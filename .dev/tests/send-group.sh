# shellcheck shell=bash
# Compose group opening into send, exercising only the offline curl stub.
send_group_tests(){
  echo "== send: group DM composition =="
  local out out2 rc capf
  stub_reset
  STUB_TOKEN='' errs "group send: token-free help" '--with' cli send -h
  oerr "group send: missing --with value" missing_flag_value cli send @alice --with
  unsent "group send: usage makes no API calls" '/api/'
  oerr "group send: no separate action" unsupported_command cli open-dm @alice

  stub_reset
  xml "group send: legacy send still works" '<sent' send @alice hello
  unsent "group send: legacy has no caller lookup" 'auth.test'
  unsent "group send: legacy has no membership read" 'conversations.members'
  stub_reset
  out=$(STUB_VARIANT=group-dm cli send @alice --with 'Bob Tan' --no-unfurl -- Hello)
  want "group send: one sent receipt" "$out" 'id="G400"'
  want "group send: audience verified" "$out" 'type="mpim" members_verified="true"'
  want "group send: resolved Alice" "$out" 'id="U1" name="Alice"'
  want "group send: resolved Bob" "$out" 'id="U2" name="Bob Tan"'
  want "group send: escaped caller" "$out" 'name="Me &amp; Myself"'
  want "group send: caller included" "$out" 'members count="3"'
  sent "group send: opens one complete audience" 'users=U1,U2'
  sent "group send: sends to opened id" 'channel=G400'
  sent "group send: actually posts" 'chat.postMessage'
  sent "group send: retains no-unfurl" 'unfurl_links=false'
  unsent "group send: never creates a channel" 'conversations.create'
  out2=$(STUB_VARIANT=group-dm cli send U2 --with U1 -- Again)
  want "group send: reordered repeat reuses returned id" "$out2" 'id="G400"'
  sent "group send: reordered members preserved" 'users=U2,U1'

  stub_reset
  xml "group send: duplicate aliases and caller removed" 'type="im"' \
    send U1 --with @alice --with USELF -- Hello
  sent "group send: only unique other ids passed" 'users=U1 '
  unsent "group send: caller excluded from open" 'users=USELF'
  stub_reset
  STUB_VARIANT=group-dm xml "group send: repeated --with and email" 'members_verified="true"' \
    send @alice --with bob@example.com --with U2 -- Hello
  sent "group send: email lookup" 'users.lookupByEmail'
  stub_reset
  STUB_VARIANT=dm-eight xml "group send: eight others accepted" 'members count="9"' \
    send U1 --with U2 --with U4 --with U5 --with U6 --with U7 --with U8 --with U9 -- Hello

  stub_reset
  oerr "group send: ninth other rejected" too_many_users \
    cli send U1 --with U2 --with U4 --with U5 --with U6 --with U7 --with U8 --with U9 --with U10 -- Hello
  unsent "group send: excessive audience never opens" 'conversations.open'
  stub_reset
  oerr "group send: caller alone rejected" not_enough_users cli send USELF --with USELF -- Hello
  stub_reset
  oerr "group send: empty extra person rejected" bad_participants cli send U1 --with '' -- Hello
  stub_reset
  oerr "group send: comma injection rejected" bad_participants cli send U1 --with 'U2,U3' -- Hello
  stub_reset
  oerr "group send: option-shaped person rejected" bad_participants cli send U1 --with -nope -- Hello
  stub_reset
  oerr "group send: channel target rejected" bad_participants cli send '#general' --with @alice -- Hello
  unsent "group send: channel target never opens" 'conversations.open'
  stub_reset
  oerr "group send: thread flag rejected" bad_group_options cli send U1 --with U2 --thread 1.0 -- Hello
  stub_reset
  oerr "group send: broadcast rejected" bad_group_options cli send U1 --with U2 --broadcast -- Hello
  unsent "group send: invalid flags never open" 'conversations.open'
  stub_reset
  errs "group send: needs body or file" 'usage:' cli send U1 --with U2
  unsent "group send: missing body never opens" 'conversations.open'
  stub_reset
  oerr "group send: missing file caught before opening" file_not_found \
    cli send U1 --with U2 --file /not-a-real-group-send-file
  unsent "group send: missing file never opens" 'conversations.open'

  stub_reset
  oerr "group send: disabled person rejected" user_disabled cli send U1 --with @carol -- Hello
  unsent "group send: disabled audience never opens" 'conversations.open'
  stub_reset
  STUB_VARIANT=ambiguous-exact oerr "group send: ambiguous name rejected" user_ambiguous \
    cli send Sam --with U2 -- Hello
  # A pre-lookup must not turn an ambiguous name into a seemingly exact id.
  stub_reset
  out=$(STUB_VARIANT=ambiguous-exact cli whois Sam); rc=$?
  eq "group send: ambiguous whois fails before an id can bypass the guard" 1 "$rc"
  want "group send: whois reports ambiguity" "$out" 'code="user_ambiguous"'
  want "group send: whois lists first candidate" "$out" 'Sam (U1)'
  want "group send: whois lists second candidate" "$out" 'Sam (U2)'
  unsent "group send: ambiguous whois never chooses a profile" 'users.info'
  unsent "group send: ambiguous whois never guesses from history" 'search.messages'
  unsent "group send: ambiguous whois never opens a conversation" 'conversations.open'
  unsent "group send: ambiguous whois never posts" 'chat.postMessage'
  stub_reset
  oerr "group send: unknown person rejected" user_not_found cli send U1 --with @definitely-missing -- Hello
  unsent "group send: never infers audience from history" 'search.messages'
  stub_reset
  STUB_VARIANT=email-denied oerr "group send: email denial propagates" missing_scope \
    cli send U1 --with bob@example.com -- Hello
  unsent "group send: lookup denial never opens" 'conversations.open'
  stub_reset
  STUB_VARIANT=no-email-user oerr "group send: empty email lookup rejected" user_not_found \
    cli send U1 --with bob@example.com -- Hello
  stub_reset
  cli whois @alice >/dev/null
  touch -t 202001010000 "$STUB_CACHE/users.json"
  STUB_TTL=9999999999 STUB_FAIL=users.list oerr "group send: failed directory refresh stops" \
    directory_refresh_failed cli send U1 --with @definitely-missing -- Hello
  stub_reset
  oerr "group send: wrong user enrichment rejected" bad_identity cli send U1 --with UUNKNOWN -- Hello
  stub_reset
  STUB_VARIANT=bad-self oerr "group send: bad caller rejected" bad_identity cli send U1 --with U2 -- Hello
  stub_reset
  STUB_VARIANT=auth-denied oerr "group send: auth failure stops" invalid_auth cli send U1 --with U2 -- Hello
  stub_reset
  STUB_FAIL=users.info oerr "group send: enrichment failure stops" network_error cli send U1 --with U2 -- Hello
  stub_reset
  STUB_VARIANT=missing-mpim-scope oerr "group send: open scope denial" missing_scope cli send U1 --with U2 -- Hello
  unsent "group send: open denied, no post" 'chat.postMessage'
  stub_reset
  STUB_VARIANT=bad-open oerr "group send: missing open id stops" bad_open_response cli send U1 --with U2 -- Hello
  unsent "group send: malformed open, no post" 'chat.postMessage'

  stub_reset
  out=$(STUB_VARIANT=member-denied cli send U1 --with U2 -- Hello); rc=$?
  eq "group send: member denial fails send" 1 "$rc"
  want "group send: read denial preserves error" "$out" 'code="missing_scope"'
  want "group send: read denial preserves opened id" "$out" '<opened id="G400"/>'
  want "group send: read denial requests an id in the handback" "$out" 'Include opened conversation G400 in your reply'
  if xml_ok "$out"; then ok "group send: read denial is one XML document"
  else no "group send: read denial is one XML document" "$out"; fi
  unsent "group send: unverified audience gets no message" 'chat.postMessage'
  stub_reset
  STUB_VARIANT=member-mismatch oerr "group send: different audience stops" dm_members_unverified \
    cli send U1 --with U2 -- Hello
  unsent "group send: wrong audience gets no message" 'chat.postMessage'
  stub_reset
  STUB_FAIL=conversations.members oerr "group send: member transport failure stops" network_error \
    cli send U1 --with U2 -- Hello
  unsent "group send: failed membership gets no message" 'chat.postMessage'
  stub_reset
  out=$(STUB_VARIANT=post-denied cli send U1 --with U2 -- Hello)
  want "group send: post failure keeps opened id" "$out" '<opened id="G400"/>'
  want "group send: post failure keeps exact error" "$out" 'code="missing_scope"'
  want "group send: post failure requests an id in the handback" "$out" 'Include opened conversation G400 in your reply'
  want "group send: post failure still blocks a blind retry" "$out" 'Do not retry until then.'

  capf=$(mktemp "${TMPDIR:-/tmp}/slacker_group_file.XXXXXX"); printf 'notes\n' > "$capf"
  stub_reset
  STUB_VARIANT=group-dm xml "group send: caption and attachment" 'members_verified="true"' \
    send U1 --with U2 --file "$capf" --no-unfurl -- Caption
  sent "group send: upload shares to opened group" 'channel_id=G400'
  sent "group send: caption posts to opened group" 'channel=G400'
  stub_reset
  STUB_VARIANT=group-dm xml "group send: bare attachment" '<members count="3">' \
    send U1 --with U2 --file "$capf"
  unsent "group send: bare attachment has no caption post" 'chat.postMessage'
  stub_reset
  STUB_VARIANT=group-dm STUB_FAIL=conversations.members oerr "group send: no upload to unverified group" \
    network_error cli send U1 --with U2 --file "$capf"
  unsent "group send: membership failure never uploads" 'files.getUploadURLExternal'
  rm -f "$capf"
  stub_cleanup
}
