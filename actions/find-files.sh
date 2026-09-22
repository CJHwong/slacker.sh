# shellcheck shell=bash
# help: read | find files by name, channel, owner, type or date
# actions/find-files.sh — file discovery over files.list.
# files.list offers no name filter and pages with paging.page/paging.pages rather
# than a cursor, so this scans pages and matches the name locally. A local match
# over a scanned window can miss a file, so an incomplete scan and a capped result
# set both emit a <more> marker. Silence would read as "no such file".
# Sourced by slacker.sh with the action args as "$@".

SLACKER_FILES_COUNT="${SLACKER_FILES_COUNT:-100}"
SLACKER_FILES_MAX_PAGES="${SLACKER_FILES_MAX_PAGES:-10}"

# Rows in a JSONL file; 0 when it is empty or unreadable.
slacker_files_rows() { jq -s 'length' "$1" 2>/dev/null || printf '0'; }

slacker_find_files() {
  local name="" chan="" from="" ftype="" since="" limit=25
  while [ $# -gt 0 ]; do
    case "$1" in
      --in)    slacker_flag_value "$1" "$#" || return 1; chan="$2";  shift 2 ;;
      --from)  slacker_flag_value "$1" "$#" || return 1; from="$2";  shift 2 ;;
      --type)  slacker_flag_value "$1" "$#" || return 1; ftype="$2"; shift 2 ;;
      --since) slacker_flag_value "$1" "$#" || return 1; since="$2"; shift 2 ;;
      --limit) slacker_flag_value "$1" "$#" || return 1
               slacker_count_value "$1" "$2" || return 1; limit="$2"; shift 2 ;;
      -*)      echo "find-files: unknown flag $1" >&2; return 1 ;;
      *)       name="$1"; shift ;;
    esac
  done
  [ "$limit" -gt 0 ] || { slacker_error bad_count recover "--limit must be at least 1." \
    "Pass a positive whole number, then retry."; return 1; }

  local channels_file users_file
  channels_file=$(slacker_channels_cache) || return 1
  users_file=$(slacker_users_cache) || return 1

  # Seeded with count, so this array is never empty. Expanding an empty array
  # under set -u is fatal before bash 4.4, and that happens before any API call.
  local fargs=(--data-urlencode "count=$SLACKER_FILES_COUNT")
  if [ -n "$chan" ]; then
    local chan_id
    chan_id=$(slacker_resolve_channel "$chan" "$channels_file") || return 1
    fargs+=(--data-urlencode "channel=$chan_id")
  fi
  if [ -n "$from" ]; then
    local from_id
    from_id=$(slacker_resolve_user "$from" "$users_file") || return 1
    fargs+=(--data-urlencode "user=$from_id")
  fi
  if [ -n "$ftype" ]; then fargs+=(--data-urlencode "types=$ftype"); fi
  if [ -n "$since" ]; then
    local epoch
    epoch=$(slacker_to_epoch "$since") || return 1
    fargs+=(--data-urlencode "ts_from=$epoch")
  fi

  local rawf bodyf allf umap cmap
  rawf=$(mktemp "${TMPDIR:-/tmp}/slacker_files.XXXXXX")
  bodyf=$(mktemp "${TMPDIR:-/tmp}/slacker_fpage.XXXXXX")
  : > "$rawf"

  # Scan to the end of the pages, or to the ceiling. There is no early stop on the
  # match count: this has to know whether the scan was complete before it can say
  # anything about what it did not find. The ceiling bounds the API calls a narrow
  # query would otherwise make against a large team.
  local page=1 pages=1 total=0 scanned=0 stop=""
  while [ -z "$stop" ]; do
    slacker_api files.list "${fargs[@]}" --data-urlencode "page=$page" > "$bodyf" \
      || { rm -f "$rawf" "$bodyf"; return 1; }
    jq -c '.files[]?' "$bodyf" >> "$rawf" 2>/dev/null || true
    pages=$(jq -r '.paging.pages // 1' "$bodyf" 2>/dev/null) || pages=1
    total=$(jq -r '.paging.total // 0' "$bodyf" 2>/dev/null) || total=0
    scanned=$(slacker_files_rows "$rawf")
    if   [ "$page" -ge "$pages" ];                   then stop=exhausted
    elif [ "$page" -ge "$SLACKER_FILES_MAX_PAGES" ]; then stop=scan
    else page=$(( page + 1 ))
    fi
  done
  rm -f "$bodyf"

  # An external file owner is not in the directory, so resolve unknowns the way
  # every other read does rather than printing an id.
  allf=$(mktemp "${TMPDIR:-/tmp}/slacker_fall.XXXXXX")
  jq -s '.' "$rawf" > "$allf"
  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  slacker_augment_users "$users_file" < "$allf" > "$umap"
  cmap=$(mktemp "${TMPDIR:-/tmp}/slacker_cmap.XXXXXX")
  slacker_augment_channels "$channels_file" < "$allf" > "$cmap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    # files.list has no name filter, so the query is matched here. A window that
    # ended early looks exactly like "no such file", which is why every early cut
    # below reports itself.
    # Both names are searched because they diverge: a Slack List is named "list"
    # (the same constant for every list) and carries its real name in .title, so
    # a name-only match can never find one.
    def file_matches($q):
      ($q == "") or ((([.name, .title] | map(select(type == "string")) | join(" ")) | ascii_downcase)
                     | contains(($q | ascii_downcase)));
    # A channel id the directory cannot resolve is dropped rather than printed: a
    # bare Cxxxx in the payload is the leak this avoids. Slack repeats an id once
    # per share, so dedupe before joining.
    def chan_names($us; $ch):
      [ (.channels // [])[]
        | . as $id
        | ($ch[$id] // "") as $v
        | if $v == "" then empty
          elif ($v | test("^[UW][A-Z0-9]+$")) then "dm:" + (user_name($us; $v) // $v)
          else $v end ] | unique | join(", ");
    ($files[0] // []) as $f | ($users[0] // {}) as $u | ($channels[0] // {}) as $c
    | ([ $f[] | select(file_matches($q)) ]) as $m
    | ($m[0:($lim | tonumber)]) as $shown
    # Every cut reports itself, and an incomplete scan outranks a capped result
    # set: "matched 989" over a window of 98527 files reads as a total unless the
    # size of that window is said out loud. The two are not mutually exclusive, so
    # both can appear in one note. Bound here rather than mid-concatenation: an
    # `as` binding is a pipeline stage, not an operand of `+`.
    | ([ (if $stop == "scan"
          then "scanned the first " + $scanned + " of " + $total
               + " files and matched " + (($m | length) | tostring)
               + " within them; narrow with --since or --in to search the rest"
          else "" end),
         (if ($m | length) > ($lim | tonumber)
          then "returned " + (($shown | length) | tostring) + " of "
               + (($m | length) | tostring) + " matches; raise --limit"
          else "" end),
         (if ($m | length) == 0 and $stop != "scan"
          then "no files matched; broaden the query or relax --in/--from/--since"
          else "" end) ]
       | map(select(. != "")) | join("; ")) as $note
    | "<files query=\"" + attr($q)
      + "\" matched=\"" + (($m | length) | tostring)
      + "\" shown=\"" + (($shown | length) | tostring)
      + "\" scanned=\"" + attr($scanned) + "\" total=\"" + attr($total) + "\">\n"
    + (([ $shown[]
          # Every Slack List is named "list", so every list in a workspace renders
          # as the same row. The title is the name a human gave it, so lead with
          # that. NOTE: no apostrophes in this comment. The whole jq program is a
          # single-quoted bash string, and one would end it mid-program.
          | "  <file id=\"" + attr(.id)
            + "\" name=\"" + attr(if (.filetype // "") == "list"
                                  then (.title // .name // "")
                                  else (.name // .title // "") end) + "\""
            + " type=\"" + attr(.filetype // "") + "\" size=\"" + ((.size // 0) | tostring) + "\""
            + " created=\"" + ((.created // 0) | fmt_ts) + "\""
            + " by=\"" + attr(user_name($u; .user) // "") + "\""
            + (chan_names($u; $c) as $chn | if $chn == "" then "" else " channel=\"" + attr($chn) + "\"" end)
            + (if (.permalink // "") != "" then " permalink=\"" + attr(.permalink) + "\"" else "" end)
            + "/>\n" ] | add) // "")
    + (if $note == "" then "" else "  <more note=\"" + attr($note) + "\"/>\n" end)
    + "</files>"
  ' \
    --arg q "$name" --arg lim "$limit" --arg scanned "$scanned" --arg total "$total" \
    --arg stop "$stop" \
    --slurpfile files "$allf" --slurpfile users "$umap" --slurpfile channels "$cmap"
  rm -f "$rawf" "$allf" "$umap" "$cmap"
}

slacker_find_files "$@"
