#!/usr/bin/env bash
# live.sh — integration tests against whatever workspace SLACKER_SH_TOKEN points
# at: read-only checks (auto-discovered channel) plus a self-DM write round-trip
# it cleans up, the canvas one included (it deletes the canvas it created). No
# hardcoded workspace ids. Needs a valid token.
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
  local ff
  ff=$("$ROOT/slacker.sh" find-files --limit 5 2>/dev/null); want "find-files" "$ff" '<files'

  # A Slack List reads through the file download, not the scope-gated
  # slackLists.* methods, so this must work on a plain files:read token. No
  # hardcoded id: discover one, and skip when the workspace has no lists.
  local lid ll
  lid=$(slacker_api files.list --data-urlencode "types=lists" --data-urlencode "count=1" 2>/dev/null \
         | jq -r '.files[0].id // empty')
  if [ -n "$lid" ]; then
    ll=$("$ROOT/slacker.sh" read-list "$lid" --limit 3 2>/dev/null)
    want "read-list" "$ll" '<list id='
    want "read-list (renders a table)" "$ll" '<table>|'
    ll=$("$ROOT/slacker.sh" read-file "$lid" 2>/dev/null)
    want "read-file routes a list" "$ll" '<list id='
  else echo "  -- read-list skipped (no list in this workspace)"; fi

  # edge cases (read-only). Errors are structured <error> on stdout now.
  local es s
  es=$("$ROOT/slacker.sh" search "zxqwvnotfound12345zzz" 2>/dev/null); want "search empty" "$es" 'total="0"'
  want "search empty hint" "$es" 'no matches; broaden'
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

  # Profile status is the one mutation with no self-DM equivalent — it is
  # workspace-visible. So this is a no-op round-trip: read the current status via
  # users.info (users:read, already required), write that exact value back, and
  # assert Slack echoed it. It proves users.profile.set works end to end without
  # ever changing what anyone sees. grace, not want, because a token without
  # users.profile:write must degrade to a structured <error>, not a suite failure.
  echo; echo "== live profile status (no-op round-trip) =="
  local prof cur_text cur_emoji st
  if [ -n "$self" ]; then
    prof=$(slacker_api users.info --data-urlencode "user=$self" 2>/dev/null | jq -c '.user.profile // {}')
    cur_text=$(printf '%s' "$prof" | jq -r '.status_text // ""')
    cur_emoji=$(printf '%s' "$prof" | jq -r '.status_emoji // ""')
    if [ -z "$cur_text" ] && [ -z "$cur_emoji" ]; then
      st=$("$ROOT/slacker.sh" status --clear 2>/dev/null) || st=""
    else
      st=$("$ROOT/slacker.sh" status "$cur_text" --emoji "$cur_emoji" 2>/dev/null) || st=""
    fi
    if [ -z "$st" ]; then
      # No payload means the call failed. A token without users.profile:write must
      # still answer a structured <error>, so that is a pass, not a suite failure.
      grace "status (scope-gated)" "$ROOT/slacker.sh" status --clear
    else
      want "status round-trip keeps the text" "$st" "text=\"$cur_text\""
      want "status round-trip keeps the emoji" "$st" "emoji=\"$cur_emoji\""
    fi
  else no "status" "no user_id from auth.test"; fi

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

    # canvas round-trip. The CLI has no delete-canvas action (canvases.delete is a
    # deliberate non-goal), so this removes its own canvas through the API. It
    # only ever touches the id it just created.
    local cmdf cnew cid cedit chtml curl_ ctables cdel
    cmdf=$(mktemp "${TMPDIR:-/tmp}/slacker_live_md.XXXXXX")
    # Padded cells on purpose: padding is the thing the docs made look like a
    # constraint, and a live canvas is the only place that can be settled.
    printf '## padded table\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n' > "$cmdf"
    cnew=$("$ROOT/slacker.sh" create-canvas "$dm" --title 'slacker.sh live test' --markdown-file "$cmdf" 2>/dev/null)
    want "create-canvas" "$cnew" '<canvas id='
    cid=$(printf '%s' "$cnew" | grep -o 'id="[^"]*"' | head -1 | sed 's/id="//;s/"//')
    if [ -n "$cid" ]; then
      want "create-canvas resolves a permalink" "$cnew" 'permalink='
      want "create-canvas names the DM" "$cnew" 'channel="dm:'
      cedit=$("$ROOT/slacker.sh" edit-canvas "$cid" --markdown-file "$cmdf" --append 2>/dev/null)
      want "edit-canvas --append" "$cedit" 'operation="insert_at_end"'
      # read-canvas flattens a table and a pipe paragraph to the same text, so the
      # canvas HTML is the only proof the markdown became real tables. Two writes
      # of one table must therefore count two.
      curl_=$(slacker_api files.info --data-urlencode "file=$cid" 2>/dev/null \
        | jq -r '.file.url_private_download // .file.url_private // empty')
      if [ -n "$curl_" ]; then
        chtml=$(mktemp "${TMPDIR:-/tmp}/slacker_live_canvas.XXXXXX")
        curl -sSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$curl_" -o "$chtml" 2>/dev/null || true
        ctables=$(grep -o '<table' "$chtml" 2>/dev/null | wc -l | tr -d ' ')
        eq "canvas tables are real (padded cells render)" "2" "$ctables"
        rm -f "$chtml"
      else no "canvas html" "no download url"; fi
      # Cleanup runs whatever the assertions above did. It goes through the real
      # action, and falls back to the raw call so a broken action cannot leak the
      # canvas it was supposed to remove.
      cdel=$("$ROOT/slacker.sh" delete-canvas "$cid" 2>/dev/null)
      want "delete-canvas (cleanup)" "$cdel" 'deleted="true"'
      if ! printf '%s' "$cdel" | grep -q 'deleted="true"'; then
        slacker_api canvases.delete --data-urlencode "canvas_id=$cid" >/dev/null 2>&1 || true
      fi
    else no "create-canvas" "no canvas id returned"; fi
    rm -f "$cmdf"
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
