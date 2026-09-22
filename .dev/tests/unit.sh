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
  wantfx "flattened .text falls back to blocks (list)" \
    "{user:\"U1\",ts:\"1.0\",text:\"top A B\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"top\"}]},{type:\"rich_text_list\",indent:0,elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"A\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    '• A'
  wantfx "flattened .text falls back to blocks (multi-section)" \
    "{user:\"U1\",ts:\"1.0\",text:\"one two\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"one\"}]},{type:\"rich_text_section\",elements:[{type:\"text\",text:\"two\"}]}]}]} | render_msg($U;{};{};\"\")" \
    'one
two'
  wantfx "nested list keeps its indent" \
    "{user:\"U1\",ts:\"1.0\",text:\"P D\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_list\",indent:0,elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"P\"}]}]},{type:\"rich_text_list\",indent:1,elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"D\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    '  • D'
  local kept; kept=$(fx "{user:\"U1\",ts:\"1.0\",text:\"*bold* line\\nsecond line\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_list\",indent:0,elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"A\"}]}]}]}]} | render_msg($U;{};{};\"\")")
  case "$kept" in *"*bold* line"*) ok "multi-line .text wins over blocks" ;;
                  *) no "multi-line .text wins over blocks" "blocks overrode a good .text" ;; esac
  # A one-liner .text with blocks now flips to blocks (any flattened shape does),
  # so markers survive via styled_text, not via .text. Real Slack stores the
  # styles on the block runs; an unstyled run next to a marker-carrying .text
  # does not occur on the wire.
  local single; single=$(fx "{user:\"U1\",ts:\"1.0\",text:\"*bold* one-liner\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"bold\",style:{bold:true}},{type:\"text\",text:\" one-liner\"}]}]}]} | render_msg($U;{};{};\"\")")
  case "$single" in *"*bold* one-liner"*) ok "single-section one-liner keeps markers" ;;
                    *) no "single-section one-liner keeps markers" "lost the emphasis on the flip" ;; esac
  wantfx "blocks walker re-emits code style" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"bold\",style:{code:true}},{type:\"text\",text:\" and \"},{type:\"text\",text:\"code\",style:{code:true}},{type:\"text\",text:\" die together.\"}]}]}]} | render_msg($U;{};{};\"\")" \
    "\`bold\` and \`code\` die together."
  wantfx "blocks walker re-emits combined bold and italic" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"word\",style:{bold:true,italic:true}}]}]}]} | render_msg($U;{};{};\"\")" \
    '*_word_*'
  wantfx "blocks walker re-emits strike" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"gone\",style:{strike:true}}]}]}]} | render_msg($U;{};{};\"\")" \
    '~gone~'
  wantfx "blocks walker leaves unstyled runs bare" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"plain\",style:{}}]}]}]} | render_msg($U;{};{};\"\")" \
    'plain'
  wantfx "styled text inside a list-bearing message (the bullet repro)" \
    "{user:\"U1\",ts:\"1.0\",text:\"one liner\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"say \"},{type:\"text\",text:\"hi\",style:{code:true}},{type:\"text\",text:\" and \"},{type:\"text\",text:\"loud\",style:{bold:true}}]},{type:\"rich_text_list\",indent:0,elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"bullet line\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    "say \`hi\` and *loud*
• bullet line"
  wantfx "single-section flattened .text falls back to blocks" \
    "{user:\"U1\",ts:\"1.0\",text:\"one two x and bold\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"one\"},{type:\"text\",text:\"\n\"},{type:\"text\",text:\"two with \"},{type:\"text\",text:\"x\",style:{code:true}},{type:\"text\",text:\" and \"},{type:\"text\",text:\"bold\",style:{bold:true}},{type:\"text\",text:\"\n\"},{type:\"text\",text:\"three\"}]}]}]} | render_msg($U;{};{};\"\")" \
    "one
