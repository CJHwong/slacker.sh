# shellcheck shell=bash
# actions/search.sh — cross-channel message search, enriched.
# Composes search.messages + users/channels caches. Flags become Slack search
# modifiers (in:/from:/after:). Requires a user token.
# Sourced by slacker.sh with the action args as "$@".

slacker_search() {
  local query="" in="" from="" since="" limit=20 page=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --in)    in="$2"; shift 2 ;;
      --from)  from="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --page)  page="$2"; shift 2 ;;
      -*)      echo "search: unknown flag $1" >&2; return 1 ;;
      *)       if [ -z "$query" ]; then query="$1"; else query="$query $1"; fi; shift ;;
    esac
  done
  if [ -z "$query" ]; then
    echo "usage: slacker.sh search <query> [--in #ch] [--from @user] [--since YYYY-MM-DD] [--limit N] [--page N]" >&2
    return 1
  fi
  : "${page:=1}"
  case "${SLACKER_SH_TOKEN:-}" in
    xoxp-*) : ;;
    *) echo "search: requires a user token (xoxp-); search.messages is not available to bot tokens" >&2; return 1 ;;
  esac

  local q="$query"
  [ -n "$in" ]    && q="$q in:${in}"
  [ -n "$from" ]  && q="$q from:${from}"
  [ -n "$since" ] && q="$q after:${since}"

  local count="$limit"; [ "$count" -gt 100 ] && count=100
  local users_file channels_file
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1
  local bodyf; bodyf=$(mktemp "${TMPDIR:-/tmp}/slacker_srch.XXXXXX")
  slacker_api search.messages --data-urlencode "query=$q" \
    --data-urlencode "count=$count" --data-urlencode "page=$page" --data-urlencode "highlight=false" > "$bodyf" || { rm -f "$bodyf"; return 1; }

  local umap; umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  slacker_augment_users "$users_file" < "$bodyf" > "$umap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($res[0].messages) as $m |
    ($users[0]) as $u | ($channels[0]) as $c |
    ($m.paging // {}) as $pg |
    "<results query=\"" + attr($q) + "\" total=\"" + (($pg.total // $m.total // 0) | tostring)
      + "\" page=\"" + (($pg.page // 1) | tostring) + "\" pages=\"" + (($pg.pages // 1) | tostring)
      + "\" shown=\"" + (($m.matches | length) | tostring) + "\">\n"
    + (([ $m.matches[]
          | "  <match channel=\"" + attr(channel_label($u; $c))
            + "\" author=\"" + attr(user_name($u; .user) // .username // .user // "")
            + "\" time=\"" + (.ts | fmt_ts) + "\" ts=\"" + attr(.ts) + "\""
            + " permalink=\"" + attr(.permalink) + "\">"
            + ((.text // "") | resolve_text($u; $c) | xml_escape)
            + "</match>\n" ] | add) // "")
    + (if ($pg.page // 1) < ($pg.pages // 1)
       then "  <more note=\"more results: rerun with --page " + (($pg.page // 1) + 1 | tostring) + " (of " + (($pg.pages) | tostring) + ")\"/>\n"
       else "" end)
    + "</results>"
  ' \
    --slurpfile users "$umap" \
    --slurpfile channels "$channels_file" \
    --slurpfile res "$bodyf" \
    --arg q "$q"
  rm -f "$umap" "$bodyf"
}

slacker_search "$@"
