# shellcheck shell=bash
# help: read | canvas content as readable text
# actions/read-canvas.sh — read a canvas.
# Slack has no "read canvas" method: canvases are files (quip mode). Resolve a
# canvas id (standalone, or a channel's properties.canvas), download the HTML,
# and reduce it to readable text.
# Sourced by slacker.sh with the action args as "$@".

SLACKER_CANVAS_TEXT_CAP="${SLACKER_CANVAS_TEXT_CAP:-131072}"

slacker_read_canvas() {
  local input="" chan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) chan="$2"; shift 2 ;;
      -*)        echo "read-canvas: unknown flag $1" >&2; return 1 ;;
      *)         input="$1"; shift ;;
    esac
  done
  if [ -z "$input" ] && [ -z "$chan" ]; then
    echo "usage: slacker.sh read-canvas <canvas-id|permalink> | --channel <#ch|id>" >&2
    return 1
  fi

  local channels_file canvas_id
  channels_file=$(slacker_channels_cache) || return 1

  if [ -n "$chan" ]; then
    local chan_id
    chan_id=$(slacker_resolve_channel "$chan" "$channels_file") || return 1
    canvas_id=$(slacker_api conversations.info --data-urlencode "channel=$chan_id" \
      | jq -r '.channel.properties.canvas.file_id // ""') || return 1
    [ -n "$canvas_id" ] || { echo "read-canvas: channel $chan has no canvas" >&2; return 1; }
  else
    case "$input" in
      F[A-Z0-9]*) canvas_id="$input" ;;
      *)          canvas_id=$(printf '%s' "$input" | grep -oE 'F[A-Z0-9]{6,}' | head -1) ;;
    esac
    [ -n "$canvas_id" ] || { echo "read-canvas: no canvas id found in '$input'" >&2; return 1; }
  fi

  local info title url perma
  info=$(slacker_api files.info --data-urlencode "file=$canvas_id") || return 1
  title=$(printf '%s' "$info" | jq -r '.file.title // .file.name // .file.id')
  url=$(printf  '%s' "$info" | jq -r '.file.url_private_download // .file.url_private // ""')
  perma=$(printf '%s' "$info" | jq -r '.file.permalink // ""')
  [ -n "$url" ] || { echo "read-canvas: canvas $canvas_id has no download url" >&2; return 1; }

  # Download to a file, reduce HTML, then cap via `head -c` from a file (never
  # pipe into head — that SIGPIPEs curl on oversized content under set -o pipefail).
  # Read into jq via --rawfile (ARG_MAX-safe). Temps are under the run-scoped TMPDIR.
  local fullf renderedf contentf
  fullf=$(mktemp "${TMPDIR:-/tmp}/slacker_dl.XXXXXX")
  curl -sSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$url" -o "$fullf" \
    || { echo "read-canvas: download failed" >&2; return 1; }
  renderedf=$(mktemp "${TMPDIR:-/tmp}/slacker_render.XXXXXX")
  jq -Rrs -L "$SLACKER_ROOT/lib" 'include "render"; html_to_text' < "$fullf" > "$renderedf"
  contentf=$(mktemp "${TMPDIR:-/tmp}/slacker_canvas.XXXXXX")
  head -c "$SLACKER_CANVAS_TEXT_CAP" "$renderedf" > "$contentf"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<canvas id=\"" + attr($id) + "\" title=\"" + attr($title)
    + "\" permalink=\"" + attr($perma) + "\">\n"
    + (if ($content | gsub("\\s"; "")) == ""
       then "  <note>empty after extraction — may be an unsupported (non-quip) canvas format; open the permalink or download the file directly</note>\n"
       else "  <content>" + ($content | xml_escape) + "</content>\n" end)
    + "</canvas>"
  ' --arg id "$canvas_id" --arg title "$title" --arg perma "$perma" --rawfile content "$contentf"
  rm -f "$contentf"
}

slacker_read_canvas "$@"
