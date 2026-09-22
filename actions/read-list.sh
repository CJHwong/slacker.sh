# shellcheck shell=bash
# help: read | Slack List rows as a table
# actions/read-list.sh — read a Slack List.
# Slack's slackLists.* methods need a lists:read scope. A List's url_private does
# not: it serves the schema and every row as one JSON document, under the same
# files:read scope every other read already uses. So this is files.info plus an
# authenticated download, like read-canvas, not a new API surface.
# Sourced by slacker.sh with the action args as "$@".

SLACKER_LIST_ROW_CAP="${SLACKER_LIST_ROW_CAP:-100}"

slacker_read_list() {
  local input="" limit=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) slacker_flag_value "$1" "$#" || return 1
               slacker_count_value "$1" "$2" || return 1; limit="$2"; shift 2 ;;
      -*)      echo "read-list: unknown flag $1" >&2; return 1 ;;
      *)       input="$1"; shift ;;
    esac
  done
  [ -n "$input" ] || { echo "usage: slacker.sh read-list <Fid|permalink> [--limit N]" >&2; return 1; }
  limit="${limit:-$SLACKER_LIST_ROW_CAP}"
  [ "$limit" -gt 0 ] || { slacker_error bad_count recover "--limit must be at least 1." \
    "Pass a positive whole number, then retry."; return 1; }

  # A list id is an ordinary file id, so the canvas extractor already does this.
  local listid
  listid=$(slacker_canvas_id_from "$input")
  [ -n "$listid" ] || { slacker_error no_list_id escalate "no list id found in '$input'." \
    "Pass a list file id (Fxxxx) or a Slack list permalink."; return 1; }

  local info ftype title url perma
  info=$(slacker_api files.info --data-urlencode "file=$listid") || return 1
  ftype=$(printf '%s' "$info" | jq -r '.file.filetype // ""')
  title=$(printf '%s' "$info" | jq -r '.file.title // .file.name // .file.id')
  url=$(printf   '%s' "$info" | jq -r '.file.url_private // ""')
  perma=$(printf '%s' "$info" | jq -r '.file.permalink // ""')

  # A wrong type here is the user pointing at the wrong thing, and the sibling
  # action that does handle it is worth naming rather than making them guess.
  if [ "$ftype" != "list" ]; then
    slacker_error not_a_list escalate \
      "file $listid is a '$ftype', not a Slack List." \
      "Read it with read-file, or read-canvas for a canvas."
    return 1
  fi
  [ -n "$url" ] || { slacker_error no_list_url escalate "list $listid has no download url." \
    "Open the permalink instead: $perma"; return 1; }

  local rawf
  rawf=$(mktemp "${TMPDIR:-/tmp}/slacker_list.XXXXXX")
  curl -fsSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$url" -o "$rawf" \
    || { slacker_error download_failed escalate "couldn't download list $listid." \
         "Open the permalink instead: $perma"; return 1; }

  # Everything downstream runs jq over this file. A non-JSON body (an error page,
  # a truncated transfer) would kill the first of them mid-pipeline and leave the
  # caller with an empty stdout and no <error> to parse, so check it once here.
  jq -e 'type == "object"' < "$rawf" >/dev/null 2>&1 \
    || { slacker_error bad_list_payload escalate \
         "list $listid downloaded, but its body is not the JSON document a list serves." \
         "Open the permalink instead: $perma"; rm -f "$rawf"; return 1; }

  # Cells hold bare user ids, and a list often carries people who are not in the
  # directory snapshot, so resolve the misses the way every other read does.
  local users_file channels_file umap cmap
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1
  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_lumap.XXXXXX")
  slacker_augment_users "$users_file" < "$rawf" > "$umap"
  cmap=$(mktemp "${TMPDIR:-/tmp}/slacker_lcmap.XXXXXX")
  slacker_augment_channels "$channels_file" < "$rawf" > "$cmap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($list[0] // {}) as $l | ($users[0] // {}) as $u | ($channels[0] // {}) as $c
    | (($l.list_records // []) | length) as $rows
    | ([$rows, ($lim | tonumber)] | min) as $shown
    | "<list id=\"" + attr($id) + "\" title=\"" + attr($title)
      + "\" rows=\"" + ($rows | tostring) + "\" shown=\"" + ($shown | tostring)
      + "\" permalink=\"" + attr($perma) + "\">\n"
    + "  <table>" + (($l | render_list_rows($u; $c; ($lim | tonumber))) | xml_escape) + "</table>\n"
    + (if $rows == 0
       then "  <note>the list has no rows</note>\n"
       elif $shown < $rows
       then "  <more note=\"showing " + ($shown | tostring) + " of " + ($rows | tostring)
            + " rows; raise --limit\"/>\n"
       else "" end)
    + "</list>"
  ' --arg id "$listid" --arg title "$title" --arg perma "$perma" --arg lim "$limit" \
    --slurpfile list "$rawf" --slurpfile users "$umap" --slurpfile channels "$cmap"
  rm -f "$rawf" "$umap" "$cmap"
}

slacker_read_list "$@"
