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
  want "escape: single-encode + strip ctrl" \
    "$(fx "{user:\"U1\",ts:\"1700000000.0\",text:\"a &gt; b &amp; c <x> end\"} | render_msg($U;{};{};\"\")")" \
    'a &gt; b &amp; c &lt;x&gt; end'
  want "deactivated author mark" \
    "$(fx "{user:\"U2\",ts:\"1700000000.0\",text:\"hi\"} | render_msg($U;{};{};\"\")")" 'deactivated="true"'
  want "tombstone file" \
    "$(fx "{user:\"U1\",ts:\"1700000000.0\",text:\"f\",files:[{id:\"F1\",mode:\"tombstone\"}]} | render_msg($U;{};{};\"\")")" 'deleted="true"'
  want "reactions resolved" \
    "$(fx "{user:\"U1\",ts:\"1700000000.0\",text:\"x\",reactions:[{name:\"tada\",count:1,users:[\"U1\"]}]} | render_msg($U;{};{};\"\")")" 'by="Alice"'
  want "forward share" \
    "$(fx "{user:\"U1\",ts:\"1700000000.0\",text:\"\",attachments:[{is_share:true,author_id:\"U1\",text:\"orig\"}]} | render_msg($U;{};{};\"\")")" '<forward'
  want "thread truncation marker" \
    "$(fx "{user:\"U1\",ts:\"1.0\",text:\"r\"} | render_msg($U;{};{\"1.0\":[{slacker_more:true}]};\"\")")" '<more note='
  want "target mark" \
    "$(fx "{user:\"U1\",ts:\"9.9\",text:\"x\"} | render_msg($U;{};{};\"9.9\")")" 'target="true"'
  want "blocks_to_text rich_text fallback" \
    "$(fx "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"hello \"},{type:\"user\",user_id:\"U1\"}]}]}]} | render_msg($U;{};{};\"\")")" 'hello @Alice'
  want "attachment text fallback (title+fallback)" \
    "$(fx "{user:\"U1\",ts:\"1.0\",text:\"\",attachments:[{title:\"TT\",fallback:\"FF\"}]} | render_msg($U;{};{};\"\")")" 'TT'
  want "mailto/link scheme decode" \
    "$(fx "\"see <mailto:a@b.com|write> and <https://x.com|site>\" | resolve_text($U;{}) | xml_escape")" 'write (mailto:a@b.com)'
  want "html_to_text numeric entity (decimal)" \
    "$(fx "\"&#25105;&lt;b&gt;\" | html_to_text | xml_escape")" '我'
  want "html_to_text numeric entity (hex)" \
    "$(fx "\"&#x6211;\" | html_to_text | xml_escape")" '我'
  want "bot author mark" \
    "$(fx "{bot_id:\"B1\",subtype:\"bot_message\",ts:\"1.0\",text:\"x\"} | render_msg({};{};{};\"\")")" 'bot="true"'
  want "empty message (no text/blocks)" \
    "$(fx "{user:\"U1\",ts:\"1.0\"} | render_msg($U;{};{};\"\")")" '<text></text>'
  want "system message (no user) -> unknown author" \
    "$(fx "{ts:\"1.0\",subtype:\"channel_join\",text:\"joined\"} | render_msg({};{};{};\"\")")" 'author="unknown"'
  want "message with only a file" \
    "$(fx "{user:\"U1\",ts:\"1.0\",files:[{name:\"a.pdf\",filetype:\"pdf\",size:9,url_private:\"https://x\"}]} | render_msg($U;{};{};\"\")")" '<file name="a.pdf"'
  want "reaction by unknown user -> shows id" \
    "$(fx "{user:\"U1\",ts:\"1.0\",text:\"x\",reactions:[{name:\"x\",count:1,users:[\"UZZZ\"]}]} | render_msg($U;{};{};\"\")")" 'by="UZZZ"'
  want "thread size marker (replies=N, not inlined)" \
    "$(fx "{user:\"U1\",ts:\"1.0\",text:\"x\",reply_count:3} | render_msg($U;{};{};\"\")")" 'replies="3"'

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
  errs "permalink: unparseable -> error" "couldn't parse" slacker_parse_permalink 'https://x.slack.com/nope'

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

  echo "== http.sh: error explainer =="
  has "explain: wrong token type" "USER token" \
    "$(slacker_explain_error search not_allowed_token_type '{}' 2>&1)"
  has "explain: missing_scope names the scope" "search:read" \
    "$(slacker_explain_error x missing_scope '{"needed":"search:read"}' 2>&1)"
  has "explain: channel_not_found hints Connect" "Slack Connect" \
    "$(slacker_explain_error x channel_not_found '{}' 2>&1)"
  has "explain: unknown code falls through" "API error on x: weird_code" \
    "$(slacker_explain_error x weird_code '{}' 2>&1)"

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
