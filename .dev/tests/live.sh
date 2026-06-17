#!/usr/bin/env bash
# live.sh — integration tests against whatever workspace SLACKER_SH_TOKEN points
# at: read-only checks (auto-discovered channel) plus a self-DM write round-trip
# it cleans up. No hardcoded workspace ids. Needs a valid token.
#   ./.dev/tests/live.sh       run these directly (needs a token)
#   ./.dev/tests/run.sh        run the whole suite
# The `assert && ok || no` reporter pattern is intentional (ok/no never fail).
# shellcheck disable=SC2015
# shellcheck source-path=SCRIPTDIR

live_tests(){
  echo "== live (read-only, auto-discovered) =="
  local auth team self
  auth=$(slacker_api auth.test 2>/dev/null) || { no "auth.test" "token invalid"; auth='{}'; }
  team=$(printf '%s' "$auth" | jq -r '.team // "?"'); self=$(printf '%s' "$auth" | jq -r '.user_id // empty')
  [ -n "$self" ] && ok "auth.test ($team)" || no "auth.test" "no user_id"

  local ch out cinfo mts link
  ch=$(slacker_api conversations.list --data-urlencode "types=public_channel" --data-urlencode "limit=200" 2>/dev/null \
        | jq -r '[.channels[] | select(.is_member==true and (.num_members//0)>1)][0].id // empty')
  if [ -n "$ch" ]; then
    out=$("$ROOT/slacker.sh" read-channel "$ch" --limit 5 2>/dev/null); want "read-channel" "$out" '<channel'
    cinfo=$("$ROOT/slacker.sh" channel-info "$ch" 2>/dev/null); want "channel-info" "$cinfo" '<channel id='
    mts=$(slacker_api conversations.history --data-urlencode "channel=$ch" --data-urlencode "limit=1" 2>/dev/null | jq -r '.messages[0].ts // empty')
    if [ -n "$mts" ]; then
      link=$(slacker_api chat.getPermalink --data-urlencode "channel=$ch" --data-urlencode "message_ts=$mts" 2>/dev/null | jq -r '.permalink // empty')
      out=$("$ROOT/slacker.sh" read-message "$link" 2>/dev/null); want "read-message" "$out" '<message'
    else no "read-message" "no message to read"; fi
  else no "read-channel" "no member channel found"; fi

  local w wc ug
  if [ -n "$self" ]; then
    w=$("$ROOT/slacker.sh" whois "$self" 2>/dev/null)
    { xml_ok "$w" && ! printf '%s' "$w" | grep -q 'name=""'; } && ok "whois (name resolved)" || no "whois" "empty name or invalid"
    wc=$("$ROOT/slacker.sh" whois "$self" --channels 2>/dev/null); want "whois --channels" "$wc" '<channels'
  fi
  ug=$("$ROOT/slacker.sh" usergroup 2>/dev/null); want "usergroup (list)" "$ug" '<usergroups'

  # edge cases (read-only). Errors are structured <error> on stdout now.
  local es s
  es=$("$ROOT/slacker.sh" search "zxqwvnotfound12345zzz" 2>/dev/null); want "search empty" "$es" 'total="0"'
  oerr "read-file bad id"    file_not_found    "$ROOT/slacker.sh" read-file F000000XXXX
  oerr "nonexistent channel" channel_not_found "$ROOT/slacker.sh" read-channel "#totally-not-a-channel-zzz"
  oerr "nonexistent user"    user_not_found    "$ROOT/slacker.sh" whois "zzznosuchhuman999"
  # junk with no extractable id must still emit (regression: set -e + grep-no-match
  # used to abort silently before the error fired).
  oerr "read-file junk -> no_file_id" no_file_id "$ROOT/slacker.sh" read-file "no-id-here"
  # usage/unknown-flag stays on stderr (not a structured result).
  errs "unknown flag -> stderr" "unknown flag" "$ROOT/slacker.sh" whois --bogus-flag
  case "${SLACKER_SH_TOKEN:-}" in
    xoxp-*) s=$("$ROOT/slacker.sh" search "the" --limit 3 2>/dev/null); want "search" "$s" '<results' ;;
    *) echo "  -- search skipped (needs user token)" ;;
  esac

  echo; echo "== live write round-trip (self-DM, cleaned up) =="
  local dm sent sts r e d sc qid sl cx
  dm=$(slacker_api conversations.open --data-urlencode "users=$self" 2>/dev/null | jq -r '.channel.id // empty')
  if [ -n "$dm" ]; then
    sent=$("$ROOT/slacker.sh" send "$dm" 'test.sh **粗體** check' 2>/dev/null); want "send" "$sent" '<sent'
    sts=$(printf '%s' "$sent" | grep -o 'ts="[^"]*"' | head -1 | sed 's/ts="//;s/"//')
    if [ -n "$sts" ]; then
      r=$("$ROOT/slacker.sh" react --channel "$dm" --ts "$sts" white_check_mark 2>/dev/null); want "react add" "$r" 'status="added"'
      r=$("$ROOT/slacker.sh" react --channel "$dm" --ts "$sts" white_check_mark --remove 2>/dev/null); want "react remove" "$r" 'status="removed"'
      e=$("$ROOT/slacker.sh" edit --channel "$dm" --ts "$sts" 'edited by test.sh **ok**' 2>/dev/null); want "edit" "$e" '<edited'
      grace "pin" "$ROOT/slacker.sh" pin --channel "$dm" --ts "$sts"
      d=$("$ROOT/slacker.sh" delete --channel "$dm" --ts "$sts" 2>/dev/null); want "delete" "$d" '<deleted'
    else no "send" "no ts returned"; fi

    # schedule round-trip
    sc=$("$ROOT/slacker.sh" schedule "$dm" 'test.sh scheduled' --at +20m 2>/dev/null); want "schedule create" "$sc" '<scheduled'
    qid=$(printf '%s' "$sc" | grep -o 'scheduled_id="[^"]*"' | sed 's/scheduled_id="//;s/"//')
    sl=$("$ROOT/slacker.sh" schedule --list "$dm" 2>/dev/null); want "schedule list" "$sl" '<scheduled_messages'
    [ -n "$qid" ] && { cx=$("$ROOT/slacker.sh" schedule --cancel "$qid" --channel "$dm" 2>/dev/null); want "schedule cancel" "$cx" '<canceled'; }
  else no "send" "could not open self-DM"; fi
}

# Run when executed directly; stay quiet (just define live_tests) when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helpers.sh
  . "$DIR/helpers.sh"
  live_tests
  summary
fi
