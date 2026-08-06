#!/usr/bin/env bash
# unit.sh — offline unit tests: deterministic, no token, run in CI.
# Covers render.jq rendering, parse.sh pure resolution (user/permalink/time),
# http.sh error mapping, and the cache.sh update-check gating.
#   ./.dev/tests/unit.sh       run these directly
#   ./.dev/tests/run.sh        run the whole suite
# The `assert && ok || no` reporter pattern is intentional (ok/no never fail).
# shellcheck disable=SC2015
# shellcheck source-path=SCRIPTDIR

unit_tests(){
  echo "== render.jq fixtures =="
  local U='{U1:{n:"Alice",r:"Alice Lee",h:"alice",d:false},U2:{n:"Bob",d:true}}'
  wantfx "escape: single-encode + strip ctrl" \
    "{user:\"U1\",ts:\"1700000000.0\",text:\"a &gt; b &amp; c <x> end\"} | render_msg($U;{};{};\"\")" \
    'a &gt; b &amp; c &lt;x&gt; end'
  wantfx "deactivated author mark" \
    "{user:\"U2\",ts:\"1700000000.0\",text:\"hi\"} | render_msg($U;{};{};\"\")" 'deactivated="true"'
  wantfx "tombstone file" \
    "{user:\"U1\",ts:\"1700000000.0\",text:\"f\",files:[{id:\"F1\",mode:\"tombstone\"}]} | render_msg($U;{};{};\"\")" 'deleted="true"'
  wantfx "reactions resolved" \
    "{user:\"U1\",ts:\"1700000000.0\",text:\"x\",reactions:[{name:\"tada\",count:1,users:[\"U1\"]}]} | render_msg($U;{};{};\"\")" 'by="Alice"'
  wantfx "forward share" \
    "{user:\"U1\",ts:\"1700000000.0\",text:\"\",attachments:[{is_share:true,author_id:\"U1\",text:\"orig\"}]} | render_msg($U;{};{};\"\")" '<forward'
  wantfx "thread truncation marker" \
    "{user:\"U1\",ts:\"1.0\",text:\"r\"} | render_msg($U;{};{\"1.0\":[{slacker_more:true}]};\"\")" '<more note='
  wantfx "target mark" \
    "{user:\"U1\",ts:\"9.9\",text:\"x\"} | render_msg($U;{};{};\"9.9\")" 'target="true"'
  wantfx "blocks_to_text rich_text fallback" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"hello \"},{type:\"user\",user_id:\"U1\"}]}]}]} | render_msg($U;{};{};\"\")" 'hello @Alice'
  wantfx "block meta: action buttons with action_id" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"actions\",elements:[{type:\"button\",action_id:\"cotf-sugg:0\",text:{type:\"plain_text\",text:\"Retry\"}},{type:\"button\",action_id:\"cotf-sugg:1\",text:{type:\"plain_text\",text:\"Skip\"}}]}]} | render_msg($U;{};{};\"\")" \
    '<button action_id="cotf-sugg:0" label="Retry"/>'
  wantfx "block meta: retired card context (tapped state)" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"context\",elements:[{type:\"mrkdwn\",text:\"✓ Discard the code changes?\"}]}]} | render_msg($U;{};{};\"\")" \
    '<context text="✓ Discard the code changes?"/>'
  wantfx "block meta: section accessory button" \
    "{user:\"U1\",ts:\"1.0\",text:\"x\",blocks:[{type:\"section\",text:{type:\"mrkdwn\",text:\"body\"},accessory:{type:\"button\",action_id:\"ok\",text:{type:\"plain_text\",text:\"Approve\"}}}]} | render_msg($U;{};{};\"\")" \
    '<button action_id="ok" label="Approve"/>'
  wantfx "block meta: input renders label" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"input\",label:{text:\"Jira key\"},element:{placeholder:{text:\"ACE-123\"},type:\"plain_text_input\"}}]} | render_msg($U;{};{};\"\")" \
    '<input label="Jira key" placeholder="ACE-123"'
  wantfx "block meta: reply inlines buttons too" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"actions\",elements:[{type:\"button\",action_id:\"cotf-sugg:0\",text:{type:\"plain_text\",text:\"Go\"}}]}]} | render_reply($U;{};\"\")" \
    '<button action_id="cotf-sugg:0" label="Go"'
  local nm; nm=$(fx "{user:\"U1\",ts:\"1.0\",text:\"plain\"} | render_msg($U;{};{};\"\")")
  case "$nm" in *"<blocks>"*) no "block meta: plain message unchanged" "unexpected <blocks>";;
                *) ok "block meta: plain message unchanged" ;; esac
  wantfx "attachment text fallback (title+fallback)" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",attachments:[{title:\"TT\",fallback:\"FF\"}]} | render_msg($U;{};{};\"\")" 'TT'
  wantfx "mailto/link scheme decode" \
    "\"see <mailto:a@b.com|write> and <https://x.com|site>\" | resolve_text($U;{}) | xml_escape" 'write (mailto:a@b.com)'
  wantfx "html_to_text numeric entity (decimal)" \
    "\"&#25105;&lt;b&gt;\" | html_to_text | xml_escape" '我'
  wantfx "html_to_text numeric entity (hex)" \
    "\"&#x6211;\" | html_to_text | xml_escape" '我'
  wantfx "bot author mark" \
    "{bot_id:\"B1\",subtype:\"bot_message\",ts:\"1.0\",text:\"x\"} | render_msg({};{};{};\"\")" 'bot="true"'
  wantfx "empty message (no text/blocks)" \
    "{user:\"U1\",ts:\"1.0\"} | render_msg($U;{};{};\"\")" '<text></text>'
  wantfx "system message (no user) -> unknown author" \
    "{ts:\"1.0\",subtype:\"channel_join\",text:\"joined\"} | render_msg({};{};{};\"\")" 'author="unknown"'
  wantfx "message with only a file" \
    "{user:\"U1\",ts:\"1.0\",files:[{name:\"a.pdf\",filetype:\"pdf\",size:9,url_private:\"https://x\"}]} | render_msg($U;{};{};\"\")" '<file name="a.pdf"'
  wantfx "reaction by unknown user -> shows id" \
    "{user:\"U1\",ts:\"1.0\",text:\"x\",reactions:[{name:\"x\",count:1,users:[\"UZZZ\"]}]} | render_msg($U;{};{};\"\")" 'by="UZZZ"'
  wantfx "thread size marker (replies=N, not inlined)" \
    "{user:\"U1\",ts:\"1.0\",text:\"x\",reply_count:3} | render_msg($U;{};{};\"\")" 'replies="3"'

  echo "== parse.sh: user resolution (fuzzy) =="
  local uf; uf="$(mktemp -d)/users.json"
  printf '%s' '{"U1":{"n":"Alice","r":"Alice Lee","h":"alice","d":false},"U2":{"n":"Bob Tan","r":"Bob Tan","h":"btan","d":false},"U3":{"n":"Bob Lim","r":"Bob Lim","h":"blim","d":false}}' > "$uf"
  eq "fuzzy: real-name exact" U1 "$(slacker_resolve_user 'Alice Lee' "$uf" 2>/dev/null)"
  eq "fuzzy: substring"       U1 "$(slacker_resolve_user 'alice' "$uf" 2>/dev/null)"
  if ! slacker_resolve_user 'bob' "$uf" >/dev/null 2>&1; then ok "fuzzy: ambiguous -> error"; else no "fuzzy: ambiguous -> error" "should fail"; fi
  rm -rf "$(dirname "$uf")" 2>/dev/null

  echo "== parse.sh: permalink =="
  eq "permalink: top-level" \
    "$(printf 'C123\t1700000000.123456\t')" \
    "$(slacker_parse_permalink 'https://x.slack.com/archives/C123/p1700000000123456')"
  eq "permalink: reply carries thread_ts" \
    "$(printf 'C123\t1700000000.123456\t1699999999.000100')" \
    "$(slacker_parse_permalink 'https://x.slack.com/archives/C123/p1700000000123456?thread_ts=1699999999.000100&cid=C123')"
  oerr "permalink: unparseable -> bad_permalink" bad_permalink slacker_parse_permalink 'https://x.slack.com/nope'

  echo "== parse.sh: time =="
  # parse_when is minute-precise: BSD `date -j` fills unspecified seconds from the
  # current clock (GNU uses :00), so pin TZ and compare floored to the minute
  # (÷60) — 2024-01-30 12:00 UTC = epoch 1706616000 = minute 28443600.
  eq "to_epoch: raw epoch passthrough" 1700000000 "$(slacker_to_epoch 1700000000)"
  eq "parse_when: 'YYYY-MM-DD HH:MM' (UTC, minute)" 28443600 "$(( $(TZ=UTC slacker_parse_when '2024-01-30 12:00') / 60 ))"
  eq "parse_when: ISO 'YYYY-MM-DDTHH:MM' (UTC, minute)" 28443600 "$(( $(TZ=UTC slacker_parse_when '2024-01-30T12:00') / 60 ))"
  eq "to_epoch: routes datetime through parse_when (UTC, minute)" 28443600 "$(( $(TZ=UTC slacker_to_epoch '2024-01-30 12:00') / 60 ))"
  if ! slacker_parse_when 'not-a-date' >/dev/null 2>&1; then ok "parse_when: garbage -> nonzero"; else no "parse_when: garbage -> nonzero" "should fail"; fi
  # relative "N<unit> ago": compare the span to now, allowing a few seconds slack.
  d=$(( $(date +%s) - $(slacker_to_epoch 7d) ))
  if [ "$d" -ge 604795 ] && [ "$d" -le 604805 ]; then ok "to_epoch: relative 7d (ago)"; else no "to_epoch: relative 7d (ago)" "delta $d"; fi
  d=$(( $(date +%s) - $(slacker_to_epoch 2w) ))
  if [ "$d" -ge 1209595 ] && [ "$d" -le 1209605 ]; then ok "to_epoch: relative 2w (ago)"; else no "to_epoch: relative 2w (ago)" "delta $d"; fi

  # Slack's `after:` is day-granular and exclusive, so since_to_after shifts the
  # boundary back a day to keep --since inclusive. Pin TZ: the epoch -> calendar
  # day mapping is local-time dependent. 1700000000 = 2023-11-14 UTC.
  eq "epoch_to_date: epoch -> calendar day (UTC)" 2023-11-14 "$(TZ=UTC slacker_epoch_to_date 1700000000)"
  eq "since_to_after: raw epoch shifts back a day"  2023-11-13 "$(TZ=UTC slacker_since_to_after 1700000000)"
  eq "since_to_after: 'YYYY-MM-DD' shifts back a day" 2024-01-29 "$(TZ=UTC slacker_since_to_after '2024-01-30')"
  eq "since_to_after: relative 7d lands 8 days back" \
    "$(TZ=UTC slacker_epoch_to_date $(( $(date +%s) - 8 * 86400 )))" \
    "$(TZ=UTC slacker_since_to_after 7d)"

  echo "== http.sh: structured <error> emitter =="
  # Direct calls have fd 3 closed, so slacker_error falls back to stdout; 2>&1
  # captures the emitted XML.
  local e
  e=$(slacker_explain_error search not_allowed_token_type '{}' 2>&1)
  want "explain: well-formed <error>"           "$e" '<error'
  has  "explain: wrong token type -> code"       'code="not_allowed_token_type"' "$e"
  has  "explain: wrong token type -> escalate"   'action="escalate"'             "$e"
  e=$(slacker_explain_error x missing_scope '{"needed":"search:read"}' 2>&1)
  has  "explain: missing_scope names the scope"  'search:read' "$e"
  e=$(slacker_explain_error x channel_not_found '{}' 2>&1)
  has  "explain: channel_not_found hints Connect" 'Slack Connect' "$e"
  e=$(slacker_explain_error x weird_code '{}' 2>&1)
  has  "explain: unknown code -> code attr"      'code="weird_code"' "$e"
  has  "explain: unknown code -> escalate"       'action="escalate"' "$e"
  e=$(slacker_explain_error chat.postMessage msg_too_long '{}' 2>&1)
  has  "explain: msg_too_long -> recover"        'action="recover"'  "$e"
  # slacker_error escapes content exactly once and stays well-formed.
  e=$(slacker_error demo recover "a & b < c" "do > x" 2>&1)
  want "emit: escaped once + well-formed"        "$e" 'a &amp; b &lt; c'

  # Every mapped code: the agent acts on the `action` attribute, so a wrong or
  # missing one sends it down the wrong path. Each arm is asserted explicitly.
  # recover = run the suggested fix; escalate = stop and ask a human.
  local code
  for code in invalid_auth not_authed token_revoked token_expired account_inactive \
              channel_not_found not_in_channel is_archived channel_not_open \
              user_not_found users_not_found no_permission restricted_action \
              cant_update_message cant_delete_message message_not_found \
              file_not_found file_deleted; do
    e=$(slacker_explain_error demo "$code" '{}' 2>&1)
    has "explain: $code -> escalate" 'action="escalate"' "$e"
  done
  for code in thread_not_found msg_too_long rate_limited ratelimited; do
    e=$(slacker_explain_error demo "$code" '{}' 2>&1)
    has "explain: $code -> recover" 'action="recover"' "$e"
  done
  e=$(slacker_explain_error demo rate_limited '{}' 2>&1)
  has "explain: rate_limited mentions retries" 'automatic retries' "$e"
  e=$(slacker_explain_error demo thread_not_found '{}' 2>&1)
  has "explain: thread_not_found asks for a permalink" 'permalink' "$e"
  e=$(slacker_explain_error demo users_not_found '{}' 2>&1)
  has "explain: users_not_found names the ids" "ids weren't found" "$e"

  echo "== http.sh: token shape warnings =="
  # Warnings only; a non-xoxp token must still be allowed through, because the
  # read surface works fine with a bot token.
  local w
  w=$(SLACKER_SH_TOKEN=xoxb-bot slacker_require_token 2>&1)
  has "require_token: bot token warns"        'bot token detected' "$w"
  w=$(SLACKER_SH_TOKEN=nonsense slacker_require_token 2>&1)
  has "require_token: odd token shape warns"  "doesn't look like"  "$w"
  w=$(SLACKER_SH_TOKEN=xoxp-good slacker_require_token 2>&1)
  eq   "require_token: user token is silent"  "" "$w"

  echo "== parse.sh: structured error codes =="
  oerr "to_epoch: bad date -> bad_date"   bad_date  slacker_to_epoch 'not-a-date'
  oerr "when_epoch: bad time -> bad_time"  bad_time  slacker_when_epoch 'half past nope'
  # since_to_after resolves its epoch in a $(…), so the inner slacker_error only
  # escapes via fd 3 — the dup the dispatcher opens (slacker.sh: exec 3>&1) and
  # that oerr's direct call leaves closed. Reopen it to match production.
  with_fd3(){ "$@" 3>&1; }
  oerr "since_to_after: bad date -> bad_date" bad_date with_fd3 slacker_since_to_after 'not-a-date'

  echo "== parse.sh: message signature (opt-out footer) =="
  local sig_default='Sent using github.com/CJHwong/slacker.sh'
  eq "signature: unset -> default footer (bare url)" "$sig_default" \
    "$(unset SLACKER_SH_SIGNATURE; slacker_signature_text)"
  eq "signature: =1 -> default footer"   "$sig_default" "$(SLACKER_SH_SIGNATURE=1 slacker_signature_text)"
  eq "signature: empty -> off"   "" "$(SLACKER_SH_SIGNATURE='' slacker_signature_text)"
  eq "signature: off -> off"     "" "$(SLACKER_SH_SIGNATURE=off slacker_signature_text)"
  eq "signature: 0 -> off"       "" "$(SLACKER_SH_SIGNATURE=0 slacker_signature_text)"
  eq "signature: custom -> verbatim" "via bot" "$(SLACKER_SH_SIGNATURE='via bot' slacker_signature_text)"
  has "signed_blocks: markdown body block" '"type":"markdown"' "$(slacker_signed_blocks 'hi' '' 'sig')"
  has "signed_blocks: context footer"      '"type":"context"'  "$(slacker_signed_blocks 'hi' '' 'sig')"
  has "signed_blocks: raw -> section body" '"type":"section"'  "$(slacker_signed_blocks 'hi' 'x' 'sig')"
  # body_args writes a global out-param array; print it so `has` can inspect it.
  _body_args_out(){ slacker_body_args "$1" "$2"; printf '%s\n' "${SLACKER_SH_BODY_ARGS[@]}"; }
  has "body_args: unsigned -> markdown_text field" 'markdown_text=hi' \
    "$(SLACKER_SH_SIGNATURE=off _body_args_out 'hi' '')"
  has "body_args: signed -> blocks param" 'blocks=' \
    "$(SLACKER_SH_SIGNATURE=1 _body_args_out 'hi' '')"
  has "body_args: signed -> text fallback" 'text=hi' \
    "$(SLACKER_SH_SIGNATURE=1 _body_args_out 'hi' '')"

  echo "== actions/read-message: not-found path (regression: unset \$msg under set -u) =="
  # The network boundary is stubbed so the real action code runs to its
  # message_not_found branch. Before the fix, msg was declared unset; under the
  # harness's set -u the guard exploded with "msg: unbound variable" and emitted
  # NO result. oerr runs this in a subshell, so the stubs stay scoped to it.
  # The empty-JSON stand-in is created and removed by the caller: oerr runs the
  # body in a command-substitution subshell, so anything the body cleans up on its
  # own way out is unreliable, and the original fixed filename was never removed
  # at all (and was shared between concurrent runs).
  local ej; ej=$(mktemp "${TMPDIR:-/tmp}/slacker_rm_empty.XXXXXX")
  printf '{}' > "$ej"
  _slacker_rm_notfound(){
    slacker_users_cache(){ printf '%s' "$ej"; }
    slacker_channels_cache(){ printf '%s' "$ej"; }
    slacker_parse_permalink(){ printf 'C0RTEST\t1700000000.000100\t'; }  # no thread_ts
    slacker_api(){ printf '{"messages":[]}'; }                           # message not found
    # shellcheck source=../../actions/read-message.sh
    . "$SLACKER_ROOT/actions/read-message.sh" \
      'https://x.slack.com/archives/C0RTEST/p1700000000000100' --no-thread
  }
  oerr "read-message: permalink to missing msg -> message_not_found" \
    message_not_found _slacker_rm_notfound
  rm -f "$ej"

  echo "== cache.sh: token key (regression: silent exit 127 with no shasum) =="
  # shasum is a perl script and is absent on Alpine and other slim images. When
  # this was a bare `| shasum |` pipeline it returned 127 under the dispatcher's
  # `set -euo pipefail` and killed slacker.sh with empty stdout AND stderr. The
  # key must still be produced with no digest tool on PATH, and must not change
  # for existing users (their cache directory would otherwise move).
  # Only meaningful where shasum exists (macOS, most Debian images) — that is the
  # population whose cache directory must not move.
  if command -v shasum >/dev/null 2>&1; then
    eq "token key: matches the historical shasum-derived key" \
      "$(printf '%s' 'xoxp-demo' | shasum | cut -c1-12)" \
      "$(SLACKER_SH_TOKEN=xoxp-demo slacker__token_key)"
  else
    ok "token key: historical-key check skipped (no shasum)"
  fi
  local nopath; nopath=$(mktemp -d)
  eq "token key: still produced with no digest tool on PATH" \
    "nodigest" \
    "$(PATH="$nopath" SLACKER_SH_TOKEN=xoxp-demo slacker__token_key)"
  # The real contract: a digest-less host must not abort the command. The
  # PATH/token overrides are deliberately scoped to this subshell.
  # shellcheck disable=SC2030,SC2031
  if ( set -euo pipefail; PATH="$nopath"; SLACKER_SH_TOKEN=xoxp-demo; slacker__token_key >/dev/null )
    then ok "token key: non-fatal under set -euo pipefail"
    else no "token key: non-fatal under set -euo pipefail" "aborted"; fi
  rm -rf "$nopath" 2>/dev/null

  echo "== cache.sh: update check (synthetic git clone) =="
  # Its one hard contract is that it must never abort a command, so the non-git
  # case runs under `set -e`.
  if command -v git >/dev/null 2>&1; then
    local ut ng m1 m2 m3
    ut=$(mktemp -d)
    { git init -q --bare "$ut/up.git"
      git clone -q "$ut/up.git" "$ut/work"
      ( cd "$ut/work"; git config user.email t@t; git config user.name t
        echo a>a; git add a; git commit -qm init; git push -q -u origin HEAD )
      git clone -q "$ut/up.git" "$ut/w2"
      ( cd "$ut/w2"; git config user.email t@t; git config user.name t
        echo b>b; git add b; git commit -qm two; git push -q origin HEAD )
    } >/dev/null 2>&1
    # Pin the disable flag per-case so these hold regardless of the caller's env.
    m1=$(SLACKER_SH_NO_UPDATE_CHECK=0 SLACKER_ROOT="$ut/work" SLACKER_CACHE_DIR="$ut/c/tok" slacker_check_update 2>&1 || true)
    printf '%s' "$m1" | grep -q 'update available' && ok "update check: behind -> notice" || no "update check: behind -> notice" "got: $m1"
    m2=$(SLACKER_SH_NO_UPDATE_CHECK=0 SLACKER_ROOT="$ut/work" SLACKER_CACHE_DIR="$ut/c/tok" slacker_check_update 2>&1 || true)
    [ -z "$m2" ] && ok "update check: throttled -> silent" || no "update check: throttled -> silent" "got: $m2"
    m3=$(SLACKER_SH_NO_UPDATE_CHECK=1 SLACKER_ROOT="$ut/work" SLACKER_CACHE_DIR="$ut/c2/tok" slacker_check_update 2>&1 || true)
    [ -z "$m3" ] && ok "update check: disabled -> silent" || no "update check: disabled -> silent" "got: $m3"
    ng=$(mktemp -d)
    # The exports are deliberately scoped to this subshell (that's the point).
    # shellcheck disable=SC2030,SC2031
    if ( set -euo pipefail; export SLACKER_SH_NO_UPDATE_CHECK=0 SLACKER_ROOT="$ng" SLACKER_CACHE_DIR="$ut/c3/tok"; slacker_check_update ) >/dev/null 2>&1
      then ok "update check: non-git -> non-fatal (set -e)"; else no "update check: non-git -> non-fatal (set -e)" "aborted"; fi
    rm -rf "$ut" "$ng" 2>/dev/null
  else
    ok "update check: skipped (no git)"
  fi
}

# Run when executed directly; stay quiet (just define unit_tests) when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helpers.sh
  . "$DIR/helpers.sh"
  unit_tests
  summary
fi