two with \`x\` and *bold*
three"
  wantfx "flattened .text with no rich_text blocks keeps .text" \
    "{user:\"U1\",ts:\"1.0\",text:\"a b c\",blocks:[{type:\"divider\"}]} | render_msg($U;{};{};\"\")" \
    'a b c'
  # The flip must never blank a body: an empty section renders nothing, so the
  # reader falls back to the .text copy the sender wrote.
  wantfx "empty section render falls back to .text" \
    "{user:\"U1\",ts:\"1.0\",text:\"real content here\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[]}]}]} | render_msg($U;{};{};\"\")" \
    'real content here'
  # Blocks carry mention ids only; the .text copy carries the labels. The walker
  # recovers them so a cache miss cannot downgrade a name to a raw id.
  wantfx "usergroup mention keeps its label from .text" \
    "{user:\"U1\",ts:\"1.0\",text:\"<!subteam^S123|@platform-team> deploy\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"usergroup\",usergroup_id:\"S123\"},{type:\"text\",text:\" deploy\"}]}]}]} | render_msg($U;{};{};\"\")" \
    '@platform-team deploy'
  wantfx "channel mention keeps its label when the cache misses" \
    "{user:\"U1\",ts:\"1.0\",text:\"see <#C123|general> now\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"see \"},{type:\"channel\",channel_id:\"C123\"},{type:\"text\",text:\" now\"}]}]}]} | render_msg($U;{};{};\"\")" \
    'see #general now'
  # Slack nests sections inside quote and preformatted containers. The walker
  # must render the runs inside them, and a code block reads back fenced.
  wantfx "preformatted block renders fenced code" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_preformatted\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"code line\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    "\`\`\`code line\`\`\`"
  wantfx "one-line fenced code keeps its fences" \
    "{user:\"U1\",ts:\"1.0\",text:\"\`\`\`foo\`\`\`\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_preformatted\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"foo\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    "\`\`\`foo\`\`\`"
  wantfx "quote block renders its runs" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_quote\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"quoted words\"}]}]}]}]} | render_msg($U;{};{};\"\")" \
    '&gt; quoted words'
  # Slack styles link, user and usergroup runs like text runs, so the wrapper
  # applies at the section level and no element branch can drop the markers.
  wantfx "styled link keeps its markers" \
    "{user:\"U1\",ts:\"1.0\",text:\"see *<https://go.dev|the doc>* now\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"see \"},{type:\"link\",url:\"https://go.dev\",text:\"the doc\",style:{bold:true}},{type:\"text\",text:\" now\"}]}]}]} | render_msg($U;{};{};\"\")" \
    'see *the doc (https://go.dev)* now'
  wantfx "styled user keeps its markers" \
    "{user:\"U1\",ts:\"1.0\",text:\"ping *<@U1>*\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"ping \"},{type:\"user\",user_id:\"U1\",style:{bold:true}}]}]}]} | render_msg($U;{U1:{n:\"Alice\"}};{};\"\")" \
    'ping *@Alice*'
  # A style that is not an object (app bug, future shape) renders bare instead
  # of crashing the whole render.
  wantfx "non-object style renders bare" \
    "{user:\"U1\",ts:\"1.0\",text:\"\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"x\",style:\"bold\"}]}]}]} | render_msg($U;{};{};\"\")" \
    'x'
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

  # Slack stores a markdown table as a table block (rows of rich_text cells,
  # column_settings alignment); its .text fallback drops the table. The reader
  # must rebuild the markdown from the block, not read the fallback.
  wantfx "table block: renders rows with alignment" \
    "{user:\"U1\",ts:\"1.0\",text:\"t\",blocks:[{type:\"table\",column_settings:[{},{\"align\":\"right\"},{}],rows:[[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"Metric\"}]}]},{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"Current\"}]}]},{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"Note\"}]}]}],[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"CPU\"}]}]},{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"92.5%\"}]}]},{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"High\"}]}]}]]}]} | render_msg($U;{};{};\"\")" \
    '| --- | ---: | --- |'

  # The cell escape and the resolved-cell path, held separately from alignment.
  # A gsub replacement is a plain string, so the pipe escape is one backslash:
  # a doubled one leaves the pipe breaking the row and ships a stray \ with it.
  # shellcheck disable=SC2016 # $t is jq's parameter, not the shell's.
  local tc='def tc($t): {type:"rich_text",elements:[{type:"rich_text_section",elements:[{type:"text",text:$t}]}]};'
  wantfx "table block: a cell pipe is escaped, not doubled" \
    "$tc {user:\"U1\",ts:\"1.0\",text:\"t\",blocks:[{type:\"table\",rows:[[tc(\"a|b\"),tc(\"h\")],[tc(\"x\"),tc(\"y\")]]}]} | render_msg($U;{};{};\"\")" \
    '| a\|b | h |'
  wantfx "table block: a cell resolves mentions, links and styles" \
    "$tc {user:\"U1\",ts:\"1.0\",text:\"t\",blocks:[{type:\"table\",rows:[[tc(\"Who\"),tc(\"Doc\")],[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"user\",user_id:\"U1\",style:{bold:true}}]}]},{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"link\",url:\"https://x.test/d\",text:\"doc\"}]}]}]]}]} | render_msg($U;{};{};\"\")" \
    '| *@Alice* | doc (https://x.test/d) |'
  # Slack's .text for a table message ends ", with interactive elements" and
  # holds no table, so a table block must send the read to the blocks instead.
  local tbl; tbl=$(fx "$tc {user:\"U1\",ts:\"1.0\",text:\"Alert summary, with interactive elements\",blocks:[{type:\"rich_text\",elements:[{type:\"rich_text_section\",elements:[{type:\"text\",text:\"Alert summary\"}]}]},{type:\"table\",rows:[[tc(\"Metric\"),tc(\"Current\")],[tc(\"CPU\"),tc(\"92%\")]]}]} | render_msg($U;{};{};\"\")")
  has "table block: the table survives the .text artifact" '| CPU | 92% |' "$tbl"
  hasnt "table block: the .text artifact is not the body" ', with interactive elements' "$tbl"
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
  # Measured live, not read from a doc: chat.postMessage caps at 12000 characters,
  # so the old "~40k chars" hint let a caller split to a size that still failed.
  e=$(slacker_explain_error chat.postMessage msg_too_long '{}' 2>&1)
  has  "explain: msg_too_long -> recover"          'action="recover"' "$e"
  has  "explain: msg_too_long names 12000 chars"   '12000-character'  "$e"
  hasnt "explain: msg_too_long drops the 40k claim" '40k'             "$e"
  # chat.update has two ceilings in two units. Which one applies depends on
  # whether the request carried a text parameter, so the message must not
  # hardcode either: 4000 BYTES with one, 12000 CHARACTERS on markdown_text.
  # The subshell scoping is the point: each case sets one state and nothing leaks.
  # shellcheck disable=SC2030,SC2031
  ( unset SLACKER_SH_SENT_TEXT_PARAM
    e=$(slacker_explain_error chat.update msg_too_long '{}' 2>&1)
    has  "explain: chat.update markdown_text -> 12000 characters" '12000-character' "$e"
    hasnt "explain: chat.update markdown_text drops the byte cap" '4000 bytes'      "$e" )
  # shellcheck disable=SC2030,SC2031
  ( SLACKER_SH_SENT_TEXT_PARAM=1
    e=$(slacker_explain_error chat.update msg_too_long '{}' 2>&1)
    has  "explain: chat.update text param -> 4000 bytes"    '4000 bytes'          "$e"
    has  "explain: chat.update text param names the cause"  'SLACKER_SH_SIGNATURE' "$e" )
  # send is NOT an escape hatch: chat.postMessage caps at 12000 characters too,
  # so advising delete-and-repost destroys the original and then fails.
  e=$(slacker_explain_error chat.update msg_too_long '{}' 2>&1)
  hasnt "explain: chat.update never claims send is uncapped" 'no such cap' "$e"
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

  echo "== parse.sh: canvas body and table shape =="
  # A canvas table renders only from contiguous rows. Writing the body with a
  # blank line between rows is the easy mistake: Slack answers ok and renders
  # prose, so the failure is silent without this guard.
  local mf cf; mf=$(mktemp "${TMPDIR:-/tmp}/slacker_umd.XXXXXX")
  cf=$(mktemp "${TMPDIR:-/tmp}/slacker_ucf.XXXXXX")
  printf '# T\n\n|a|b|\n|--|--|\n|1|2|\n' > "$mf"
  printf '## H\n\n| a | b |\n\n|---|---|\n\n| 1 | 2 |\n' > "$cf"
  eq "table_break_line: contiguous rows pass" "" "$(slacker_table_break_line "$mf")"
  # The false-positive guard: two tables stacked with a blank line between them
  # is legal markdown, and the second one opens with a header, so it must pass.
  printf '|a|b|\n|--|--|\n|1|2|\n\n|c|d|\n|--|--|\n|3|4|\n' > "$cf"
  eq "table_break_line: two stacked tables are legal" "" "$(slacker_table_break_line "$cf")"
  printf '## H\n\n| a | b |\n\n|---|---|\n\n| 1 | 2 |\n' > "$cf"
  eq "table_break_line: blank line inside a table is line 3" "3" "$(slacker_table_break_line "$cf")"
  # A CRLF body must behave identically. Without stripping the CR, a "blank" line
  # is not blank, so the guard goes blind on exactly the file it should catch.
  printf '## H\r\n\r\n| a | b |\r\n\r\n|---|---|\r\n\r\n| 1 | 2 |\r\n' > "$cf"
  eq "table_break_line: CRLF blank line inside a table is line 3" "3" "$(slacker_table_break_line "$cf")"
  printf '# T\r\n\r\n|a|b|\r\n|--|--|\r\n|1|2|\r\n' > "$cf"
  eq "table_break_line: CRLF contiguous rows pass" "" "$(slacker_table_break_line "$cf")"
  printf '|a|b|\r\n|--|--|\r\n|1|2|\r\n\r\n|c|d|\r\n|--|--|\r\n|3|4|\r\n' > "$cf"
  eq "table_break_line: CRLF two stacked tables are legal" "" "$(slacker_table_break_line "$cf")"
  # A table nested under a list item is indented. Leading whitespace must not put
  # it out of the guard's reach.
  printf -- '- item\n\n  | a | b |\n\n  |---|---|\n\n  | 1 | 2 |\n' > "$cf"
  eq "table_break_line: an indented broken table is still caught" "3" "$(slacker_table_break_line "$cf")"
  printf -- '- item\n\n  |a|b|\n  |--|--|\n  |1|2|\n' > "$cf"
  eq "table_break_line: a valid indented table passes" "" "$(slacker_table_break_line "$cf")"
  eq "check_table_rows: valid body is silent" "" "$(slacker_check_table_rows "$mf")"
  # Give this case its own broken body: the CRLF cases above left $cf legal.
  printf '## H\n\n| a | b |\n\n|---|---|\n\n| 1 | 2 |\n' > "$cf"
  oerr "check_table_rows: blank line -> table_not_contiguous" \
       table_not_contiguous slacker_check_table_rows "$cf"
  # The VALUE of the document_content field, never a wrapper around it. A wrapper
  # reaches Slack as an object with no type and no markdown, so the canvas comes
  # back empty, and no offline test can see that: the stub records argv and never
  # dereferences curl's name@path form.
  eq "canvas_document: emits the bare document_content value" \
     "$(jq -Rs '{type:"markdown",markdown:.}' < "$mf")" \
     "$(slacker_canvas_document "$mf")"
  hasnt "canvas_document: is not wrapped in a document_content key" '"document_content"' \
     "$(slacker_canvas_document "$mf")"
  eq "canvas_changes: replace emits one entry" \
     "$(jq -Rs '[{operation:"replace",document_content:{type:"markdown",markdown:.}}]' < "$mf")" \
     "$(slacker_canvas_changes "$mf" replace)"
  has "canvas_changes: passes the operation through" '"operation": "insert_at_end"' \
     "$(slacker_canvas_changes "$mf" insert_at_end)"
  eq "canvas_id_from: a bare id passes through"  "F0800CANV" "$(slacker_canvas_id_from F0800CANV)"
  eq "canvas_id_from: a permalink yields the id" "F0800CANV" \
     "$(slacker_canvas_id_from 'https://x.slack.com/docs/T1/F0800CANV')"
  eq "canvas_id_from: no id yields empty"        "" "$(slacker_canvas_id_from 'nothing-here')"
  rm -f "$mf" "$cf"

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

  echo "== render.jq: a reply's sub-blocks nest inside the reply =="
  # The block helpers are written for a top-level <message> (2 spaces). A <reply>
  # opens at 6, so without indent_reply its blocks/reactions/files came out at
  # message depth and read as if they had escaped the reply.
  eq "indent_reply: empty stays empty" "" "$(fx '("" | indent_reply)')"
  eq "indent_reply: adds one reply level" "    <a/>" "$(fx '("<a/>" | indent_reply)')"
  # Two lines, so the assertion survives command substitution stripping a
  # trailing newline. A blank line must stay blank, not become whitespace.
  eq "indent_reply: indents each line, blanks stay blank" "    <a/>

    <b/>" "$(fx '("<a/>\n\n<b/>" | indent_reply)')"
  local rep
  rep=$(fx '({ts:"1.0", user:"U1", text:"hi", reactions:[{name:"tada",count:1,users:["U1"]}]}
             | render_reply({}; {}; "none"))')
  want "render_reply: reactions sit inside the reply" "$rep" '        <reactions>'
  hasnt "render_reply: no reaction at message depth" '
    <reactions>' "$rep"

  echo "== parse.sh: argument guards (regression: raw bash errors, empty stdout) =="
  # A trailing flag left "$2" unset. Under `set -u` that aborted the action with
  # a bash diagnostic naming an internal file and line, and no <error> at all.
  oerr "flag_value: a trailing flag -> missing_flag_value" missing_flag_value \
       slacker_flag_value --since 1
  ( slacker_flag_value --since 2 ) && ok "flag_value: a value present passes" \
    || no "flag_value: a value present passes" "returned non-zero"
  # A non-numeric count reached $(( )) and aborted with an arithmetic error.
  oerr "count_value: letters -> bad_count"  bad_count slacker_count_value --limit abc
  oerr "count_value: negative -> bad_count" bad_count slacker_count_value --limit -5
  oerr "count_value: empty -> bad_count"    bad_count slacker_count_value --limit ''
  oerr "count_value: hex -> bad_count"      bad_count slacker_count_value --limit 0x10
  ( slacker_count_value --limit 200 ) && ok "count_value: a whole number passes" \
    || no "count_value: a whole number passes" "returned non-zero"

  echo "== cache.sh: an unparseable map is stale, not a confident wrong answer =="
  # A truncated write used to pass the TTL check and then fail at the jq read,
  # where the miss surfaced as user_not_found — wrong, and escalated to a human.
  local badc; badc=$(mktemp -d "${TMPDIR:-/tmp}/slacker_badcache.XXXXXX")
  printf '{"C1":"ok"}' > "$badc/good.json"
  printf 'garbage not json {{{' > "$badc/bad.json"
  printf '' > "$badc/empty.json"
  ( SLACKER_CACHE_TTL=999999999; slacker_cache_stale "$badc/good.json" ) \
    && no "cache_stale: valid JSON within TTL is fresh" "reported stale" \
    || ok "cache_stale: valid JSON within TTL is fresh"
  ( SLACKER_CACHE_TTL=999999999; slacker_cache_stale "$badc/bad.json" ) \
    && ok "cache_stale: unparseable JSON is stale" \
    || no "cache_stale: unparseable JSON is stale" "reported fresh"
  ( SLACKER_CACHE_TTL=999999999; slacker_cache_stale "$badc/empty.json" ) \
    && ok "cache_stale: an empty file is stale" \
    || no "cache_stale: an empty file is stale" "reported fresh"

  echo "== render.jq: a non-string .text renders instead of killing the payload =="
  # Slack sends .text as a string by contract, not by guarantee. A number, array,
  # or object aborted the whole render with a jq type error and an empty stdout.
  eq "as_text: null -> empty"   ""        "$(fx '(null   | as_text)')"
  eq "as_text: string passes"   "hi"      "$(fx '("hi"   | as_text)')"
  eq "as_text: number coerces"  "12345"   "$(fx '(12345  | as_text)')"
  eq "as_text: array coerces"   '["a"]'   "$(fx '(["a"]  | as_text)')"
  eq "as_text: object coerces"  '{"a":1}' "$(fx '({"a":1}| as_text)')"
  wantfx "message_text: a number body still renders" \
    '({text: 12345} | message_text({}; {}))' '12345'
  wantfx "message_text: an object body still renders" \
    '({text: {"a":1}} | message_text({}; {}))' '{"a":1}'


  echo "== render.jq: Slack List rows =="
  # Two columns. Every row field carries a column_id that is NOT its schema
  # entry's id, which is exactly how Slack sends one: join on column_id and
  # every cell comes back empty while the table still looks plausible.
  local LIST_DOC LIST_OUT
  LIST_DOC='{list_metadata:{schema:[
      {id:"c1",name:"Task",key:"k1",type:"text"},
      {id:"c2",name:"Owner",key:"k2",type:"user"},
      {id:"c3",name:"Status",key:"k3",type:"select",
       options:{choices:[{value:"Opt1",label:"Approved"}]}},
      {id:"c4",name:"Done",key:"k4",type:"checkbox"},
      {id:"c5",name:"Created",key:"k5",type:"created_time"}]},
    list_records:[
      {fields:[{key:"k1",column_id:"zzz",text:"Rotate the token"},
               {key:"k2",column_id:"zzz",user:["U1"]},
               {key:"k3",column_id:"zzz",select:["Opt1"]},
               {key:"k4",column_id:"zzz",checkbox:false},
               {key:"k5",column_id:"zzz",timestamp:[1757419200]}]},
      {fields:[{key:"k1",column_id:"zzz",text:"Ship | now\nnext line"},
               {key:"k2",column_id:"zzz",user:["U9GONE"]},
               {key:"k3",column_id:"zzz",select:["Opt9"]}]}]}'
  LIST_OUT=$(TZ=UTC fx "({\"U1\":{n:\"Alice\"}} as \$u | $LIST_DOC | render_list_rows(\$u; {}; 10))")
  has "render_list: the header names the columns"   '| Task | Owner | Status | Done | Created |' "$LIST_OUT"
  has "render_list: a cell joins on key, not column_id" 'Rotate the token' "$LIST_OUT"
  has "render_list: a user id resolves to a name"   '@Alice'   "$LIST_OUT"
  has "render_list: a select id resolves to its label" 'Approved' "$LIST_OUT"
  # `(.checkbox // null) != null` would drop this row's cell and shift the table.
  has "render_list: an unticked checkbox renders no" '| no |'  "$LIST_OUT"
  has "render_list: a timestamp is humanized (UTC)" '2025-09-09 12:00' "$LIST_OUT"
  # A pipe would end the cell early and a newline would end the row.
  has "render_list: a pipe in a cell is escaped"    'Ship \| now' "$LIST_OUT"
  hasnt "render_list: a newline in a cell is folded" 'Ship \| now
next' "$LIST_OUT"
  has "render_list: an unresolvable user falls back to the id" '@U9GONE' "$LIST_OUT"
  has "render_list: an unknown select id falls back to the id" 'Opt9' "$LIST_OUT"
  # Row 2 has no k4/k5 field. The schema fixes the column order, so the missing
  # cells must render empty rather than shifting Status left into Done.
  has "render_list: a sparse row keeps its columns aligned" '| Opt9 |  |  |' "$LIST_OUT"

  # Slack keeps adding column types, and a type this code has never seen still
  # arrives with a value. Render it rather than dropping the cell.
  LIST_OUT=$(fx '({list_metadata:{schema:[{name:"Rating",key:"k1",type:"rating"}]},
                   list_records:[{fields:[{key:"k1",column_id:"z",value:4}]}]}
                  | render_list_rows({}; {}; 10))')
  has "render_list: an unknown field shape falls back to its value" '| 4 |' "$LIST_OUT"

  LIST_OUT=$(fx "($LIST_DOC | render_list_rows({}; {}; 1))")
  has  "render_list: --limit caps the rows"     'Rotate the token' "$LIST_OUT"
  hasnt "render_list: --limit drops the rest"   'Ship'             "$LIST_OUT"

  LIST_OUT=$(fx '({list_metadata:{schema:[{name:"Name",key:"k1",type:"text"}]},list_records:[]}
                  | render_list_rows({}; {}; 10))')
  has  "render_list: no rows still names the columns" '| Name |' "$LIST_OUT"
  eq "render_list: no schema renders nothing" "" \
    "$(fx '({list_metadata:{schema:[]},list_records:[]} | render_list_rows({}; {}; 10))')"

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

  echo "== cache.sh: a name miss rebuilds the channel directory once =="
  # The bug this pins: with a long SLACKER_CACHE_TTL the directory never expires,
  # so a channel created since the snapshot resolves as channel_not_found
  # forever. Observed in production with a 7-week-old map holding 251 of 1479
  # channels; it cost a release note that had passed every publication gate.
  local cdir; cdir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_refresh.XXXXXX")
  printf '{"C0OLD":"old-channel"}' > "$cdir/channels.json"

  # $2 overrides the configured TTL. Without the override a huge TTL makes every
  # file fresh, which is exactly the state that hid the stale map.
  # The subshell scoping is the point: each case sets one TTL and nothing leaks.
  # shellcheck disable=SC2030,SC2031
  ( SLACKER_CACHE_TTL=999999999
    if slacker_cache_stale "$cdir/channels.json" 0; then exit 0; else exit 1; fi )
  eq "cache_stale: second arg overrides a huge configured TTL" 0 "$?"
  # shellcheck disable=SC2030,SC2031
  ( SLACKER_CACHE_TTL=0
    if slacker_cache_stale "$cdir/channels.json" 99999; then exit 0; else exit 1; fi )
  eq "cache_stale: second arg also overrides a tiny one" 1 "$?"

  # A just-written map must not be rebuilt again: the floor is what stops a typo
  # re-listing the whole workspace on every lookup.
  ( SLACKER_CACHE_DIR="$cdir"
    slacker_channels_cache(){ printf 'REBUILT' >> "$cdir/calls"; }
    slacker_channels_cache_refresh; exit $? )
  eq "refresh: declines while the map is under a minute old" 1 "$?"
  hasnt "refresh: and did not call the builder" "REBUILT" "$(cat "$cdir/calls" 2>/dev/null)"

  # Aged past the floor, a miss is allowed to rebuild.
  touch -t 197001010000 "$cdir/channels.json"
  ( SLACKER_CACHE_DIR="$cdir"
    slacker_channels_cache(){ printf 'REBUILT' >> "$cdir/calls"; }
    slacker_channels_cache_refresh; exit $? )
  eq "refresh: rebuilds once the map is old" 0 "$?"
  has "refresh: called the builder" "REBUILT" "$(cat "$cdir/calls" 2>/dev/null)"

  # The fix itself: resolve misses, the rebuild adds the channel, the retry wins.
  local rout
  # shellcheck disable=SC2030,SC2031
  rout=$( SLACKER_CACHE_DIR="$cdir"
          slacker_channels_cache_refresh(){
            printf '{"C0OLD":"old-channel","C0NEW":"product-release"}' > "$cdir/channels.json"
          }
          slacker_resolve_channel "#product-release" "$cdir/channels.json" )
  eq "resolve_channel: a miss rebuilds and then resolves" "C0NEW" "$rout"

  # And when the rebuild genuinely does not have it, it still fails - with advice
  # that no longer tells the operator to delete a file the code just refreshed.
  _slacker_rc_miss(){
    slacker_channels_cache_refresh(){ return 0; }
    slacker_resolve_channel "#ghost" "$cdir/channels.json"
  }
  oerr "resolve_channel: still errors when the rebuild cannot help" \
    channel_not_found _slacker_rc_miss
  rm -rf "$cdir" 2>/dev/null

  echo "== cache.sh: an unknown channel id is repaired one call at a time =="
  # The other half of the same problem. A NAME miss has to re-list the workspace,
  # but an ID miss does not: conversations.info takes an id, so a channel the
  # directory has never heard of costs one call instead of a full rebuild.
  # Without this the id rendered straight through as a bare C0NEW.
  local adir; adir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_augch.XXXXXX")
  printf '{"C0OLD":"old-channel"}' > "$adir/channels.json"
  local amap
  amap=$( SLACKER_CACHE_DIR="$adir"
          slacker_api(){ printf '%s\n' "$*" >> "$adir/calls"
                         printf '{"channel":{"id":"C0NEW","name":"product-release"}}'; }
          printf '{"text":"see <#C0NEW> today"}' | slacker_augment_channels "$adir/channels.json" )
  eq "augment_channels: an unknown mention resolves" "product-release" \
    "$(printf '%s' "$amap" | jq -r '.C0NEW')"
  eq "augment_channels: the base map survives the merge" "old-channel" \
    "$(printf '%s' "$amap" | jq -r '.C0OLD')"
  has "augment_channels: asked conversations.info" "conversations.info" "$(cat "$adir/calls" 2>/dev/null)"

  # Persisted, so the next payload mentioning it pays nothing. The stub fails
  # here on purpose: a second call would show up as an unresolved id.
  local acached
  acached=$( SLACKER_CACHE_DIR="$adir"
             slacker_api(){ printf 'AGAIN\n' >> "$adir/calls"; return 1; }
             printf '{"text":"see <#C0NEW> again"}' | slacker_augment_channels "$adir/channels.json" )
  eq "augment_channels: the resolution persists to channels_extra.json" "product-release" \
    "$(printf '%s' "$acached" | jq -r '.C0NEW')"
  hasnt "augment_channels: and is not looked up twice" "AGAIN" "$(cat "$adir/calls" 2>/dev/null)"

  # A DM comes back with the counterpart user id and no name — the same shape the
  # base builder stores, so slacker_dm_label still renders it as dm:Name.
  local adm
  adm=$( SLACKER_CACHE_DIR="$adir"
         slacker_api(){ printf '{"channel":{"id":"D0DM","user":"U0BOB"}}'; }
         printf '{"channel_id":"D0DM"}' | slacker_augment_channels "$adir/channels.json" )
  eq "augment_channels: a DM stores the counterpart user id" "U0BOB" \
    "$(printf '%s' "$adm" | jq -r '.D0DM')"

  # Best effort: a lookup that fails leaves the id unresolved. It must not error
  # out, and its <error> must not land in the map the caller is about to render.
  local afail
  afail=$( SLACKER_CACHE_DIR="$adir"
           slacker_api(){ slacker_error channel_not_found escalate "gone" "gone"; }
           printf '{"text":"gone <#C0GONE>"}' | slacker_augment_channels "$adir/channels.json" )
  hasnt "augment_channels: a failed lookup leaks no <error> into the map" "<error" "$afail"
  printf '%s' "$afail" | jq -e 'has("C0GONE") | not' >/dev/null 2>&1 \
    && ok "augment_channels: a failed lookup leaves the id unresolved" \
    || no "augment_channels: a failed lookup leaves the id unresolved" "map: $afail"
  rm -rf "$adir" 2>/dev/null

  echo "== cache.sh: a name miss rebuilds the user directory too =="
  # slacker_resolve_user had the channel bug's exact shape: one reverse lookup
  # against a map a long TTL never expires, so anyone who joined since the
  # snapshot was user_not_found forever.
  local udir; udir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_urefresh.XXXXXX")
  printf '{"U0OLD":{"n":"Alice","r":"Alice Lee","h":"alice","d":false}}' > "$udir/users.json"

  ( SLACKER_CACHE_DIR="$udir"
    slacker_users_cache(){ printf 'REBUILT' >> "$udir/calls"; }
    slacker_users_cache_refresh; exit $? )
  eq "users refresh: declines while the map is under a minute old" 1 "$?"
  hasnt "users refresh: and did not call the builder" "REBUILT" "$(cat "$udir/calls" 2>/dev/null)"

  touch -t 197001010000 "$udir/users.json"
  ( SLACKER_CACHE_DIR="$udir"
    slacker_users_cache(){ printf 'REBUILT' >> "$udir/calls"; }
    slacker_users_cache_refresh; exit $? )
  eq "users refresh: rebuilds once the map is old" 0 "$?"
  has "users refresh: called the builder" "REBUILT" "$(cat "$udir/calls" 2>/dev/null)"

  local uout
  # The cache-dir override is deliberately scoped to this subshell.
  # shellcheck disable=SC2030,SC2031
  uout=$( SLACKER_CACHE_DIR="$udir"
          slacker_users_cache_refresh(){
            printf '{"U0OLD":{"n":"Alice"},"U0NEW":{"n":"Carol","r":"Carol Chen","h":"carol","d":false}}' > "$udir/users.json"
          }
          slacker_resolve_user "@carol" "$udir/users.json" )
  eq "resolve_user: a miss rebuilds and then resolves" "U0NEW" "$uout"

  # An ambiguous match is a real answer, not a stale map, so it must not rebuild.
  printf '{"U0A":{"n":"Sam Lee"},"U0B":{"n":"Sam Ray"}}' > "$udir/users.json"
  _slacker_ru_ambig(){
    slacker_users_cache_refresh(){ printf 'REBUILT' >> "$udir/calls2"; return 0; }
    slacker_resolve_user "@sam" "$udir/users.json"
  }
  oerr "resolve_user: an ambiguous name still lists the candidates" \
    user_ambiguous _slacker_ru_ambig
  hasnt "resolve_user: and did not rebuild for it" "REBUILT" "$(cat "$udir/calls2" 2>/dev/null)"

  _slacker_ru_miss(){
    slacker_users_cache_refresh(){ return 0; }
    slacker_resolve_user "@ghost" "$udir/users.json"
  }
  oerr "resolve_user: still errors when the rebuild cannot help" \
    user_not_found _slacker_ru_miss
  rm -rf "$udir" 2>/dev/null

  echo "== parse.sh: the miss hint tells the three refresh outcomes apart =="
  # A refresh fails for two different reasons and both used to produce the same
  # <next>: "The directory was rebuilt". It was false whenever the one-minute
  # floor blocked the rebuild, which is the common case for a repeated lookup,
  # and false again when Slack refused the rebuild. A hint that is right in the
  # common case and confidently wrong otherwise is worse than no hint, because
  # the reader acts on it and goes hunting for an external user who is not
  # external. States 1 and 2 use the real refresh function, not a stub: the
  # exit code is the contract under test.
  local hdir; hdir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_hint.XXXXXX")
  printf '{"C0OLD":"old-channel"}' > "$hdir/channels.json"
  printf '{"U0OLD":{"n":"Alice","r":"Alice Lee","h":"alice","d":false}}' > "$hdir/users.json"

  # State 0: the rebuild ran and the name still is not there. Today's advice.
  local h0c h0u
  h0c=$( slacker_channels_cache_refresh(){ return 0; }
         slacker_resolve_channel "#ghost" "$hdir/channels.json" 2>/dev/null )
  has "hint: channel rebuilt and still absent" "was rebuilt and still lacks it" "$h0c"
  h0u=$( slacker_users_cache_refresh(){ return 0; }
         slacker_resolve_user "@ghost" "$hdir/users.json" 2>/dev/null )
  has "hint: user rebuilt and still absent" "was rebuilt and still lacks them" "$h0u"

  # State 1: the floor blocked it, so nothing was rebuilt. This is the one that
  # regressed silently — the map was untouched and the error said otherwise.
  # The maps were written a moment ago, so the real refresh declines.
  local h1c h1u
  # shellcheck disable=SC2030,SC2031
  h1c=$( SLACKER_CACHE_DIR="$hdir"
         slacker_resolve_channel "#ghost" "$hdir/channels.json" 2>/dev/null )
  has "hint: channel floor blocked the rebuild" "refreshed less than a minute ago" "$h1c"
  hasnt "hint: and does not claim a rebuild" "was rebuilt" "$h1c"
  # shellcheck disable=SC2030,SC2031
  h1u=$( SLACKER_CACHE_DIR="$hdir"
         slacker_resolve_user "@ghost" "$hdir/users.json" 2>/dev/null )
  has "hint: user floor blocked the rebuild" "refreshed less than a minute ago" "$h1u"
  hasnt "hint: and does not claim a rebuild either" "was rebuilt" "$h1u"

  # State 2: past the floor, the rebuild ran and Slack refused it.
  touch -t 197001010000 "$hdir/channels.json" "$hdir/users.json"
  ( SLACKER_CACHE_DIR="$hdir"
    slacker_channels_cache(){ return 1; }
    slacker_channels_cache_refresh; exit $? )
  eq "refresh: a failed rebuild is code 2, not 1" 2 "$?"
  ( SLACKER_CACHE_DIR="$hdir"
    slacker_users_cache(){ return 1; }
    slacker_users_cache_refresh; exit $? )
  eq "users refresh: a failed rebuild is code 2, not 1" 2 "$?"
  local h2c h2u
  # shellcheck disable=SC2030,SC2031
  h2c=$( SLACKER_CACHE_DIR="$hdir"
         slacker_channels_cache(){ return 1; }
         slacker_resolve_channel "#ghost" "$hdir/channels.json" 2>/dev/null )
  has "hint: channel rebuild failed" "rebuild failed" "$h2c"
  hasnt "hint: and does not claim a rebuild happened" "was rebuilt" "$h2c"
  # shellcheck disable=SC2030,SC2031
  h2u=$( SLACKER_CACHE_DIR="$hdir"
         slacker_users_cache(){ return 1; }
         slacker_resolve_user "@ghost" "$hdir/users.json" 2>/dev/null )
  has "hint: user rebuild failed" "rebuild failed" "$h2u"
  hasnt "hint: and does not claim a rebuild happened either" "was rebuilt" "$h2u"

  # Every state is still a well-formed <error> the caller can parse.
  xml_ok "$h1c" && ok "hint: the floor-blocked error is still valid xml" \
    || no "hint: the floor-blocked error is still valid xml" "$h1c"
  rm -rf "$hdir" 2>/dev/null

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
  # Distinct tokens must key distinct cache namespaces: switching workspaces
  # (SLACKER_SH_WORKSPACE -> SLACKER_SH_TOKEN_<name>) must never resolve ids
  # against the other workspace's users/channels.
  local k1 k2
  k1=$(SLACKER_SH_TOKEN=xoxp-work-token slacker__token_key)
  k2=$(SLACKER_SH_TOKEN=xoxp-personal-token slacker__token_key)
  if [ -n "$k1" ] && [ -n "$k2" ] && [ "$k1" != "$k2" ]; then
    ok "token key: distinct tokens -> distinct cache namespaces"
  else
    no "token key: distinct tokens -> distinct cache namespaces" "k1=$k1 k2=$k2"
  fi

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
