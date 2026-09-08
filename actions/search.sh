# shellcheck shell=bash
# help: read | enriched cross-channel message search
# actions/search.sh — cross-channel message search, enriched.
# Composes search.messages + users/channels caches. Flags become Slack search
# modifiers (in:/from:/after:). Requires a user token.
# Sourced by slacker.sh with the action args as "$@".

slacker_search() {
  local query="" in="" from="" since="" limit=20 page=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --in)    slacker_flag_value "$1" "$#" || return 1; in="$2"; shift 2 ;;
      --from)  slacker_flag_value "$1" "$#" || return 1; from="$2"; shift 2 ;;
      --since) slacker_flag_value "$1" "$#" || return 1; since="$2"; shift 2 ;;
      --limit) slacker_flag_value "$1" "$#" || return 1; limit="$2"; shift 2 ;;
      --page)  slacker_flag_value "$1" "$#" || return 1; page="$2"; shift 2 ;;
      -*)      echo "search: unknown flag $1" >&2; return 1 ;;
      *)       if [ -z "$query" ]; then query="$1"; else query="$query $1"; fi; shift ;;
    esac
  done
  if [ -z "$query" ]; then
    echo "usage: slacker.sh search <query> [--in #ch] [--from @user] [--since <date|7d>] [--limit N] [--page N]" >&2
    return 1
  fi
  slacker_count_value --limit "$limit" || return 1
  [ -n "$page" ] && { slacker_count_value --page "$page" || return 1; }
  : "${page:=1}"
  case "${SLACKER_SH_TOKEN:-}" in
    xoxp-*) : ;;
    *) slacker_error not_allowed_token_type escalate \
         "search needs a user token (xoxp-); search.messages isn't available to bot tokens." \
         "A human must configure a user token in SLACKER_SH_TOKEN."; return 1 ;;
  esac

  local q="$query"
  [ -n "$in" ]    && q="$q in:${in}"
  [ -n "$from" ]  && q="$q from:${from}"
  if [ -n "$since" ]; then
    local after; after=$(slacker_since_to_after "$since") || return 1
    q="$q after:${after}"
  fi

  local count="$limit"; [ "$count" -gt 100 ] && count=100
  local users_file channels_file
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1
  local bodyf; bodyf=$(mktemp "${TMPDIR:-/tmp}/slacker_srch.XXXXXX")
  slacker_api search.messages --data-urlencode "query=$q" \
    --data-urlencode "count=$count" --data-urlencode "page=$page" --data-urlencode "highlight=false" > "$bodyf" || { rm -f "$bodyf"; return 1; }

  local umap; umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  slacker_augment_users "$users_file" < "$bodyf" > "$umap"
  local cmap; cmap=$(mktemp "${TMPDIR:-/tmp}/slacker_cmap.XXXXXX")
  slacker_augment_channels "$channels_file" < "$bodyf" > "$cmap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    # .messages and .matches are objects/arrays by contract, not by guarantee.
    # Indexing a string or an array with "matches" aborted the render with a raw
    # jq error and an empty stdout, so normalize both shapes before reading them.
    (($res[0].messages | if type == "object" then . else {} end)) as $m
    | (($m.matches | if type == "array" then . else [] end)) as $matches |
    ($users[0]) as $u | ($channels[0]) as $c |
    ($m.paging // {}) as $pg |
    "<results query=\"" + attr($q) + "\" total=\"" + (($pg.total // $m.total // 0) | tostring)
      + "\" page=\"" + (($pg.page // 1) | tostring) + "\" pages=\"" + (($pg.pages // 1) | tostring)
      + "\" shown=\"" + (($matches | length) | tostring) + "\">\n"
    + (([ $matches[]
          | "  <match channel=\"" + attr(channel_label($u; $c))
            + "\" author=\"" + attr(user_name($u; .user) // .username // .user // "")
            + "\" time=\"" + (.ts | fmt_ts) + "\" ts=\"" + attr(.ts) + "\""
            + " permalink=\"" + attr(.permalink) + "\">"
            + ((.text // "") | resolve_text($u; $c) | xml_escape)
            + "</match>\n" ] | add) // "")
    + (if ($matches | length) == 0
       then "  <more note=\"no matches; broaden the query or relax --in/--from/--since\"/>\n"
       elif ($pg.page // 1) < ($pg.pages // 1)
       then "  <more note=\"more results: rerun with --page " + (($pg.page // 1) + 1 | tostring) + " (of " + (($pg.pages) | tostring) + ")\"/>\n"
       else "" end)
    + "</results>"
  ' \
    --slurpfile users "$umap" \
    --slurpfile channels "$cmap" \
    --slurpfile res "$bodyf" \
    --arg q "$q"
  rm -f "$umap" "$cmap" "$bodyf"
}

slacker_search "$@"
