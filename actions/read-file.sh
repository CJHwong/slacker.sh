# shellcheck shell=bash
# help: read | attachment content (text inlined, binary cached)
# actions/read-file.sh — read an attachment.
# files.info for metadata + authenticated download of url_private. Text content
# is inlined (capped); binaries are saved to the cache and the path reported.
# Sourced by slacker.sh with the action args as "$@".

SLACKER_FILE_TEXT_CAP="${SLACKER_FILE_TEXT_CAP:-65536}" # bytes inlined for text files

slacker_read_file() {
  local input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) echo "read-file: unknown flag $1" >&2; return 1 ;;
      *)  input="$1"; shift ;;
    esac
  done
  [ -n "$input" ] || { echo "usage: slacker.sh read-file <permalink|Fid>" >&2; return 1; }

  local fileid
  case "$input" in
    F[A-Z0-9]*) fileid="$input" ;;
    *)          fileid=$(printf '%s' "$input" | grep -oE 'F[A-Z0-9]{6,}' | head -1 || true) ;;
  esac
  [ -n "$fileid" ] || { slacker_error no_file_id escalate "no file id found in '$input'." \
    "Pass a file id (Fxxxx) or a Slack file permalink."; return 1; }

  local info f url mime name ftype size user perma users_file uname
  info=$(slacker_api files.info --data-urlencode "file=$fileid") || return 1
  f=$(printf '%s' "$info" | jq -c '.file')
  url=$(printf  '%s' "$f" | jq -r '.url_private // ""')
  mime=$(printf '%s' "$f" | jq -r '.mimetype // ""')
  name=$(printf '%s' "$f" | jq -r '.name // .title // .id')
  ftype=$(printf '%s' "$f" | jq -r '.filetype // ""')
  size=$(printf '%s' "$f" | jq -r '.size // 0')
  user=$(printf '%s' "$f" | jq -r '.user // ""')
  perma=$(printf '%s' "$f" | jq -r '.permalink // ""')

  users_file=$(slacker_users_cache 3>/dev/null) || users_file=""
  if [ -n "$users_file" ] && [ -n "$user" ]; then
    uname=$(jq -r --arg id "$user" '.[$id].n // $id' "$users_file")
  else
    uname="$user"
  fi

  local is_text=0
  case "$mime" in text/*|application/json|application/xml|application/x-ndjson) is_text=1 ;; esac
  case "$ftype" in text|javascript|json|csv|markdown|html|xml|yaml|yml|log|python|shell|java|c|cpp|go|rust|ruby|php|sql|diff|space) is_text=1 ;; esac

  # Shared header attributes for the <file> element (a jq expression, not bash —
  # the $vars are jq --arg bindings, so single quotes are intentional).
  # shellcheck disable=SC2016
  local hdr='"<file id=\"" + attr($id) + "\" name=\"" + attr($name) + "\" type=\"" + attr($ftype) + "\" mime=\"" + attr($mime) + "\" size=\"" + attr($size) + "\" user=\"" + attr($user) + "\" permalink=\"" + attr($perma) + "\">"'

  if [ -z "$url" ]; then
    jq -rn -L "$SLACKER_ROOT/lib" "include \"render\"; $hdr + \"\n  <error>no url_private (external or restricted file)</error>\n</file>\"" \
      --arg id "$fileid" --arg name "$name" --arg ftype "$ftype" --arg mime "$mime" --arg size "$size" --arg user "$uname" --arg perma "$perma"
    return 0
  fi

  if [ "$is_text" -eq 1 ]; then
    # Download to a file first, then `head -c` from the file (never pipe into head:
    # that SIGPIPEs curl on oversized content and would abort under set -o pipefail).
    # Read into jq via --rawfile so large content stays ARG_MAX-safe. Temp files
    # live under the run-scoped TMPDIR and are cleaned on exit.
    local rawfull contentf; rawfull=$(mktemp "${TMPDIR:-/tmp}/slacker_dl.XXXXXX")
    # -f so an HTTP 401/403 is a failure, not a "successful" download of the error
    # page. External files (Google Docs/Dropbox links shared into Slack) 401 here.
    curl -fsSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$url" -o "$rawfull" \
      || { slacker_error download_failed escalate \
           "couldn't download file $fileid — Slack only serves its own hosted files, so this looks external or restricted." \
           "Open the permalink instead: $perma"; return 1; }
    contentf=$(mktemp "${TMPDIR:-/tmp}/slacker_file.XXXXXX")
    case "$mime/$ftype" in
      text/html*|*/html|*/email)  # reduce tags + decode entities, then cap
        local renderedf; renderedf=$(mktemp "${TMPDIR:-/tmp}/slacker_html.XXXXXX")
        jq -Rrs -L "$SLACKER_ROOT/lib" 'include "render"; html_to_text' < "$rawfull" > "$renderedf"
        head -c "$SLACKER_FILE_TEXT_CAP" "$renderedf" > "$contentf" ;;
      *) head -c "$SLACKER_FILE_TEXT_CAP" "$rawfull" > "$contentf" ;;
    esac
    jq -rn -L "$SLACKER_ROOT/lib" "include \"render\"; $hdr + \"\n  <content>\" + (\$content | xml_escape) + \"</content>\n</file>\"" \
      --arg id "$fileid" --arg name "$name" --arg ftype "$ftype" --arg mime "$mime" --arg size "$size" --arg user "$uname" --arg perma "$perma" \
      --rawfile content "$contentf"
  else
    local dir dest
    dir="$SLACKER_CACHE_DIR/files"; mkdir -p "$dir"
    dest="$dir/$fileid-$name"
    curl -fsSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$url" -o "$dest" \
      || { slacker_error download_failed escalate \
           "couldn't download file $fileid — Slack only serves its own hosted files, so this looks external or restricted." \
           "Open the permalink instead: $perma"; return 1; }
    jq -rn -L "$SLACKER_ROOT/lib" "include \"render\"; $hdr + \"\n  <saved path=\\\"\" + attr(\$path) + \"\\\"/>\n</file>\"" \
      --arg id "$fileid" --arg name "$name" --arg ftype "$ftype" --arg mime "$mime" --arg size "$size" --arg user "$uname" --arg perma "$perma" \
      --arg path "$dest"
  fi
}

slacker_read_file "$@"
