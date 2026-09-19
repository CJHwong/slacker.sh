# shellcheck shell=bash
# help: write | replace or append a canvas's content from a markdown file
# actions/edit-canvas.sh — write markdown into an existing canvas.
# canvases.edit takes a changes array; the default replaces the whole document,
# which needs no section_id and no canvases:read scope. One operation per call,
# so --append is a separate call, not a second entry in the array.
# Sourced by slacker.sh with the action args as "$@".

slacker_edit_canvas() {
  local input="" mdfile="" append=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --markdown-file) slacker_flag_value "$1" "$#" || return 1; mdfile="$2"; shift 2 ;;
      --append)        append=1; shift ;;
      -*)              echo "edit-canvas: unknown flag $1" >&2; return 1 ;;
      *)               input="$1"; shift ;;
    esac
  done
  if [ -z "$input" ] || [ -z "$mdfile" ]; then
    echo "usage: slacker.sh edit-canvas <canvas-id|permalink> --markdown-file <path> [--append]" >&2
    return 1
  fi
  [ -f "$mdfile" ] || { slacker_error markdown_file_missing escalate \
    "no such file: $mdfile." \
    "Check the path, then retry."; return 1; }
  slacker_check_table_rows "$mdfile" || return 1

  local canvas_id
  canvas_id=$(slacker_canvas_id_from "$input")
  [ -n "$canvas_id" ] || { slacker_error no_canvas_id escalate \
    "no canvas id found in '$input'." \
    "Pass a canvas file id (Fxxxx) or a canvas permalink."; return 1; }

  local operation=replace
  [ -n "$append" ] && operation=insert_at_end

  # changes goes as a file reference (curl's `name@path` form) so a
  # canvas-sized document never reaches argv.
  local changesf
  changesf=$(mktemp "${TMPDIR:-/tmp}/slacker_chg.XXXXXX")
  slacker_canvas_changes "$mdfile" "$operation" > "$changesf" \
    || { rm -f "$changesf"; return 1; }

  slacker_api canvases.edit \
    --data-urlencode "canvas_id=$canvas_id" \
    --data-urlencode "changes@$changesf" > /dev/null || { rm -f "$changesf"; return 1; }
  rm -f "$changesf"

  # Resolve title and permalink for the caller. Tolerate a failure: the write
  # already happened, so a missing link must not be reported as a failed edit.
  local info title perma
  info=$(slacker_api files.info --data-urlencode "file=$canvas_id" 3>/dev/null) || info=""
  title=$(printf '%s' "$info" | jq -r '.file.title // .file.name // ""' 2>/dev/null) || title=""
  perma=$(printf '%s' "$info" | jq -r '.file.permalink // ""' 2>/dev/null) || perma=""

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<canvas id=\"" + attr($id) + "\""
    + (if $title != "" then " title=\"" + attr($title) + "\"" else "" end)
    + (if $perma != "" then " permalink=\"" + attr($perma) + "\"" else "" end)
    + " operation=\"" + attr($op) + "\"/>\n"
  ' --arg id "$canvas_id" --arg title "$title" --arg perma "$perma" --arg op "$operation"
}

slacker_edit_canvas "$@"
