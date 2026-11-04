# shellcheck shell=bash
# Offline-only audience and partial-success regressions. Never open a live group.
open_dm_tests(){
  echo "== actions/open-dm =="
  local out out2 rc
  stub_reset
  STUB_TOKEN='' errs "open-dm: token-free help" 'usage: slacker.sh open-dm' cli open-dm -h
  errs "open-dm: unknown flag" 'unknown flag' cli open-dm --nope
  unsent "open-dm: help/usage makes no API calls" '/api/'
  oerr "open-dm: empty participant" bad_participants cli open-dm ''

  stub_reset
  out=$(STUB_VARIANT=group-dm cli open-dm @alice 'Bob Tan')
  want "open-dm: group receipt is XML" "$out" 'id="G400" type="mpim" members_verified="true"'
  want "open-dm: names and XML escaping" "$out" 'name="Me &amp; Myself"'
  want "open-dm: requested audience labeled" "$out" 'source="requested" count="3"'
  want "open-dm: Alice resolved" "$out" 'id="U1" name="Alice"'
  want "open-dm: Bob resolved" "$out" 'id="U2" name="Bob Tan"'
  sent "open-dm: identifies caller" '/api/auth.test'
  sent "open-dm: opens whole group" 'users=U1,U2'
  sent "open-dm: requests full definition" 'return_im=true'
  sent "open-dm: verifies opened id" 'channel=G400'
  unsent "open-dm: never posts a message" 'chat.postMessage'
  unsent "open-dm: never creates a channel" 'conversations.create'
  # Repeat against the same fixture without resetting: both calls still use the
  # same member set and return the same id, even in a different input order.
  out2=$(STUB_VARIANT=group-dm cli open-dm U2 U1)
  want "open-dm: same member set resumes" "$out2" 'id="G400"'
  sent "open-dm: preserves input order for Slack" 'users=U2,U1'

  stub_reset
  xml "open-dm: individual DM" 'type="im" members_verified="true"' open-dm U1
  sent "open-dm: individual request" 'users=U1'
  stub_reset
  xml "open-dm: duplicate aliases and caller removed" 'members_verified="true"' \
    open-dm U1 @alice USELF U1
  sent "open-dm: sends one unique other user" 'users=U1 '
  unsent "open-dm: caller not passed to open" 'users=USELF'
  stub_reset
  STUB_VARIANT=group-dm xml "open-dm: email participant" 'members_verified="true"' \
    open-dm @alice bob@example.com
  sent "open-dm: email lookup" 'users.lookupByEmail'

  stub_reset
  STUB_VARIANT=dm-eight xml "open-dm: eight others accepted" 'members_verified="true"' \
    open-dm U1 U2 U4 U5 U6 U7 U8 U9
  stub_reset
  oerr "open-dm: ninth other user rejected" too_many_users \
    cli open-dm U1 U2 U4 U5 U6 U7 U8 U9 U10
  unsent "open-dm: too many users never opens" 'conversations.open'
  stub_reset
  oerr "open-dm: caller alone rejected" not_enough_users cli open-dm USELF
  unsent "open-dm: caller-only never opens" 'conversations.open'
  stub_reset
  oerr "open-dm: comma injection rejected" bad_participants cli open-dm 'U1,U2'
  unsent "open-dm: malformed ids never open" 'conversations.open'
  stub_reset
  oerr "open-dm: deactivated participant rejected" user_disabled cli open-dm U1 @carol
  unsent "open-dm: no partial audience on disabled user" 'conversations.open'
  stub_reset
  STUB_VARIANT=ambiguous-exact oerr "open-dm: duplicate exact names rejected" user_ambiguous \
    cli open-dm Sam
  unsent "open-dm: ambiguous audience never opens" 'conversations.open'
  stub_reset
  oerr "open-dm: unknown user stops before opening" user_not_found cli open-dm @definitely-missing
  unsent "open-dm: unresolved audience never opens" 'conversations.open'
  unsent "open-dm: never guesses audience from history" 'search.messages'
  stub_reset
  STUB_VARIANT=email-denied oerr "open-dm: email lookup denial propagates" missing_scope \
    cli open-dm bob@example.com
  unsent "open-dm: email denial never searches" 'search.messages'
  unsent "open-dm: email denial never opens" 'conversations.open'
  stub_reset
  STUB_VARIANT=no-email-user oerr "open-dm: empty email lookup rejected" user_not_found \
    cli open-dm bob@example.com
  unsent "open-dm: empty email never searches" 'search.messages'
  stub_reset
  cli whois @alice >/dev/null
  touch -t 202001010000 "$STUB_CACHE/users.json"
  STUB_TTL=9999999999 STUB_FAIL=users.list oerr "open-dm: failed directory refresh stops" \
    directory_refresh_failed cli open-dm @definitely-missing
  unsent "open-dm: failed directory never opens" 'conversations.open'
  stub_reset
  oerr "open-dm: wrong user enrichment rejected" bad_identity cli open-dm UUNKNOWN
  unsent "open-dm: wrong enrichment never opens" 'conversations.open'
  stub_reset
  STUB_VARIANT=bad-self oerr "open-dm: bad caller rejected" bad_identity cli open-dm U1
  unsent "open-dm: missing caller never opens" 'conversations.open'
  stub_reset
  STUB_VARIANT=auth-denied oerr "open-dm: auth failure stops" invalid_auth cli open-dm U1
  unsent "open-dm: auth failure never opens" 'conversations.open'
  stub_reset
  STUB_FAIL=users.info oerr "open-dm: enrichment failure stops" network_error cli open-dm U1
  unsent "open-dm: failed enrichment never opens" 'conversations.open'

  stub_reset
  STUB_VARIANT=missing-mpim-scope oerr "open-dm: missing scope is structured" missing_scope \
    cli open-dm U1 U2
  unsent "open-dm: missing scope no fallback" 'conversations.create'
  stub_reset
  STUB_VARIANT=bad-open oerr "open-dm: bad response warns uncertain open" bad_open_response \
    cli open-dm U1
  unsent "open-dm: bad response never verifies guessed id" 'conversations.members'
  stub_reset
  out=$(STUB_VARIANT=member-denied cli open-dm U1); rc=$?
  eq "open-dm: open success retained after read denial" 0 "$rc"
  want "open-dm: partial receipt keeps id" "$out" 'id="D300" type="im" members_verified="false"'
  want "open-dm: partial receipt keeps exact error" "$out" 'code="missing_scope"'
  if xml_ok "$out"; then ok "open-dm: partial result is one XML document"
  else no "open-dm: partial result is one XML document" "$out"; fi
  unsent "open-dm: read denial never sends" 'chat.postMessage'
  stub_reset
  STUB_VARIANT=member-mismatch xml "open-dm: wrong membership not certified" 'members_verified="false"' \
    open-dm U1
  stub_reset
  STUB_FAIL=conversations.members xml "open-dm: read network failure retains receipt" 'code="network_error"' \
    open-dm U1
  stub_cleanup
}
