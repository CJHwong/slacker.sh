# shellcheck shell=bash
# help: write | delete a canvas permanently. There is no undo.
# actions/delete-canvas.sh — delete a canvas.
# canvases.delete takes the canvas id and nothing else. Deletion is permanent
# ("there is no way to get it back"), so this action never guesses: a mistyped id
# is an <error> to escalate, never a second attempt at a different canvas.
# Sourced by slacker.sh with the action args as "$@".

slacker_delete_canvas() {
  local input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) echo "delete-canvas: unknown flag $1" >&2; return 1 ;;
      *)  input="$1"; shift ;;
    esac
  done
  [ -n "$input" ] || { echo "usage: slacker.sh delete-canvas <canvas-id|permalink>" >&2; return 1; }

  local canvas_id
  canvas_id=$(slacker_canvas_id_from "$input")
  [ -n "$canvas_id" ] || { slacker_error no_canvas_id escalate \
    "no canvas id found in '$input'." \
    "Pass a canvas file id (Fxxxx) or a canvas permalink."; return 1; }

  slacker_api canvases.delete --data-urlencode "canvas_id=$canvas_id" >/dev/null || return 1

  # The file-tombstone shape: the resource is named, and its state is that it is
  # gone. read-canvas renders the same element when the canvas still exists.
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<canvas id=\"" + attr($id) + "\" deleted=\"true\"/>\n"
  ' --arg id "$canvas_id"
}

slacker_delete_canvas "$@"
