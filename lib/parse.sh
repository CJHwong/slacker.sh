# shellcheck shell=bash
# lib/parse.sh — shell-side input parsing shared across actions.
# Sourced by slacker.sh. Depends on: jq, date.

# Parse a date/time string to epoch — portable (BSD `date -j`, then GNU `date -d`).
# Accepts YYYY-MM-DD, "YYYY-MM-DD HH:MM", YYYY-MM-DDTHH:MM. Nonzero if unparseable.
slacker_parse_when() {
  local v="$1"
  date -j -f "%Y-%m-%d %H:%M" "$v" +%s 2>/dev/null && return 0
  date -j -f "%Y-%m-%dT%H:%M" "$v" +%s 2>/dev/null && return 0
  date -j -f "%Y-%m-%d" "$v" +%s 2>/dev/null && return 0
  date -d "$v" +%s 2>/dev/null && return 0
  return 1
}

# A "since" value -> epoch seconds. Accepts raw epoch, YYYY-MM-DD[ HH:MM], or a
# relative span ago: 7d, 2w, 24h (handy for "catch me up on the last week").
slacker_to_epoch() {
  local input="$1" num
  case "$input" in
    ''|*[!0-9]*)
      # relative "N<unit> ago": now minus the span. Falls through to date parsing
      # if the prefix isn't a clean number (e.g. "7days", "tomorrow").
      case "$input" in
        [0-9]*[dwh])
          num=${input%?}
          case "$num" in
            ''|*[!0-9]*) : ;;
            *) case "$input" in
                 *h) printf '%s' "$(( $(date +%s) - num * 3600 ))";  return 0 ;;
                 *d) printf '%s' "$(( $(date +%s) - num * 86400 ))"; return 0 ;;
                 *w) printf '%s' "$(( $(date +%s) - num * 604800 ))"; return 0 ;;
               esac ;;
          esac ;;
      esac
      slacker_parse_when "$input" \
        || { slacker_error bad_date recover "can't parse date '$input'." \
             "Use YYYY-MM-DD, an epoch, or a span like 7d/2w/24h, then retry."; return 1; } ;;
    *) printf '%s' "$input" ;;
  esac
}

# #name / name / Cxxxx -> channel id (reverse lookup in the channels cache).
slacker_resolve_channel() {
  local input="${1#\#}" channels_file="$2" id
  case "$input" in
    [CGD][A-Z0-9]*) printf '%s' "$input"; return 0 ;;
  esac
  id=$(jq -r --arg n "$input" 'to_entries | map(select(.value == $n)) | (.[0].key // "")' "$channels_file")
  if [ -z "$id" ]; then
    slacker_error channel_not_found escalate \
      "channel '$input' not found in the workspace directory." \
      "Slack Connect / ext-shared channels aren't listed — ask the user for the channel id (Cxxxx). Or the cache may be stale: rm ${SLACKER_CACHE_DIR:-~/.cache/slacker_sh}/channels.json to rebuild."
    return 1
  fi
  printf '%s' "$id"
}

# @name / name / Uxxxx -> user id. Matches display name, real name, or handle:
# exact (case-insensitive) wins; else substring (preferring active accounts).
# Ambiguous substring -> error listing candidates.
slacker_resolve_user() {
  local input="${1#@}" users_file="$2" result
  case "$input" in
    [UW][A-Z0-9]*) printf '%s' "$input"; return 0 ;;
    *@*.*)  # an email -> Slack lookup
      result=$(slacker_api users.lookupByEmail --data-urlencode "email=$input") || return 1
      printf '%s' "$(printf '%s' "$result" | jq -r '.user.id')"; return 0 ;;
  esac
  result=$(jq -r --arg q "$input" '
    ($q | ascii_downcase) as $ql |
    [ to_entries[] | { id: .key, n: (.value.n // ""), r: (.value.r // ""), h: (.value.h // ""), d: (.value.d // false) } ] as $all |
    ([ $all[] | select((.n | ascii_downcase) == $ql or (.r | ascii_downcase) == $ql or (.h | ascii_downcase) == $ql) ]) as $exact |
    if ($exact | length) >= 1 then $exact[0].id
    else
      ([ $all[] | select((.n | ascii_downcase | contains($ql)) or (.r | ascii_downcase | contains($ql)) or (.h | ascii_downcase | contains($ql))) ]) as $sub |
      ([ $sub[] | select(.d | not) ]) as $active |
      (if ($active | length) > 0 then $active else $sub end) as $cands |
      if   ($cands | length) == 1 then $cands[0].id
      elif ($cands | length) == 0 then ""
      else "AMBIG:" + ([ $cands[] | (if .n != "" then .n else .h end) + " (" + .id + ")" ] | join(", ")) end
    end
  ' "$users_file")
  case "$result" in
    "")       slacker_error user_not_found escalate \
                "user '$input' not found in the workspace directory." \
                "External / Slack Connect users aren't listed — ask the user for the user id (Uxxxx), or an email (whois resolves an email exactly)."
              return 1 ;;
    AMBIG:*)  slacker_error user_ambiguous escalate \
                "'$input' matches multiple users: ${result#AMBIG:}." \
                "Ask the user which one they mean and pass that user id (Uxxxx)."
              return 1 ;;
    *)        printf '%s' "$result" ;;
  esac
}

