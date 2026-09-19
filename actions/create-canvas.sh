# shellcheck shell=bash
# help: write | create a channel canvas, with optional markdown content
# actions/create-canvas.sh — create a canvas tabbed on a channel.
# conversations.canvases.create carries the body in the same call, so this is one
# request. The response holds canvas_id and no canvas object, so a second
# files.info resolves the permalink the caller needs to link to it.
# Sourced by slacker.sh with the action args as "$@".

slacker_create_canvas() {
  local target="" title="" mdfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)         slacker_flag_value "$1" "$#" || return 1; title="$2"; shift 2 ;;
      --markdown-file) slacker_flag_value "$1" "$#" || return 1; mdfile="$2"; shift 2 ;;
      -*)              echo "create-canvas: unknown flag $1" >&2; return 1 ;;
      *)               target="$1"; shift ;;
    esac
  done
  if [ -z "$target" ] || [ -z "$title" ]; then
    echo "usage: slacker.sh create-canvas <#chan|id> --title <title> [--markdown-file <path>]" >&2
    return 1
  fi

  # Validate the body first. Both checks are local, and both must fail before any
  # API call, so no canvas is created for a body that cannot be written.
  if [ -n "$mdfile" ]; then
    [ -f "$mdfile" ] || { slacker_error markdown_file_missing escalate \
      "no such file: $mdfile." \
      "Check the path, then retry."; return 1; }
    slacker_check_table_rows "$mdfile" || return 1
  fi

  local channels_file chan_id chan_name
  channels_file=$(slacker_channels_cache) || return 1
  chan_id=$(slacker_resolve_channel "$target" "$channels_file") || return 1
  chan_name=$(jq -r --arg id "$chan_id" '.[$id] // ""' "$channels_file")
  # A DM id is not in the channel directory, so fall back to the id rather than
  # emitting an empty attribute.
  [ -n "$chan_name" ] || chan_name="$chan_id"

  # The body goes as a file reference (curl's `name@path` form), so a
  # canvas-sized body never reaches argv. It is built here, after every early
  # return, so no exit path can leave the temp file behind.
  local resp canvas_id bodyf="" filled=""
  if [ -n "$mdfile" ]; then
    bodyf=$(mktemp "${TMPDIR:-/tmp}/slacker_body.XXXXXX")
    slacker_canvas_document "$mdfile" > "$bodyf" || { rm -f "$bodyf"; return 1; }
    filled=1
    resp=$(slacker_api conversations.canvases.create \
      --data-urlencode "channel_id=$chan_id" \
      --data-urlencode "title=$title" \
      --data-urlencode "document_content@$bodyf") || { rm -f "$bodyf"; return 1; }
    rm -f "$bodyf"
  else
    resp=$(slacker_api conversations.canvases.create \
      --data-urlencode "channel_id=$chan_id" \
      --data-urlencode "title=$title") || return 1
  fi

  canvas_id=$(printf '%s' "$resp" | jq -r '.canvas_id // ""')
  [ -n "$canvas_id" ] || { slacker_error no_canvas_id escalate \
    "Slack accepted the call but returned no canvas_id." \
    "Retry once. If it repeats, the canvas may already exist; look for it with: slacker.sh channel-info $chan_id"; return 1; }

  # The permalink is what the caller needs. Tolerate a failure here: the canvas
  # exists either way, so a missing link must not look like a failed create.
  local info perma
  info=$(slacker_api files.info --data-urlencode "file=$canvas_id" 3>/dev/null) || info=""
  perma=$(printf '%s' "$info" | jq -r '.file.permalink // ""' 2>/dev/null) || perma=""

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<canvas id=\"" + attr($id) + "\" title=\"" + attr($title)
    + "\" channel=\"" + attr($chan) + "\""
    + (if $perma != "" then " permalink=\"" + attr($perma) + "\"" else "" end)
    + "/>\n"
    + (if $filled == ""
       then "<note>the canvas is empty. Fill it with edit-canvas and --markdown-file.</note>\n"
       else "" end)
  ' --arg id "$canvas_id" --arg title "$title" --arg chan "$chan_name" \
    --arg perma "$perma" --arg filled "$filled"
}

slacker_create_canvas "$@"