# A channel display name: if it resolves to a user id (a DM), render dm:Name.
slacker_dm_label() {
  local value="$1" users_file="$2"
  case "$value" in
    [UW][A-Z0-9]*) printf 'dm:%s' "$(jq -r --arg id "$value" '.[$id].n // $id' "$users_file")" ;;
    *)             printf '%s' "$value" ;;
  esac
}

# A Slack permalink -> "channel_id<TAB>ts<TAB>thread_ts" (thread_ts may be empty).
# https://x.slack.com/archives/C123/p1700000000123456?thread_ts=1699999999.000100&cid=C123
slacker_parse_permalink() {
  local url="$1" cid ppart secs micros ts thread
  cid=$(printf '%s' "$url"   | sed -n 's#.*/archives/\([A-Z0-9][A-Z0-9]*\)/.*#\1#p')
  ppart=$(printf '%s' "$url" | sed -n 's#.*/archives/[A-Z0-9]*/p\([0-9][0-9]*\).*#\1#p')
  thread=$(printf '%s' "$url" | sed -n 's#.*[?&]thread_ts=\([0-9.][0-9.]*\).*#\1#p')
  if [ -n "$ppart" ]; then
    secs=${ppart%??????}; micros=${ppart#"$secs"}; ts="$secs.$micros"
  fi
  if [ -z "$cid" ] || [ -z "$ts" ]; then
    slacker_error bad_permalink escalate \
      "couldn't parse the Slack permalink: $url" \
      "Pass a full archives permalink like https://<workspace>.slack.com/archives/C.../p..., then retry."
    return 1
  fi
  printf '%s\t%s\t%s' "$cid" "$ts" "$thread"
}

# A message target -> "channel_id<TAB>ts<TAB>thread". Accepts a permalink ($1)
# OR a channel ($2) + ts ($3). Shared by react/edit/delete/pin.
slacker_resolve_message() {
  local url="$1" chan="$2" ts="$3" channels_file="$4"
  if [ -n "$url" ]; then slacker_parse_permalink "$url"; return $?; fi
  if [ -z "$chan" ] || [ -z "$ts" ]; then
    slacker_error missing_target escalate \
      "need a permalink, or both --channel and --ts." \
      "Provide a permalink, or pass --channel <#ch|id> and --ts <ts>."
    return 1
  fi
  local cid; cid=$(slacker_resolve_channel "$chan" "$channels_file") || return 1
  printf '%s\t%s\t' "$cid" "$ts"
}

# A send/post recipient -> a postable channel id. Accepts #channel / Cxxx / Dxxx
# OR @user / Uxxx / email (opens the DM). The users cache is built only when a
# person is targeted. Shared by send/schedule (and read-channel).
slacker_resolve_target() {
  local input="$1" channels_file="$2" uid resp uf
  case "$input" in
    @*|*@*.*)
      uf=$(slacker_users_cache) || return 1
      uid=$(slacker_resolve_user "$input" "$uf") || return 1
      resp=$(slacker_api conversations.open --data-urlencode "users=$uid") || return 1
      printf '%s' "$(printf '%s' "$resp" | jq -r '.channel.id')" ;;
    [UW][A-Z0-9]*)
      resp=$(slacker_api conversations.open --data-urlencode "users=$input") || return 1
      printf '%s' "$(printf '%s' "$resp" | jq -r '.channel.id')" ;;
    [CGD][A-Z0-9]*) printf '%s' "$input" ;;
    *) slacker_resolve_channel "$input" "$channels_file" ;;
  esac
}

# Raw-mrkdwn flag ($1 non-empty) -> the chat field name. Keeps send/edit/schedule
# consistent: standard Markdown via markdown_text by default, raw via --mrkdwn.
slacker_text_field() { if [ -n "$1" ]; then printf 'text'; else printf 'markdown_text'; fi; }

# A "when" -> epoch. epoch | YYYY-MM-DD[ HH:MM] | ISO | +30m/+2h/+1d. For schedule.
slacker_when_epoch() {
  local w="$1" n
  case "$w" in
    +[0-9]*m) n=${w#+}; n=${n%m}; printf '%s' "$(( $(date +%s) + n * 60 ))" ;;
    +[0-9]*h) n=${w#+}; n=${n%h}; printf '%s' "$(( $(date +%s) + n * 3600 ))" ;;
    +[0-9]*d) n=${w#+}; n=${n%d}; printf '%s' "$(( $(date +%s) + n * 86400 ))" ;;
    ''|*[!0-9]*)
      slacker_parse_when "$w" \
        || { slacker_error bad_time recover "can't parse time '$w'." \
             "Use an epoch, 'YYYY-MM-DD HH:MM', or a relative +30m/+2h/+1d, then retry."; return 1; } ;;
    *) printf '%s' "$w" ;;
  esac
}
