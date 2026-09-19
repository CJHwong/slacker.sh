#!/usr/bin/env bash
# actions.sh — offline end-to-end tests: the real slacker.sh binary driven
# through .dev/tests/stub/curl, which replays .dev/tests/fixtures. No token, no
# network, deterministic, safe in CI.
#
# These cover what unit.sh cannot: the dispatcher, argument parsing, cache
# building, pagination, the API-call shapes each action emits, and the error
# branches. unit.sh stays the home for pure-function and render.jq assertions.
#   ./.dev/tests/actions.sh    run these directly
#   ./.dev/tests/run.sh        run the whole suite
# The `assert && ok || no` reporter pattern is intentional (ok/no never fail).
# shellcheck disable=SC2015
# shellcheck source-path=SCRIPTDIR

# A permalink into the fixture channel, used by every message-targeting action.
SLACKER_T_LINK='https://x.slack.com/archives/C100/p1700000300000100'

action_tests(){
  echo "== dispatcher =="
  stub_reset
  local out
  out=$(cli help 2>&1); has "help: lists read commands"  'read-channel' "$out"
  out=$(cli help 2>&1); has "help: lists write commands" 'send'         "$out"
  out=$(cli --help 2>&1); has "help: --help alias"       'Usage:'       "$out"
  errs "dispatcher: no args -> usage on stderr" 'Usage:'          cli
  errs "dispatcher: unknown command"            "unknown command" cli definitely-not-a-command
  # Regression: the action name was pasted into a path, so a relative name with
  # ../ sourced and executed any .sh file on disk. A command word has no slash.
  errs "dispatcher: traversal in the name"  "invalid command name" cli ../../elsewhere/payload
  errs "dispatcher: absolute path name"     "invalid command name" cli /etc/passwd
  errs "dispatcher: a dotted name"          "invalid command name" cli read.channel
  errs "dispatcher: a name starting with -" "invalid command name" cli -x
  xml  "dispatcher: a real hyphenated command still dispatches" '<channel' \
       read-channel '#general'
  stub_reset

  echo "== cache.sh: an unwritable cache directory is a result, not a bash error =="
  # Regression: a read-only HOME or a full disk surfaced as a raw "Permission
  # denied" from the redirection, with an empty stdout and nothing to parse.
  stub_reset
  # The cache path's parent is a regular file, so mkdir -p can never create it.
  # chmod 500 was the obvious way to write this and it passes on macOS, but the
  # Linux container CI runs as root, and root writes through a 0500 directory.
  printf 'not a directory\n' > "$STUB_STATE/blocker"
  STUB_CACHE="$STUB_STATE/blocker/cache" \
    oerr "cache: unwritable dir -> cache_unwritable" cache_unwritable cli whois '@alice'
  stub_reset
  errs "dispatcher: <cmd> -h -> action usage"   'usage: slacker.sh send' cli send -h
  # -h must work before a token exists: the token is enforced at the first API
  # call, not in the dispatcher.
  STUB_TOKEN='' errs "dispatcher: -h works with no token" 'usage: slacker.sh read-channel' cli read-channel -h
  STUB_TOKEN='' oerr "no token -> no_token" no_token cli whois @alice

  echo "== actions/workspaces =="
  stub_reset
  out=$(STUB_TOKEN_work=xoxp-work-token STUB_TOKEN_personal=xoxp-personal-token cli workspaces 2>&1)
  has "workspaces: lists named workspaces" 'name="work"' "$out"
  has "workspaces: lists personal"          'name="personal"' "$out"
  has "workspaces: default token listed"    'name="default"' "$out"
  has "workspaces: default active with no selector" 'active="default"' "$out"

  stub_reset
  STUB_WORKSPACE=work STUB_TOKEN_work=xoxp-work-token \
    xml "workspaces: marks the active workspace" 'active="work"' workspaces

  stub_reset
  STUB_TOKEN='' xml "workspaces: token-free" 'active=""' workspaces

  stub_reset
  out=$(STUB_WORKSPACE=typo cli workspaces 2>&1)
  want "workspaces: broken selector flagged, not active" "$out" 'active=""'
  has "workspaces: broken selector names the misconfiguration" 'broken="typo"' "$out"

  stub_reset
  STUB_WORKSPACE=work STUB_TOKEN_work=xoxp-work-token \
    xml "workspaces: resolver picks the workspace token" '<user' whois @alice
  sent "workspaces: request carries the workspace token" 'Authorization: Bearer xoxp-work-token'
  unsent "workspaces: default token not used" 'Authorization: Bearer xoxp-test-token'

  stub_reset
  STUB_WORKSPACE=typo oerr "workspaces: missing workspace token -> XML boot error" \
    unknown_workspace cli whois @alice
  stub_reset
  out=$(STUB_WORKSPACE=typo cli whois @alice 2>&1)
  has "workspaces: boot error names the missing var" 'SLACKER_SH_TOKEN_typo' "$out"
  has "workspaces: boot error is actionable" 'Unset SLACKER_SH_WORKSPACE' "$out"

  stub_reset
  printf 'SLACKER_SH_TOKEN_work=xoxp-env-work-token\n' > "$STUB_ROOT/.env"
  STUB_WORKSPACE=work xml "workspaces: token from .env" '<user' whois @alice
  sent "workspaces: .env token reached the API" 'Authorization: Bearer xoxp-env-work-token'

  echo "== actions/send (regression: empty optional-arg array under set -u) =="
  # The 2026-08-03 delivery failure: a plain top-level send builds no optional
  # args, and expanding that empty array under `set -u` aborted before
  # chat.postMessage on bash < 4.4. Each shape below must reach the API.
  stub_reset
  xml  "send: top-level, no optional flags" '<sent'      send '#general' 'hello there'
  sent "send: top-level reached postMessage" 'chat.postMessage'
  sent "send: carries the resolved channel"  'channel=C100'
  unsent "send: top-level sends no thread_ts" 'thread_ts='

  stub_reset
  # --thread also takes a bare ts, not just a permalink.
  xml  "send: thread reply by bare ts" '<sent' send '#general' 'in thread' --thread 1700000300.000100
  sent "send: bare ts becomes thread_ts" 'thread_ts=1700000300.000100'

  stub_reset
  xml  "send: thread reply" '<sent' send '#general' 'in thread' --thread "$SLACKER_T_LINK"
  sent "send: thread reply carries thread_ts" 'thread_ts=1700000300.000100'

  stub_reset
  xml  "send: thread reply + broadcast" '<sent' send '#general' 'heads up' \
       --thread "$SLACKER_T_LINK" --broadcast
  sent "send: broadcast carries reply_broadcast" 'reply_broadcast=true'

  stub_reset
  xml  "send: top-level --no-unfurl" '<sent' send '#general' 'see https://x.com' --no-unfurl
  sent "send: --no-unfurl carries unfurl_links" 'unfurl_links=false'
  unsent "send: --no-unfurl alone sends no thread_ts" 'thread_ts='

  stub_reset
  # Not under STUB_STATE: stub_reset wipes that between cases.
  local capf; capf=$(mktemp "${TMPDIR:-/tmp}/slacker_note.XXXXXX"); printf 'note body\n' > "$capf"
  xml  "send: file with caption" '<sent' send '#general' 'the notes' --file "$capf"
  sent "send: caption posted first"    'chat.postMessage'
  sent "send: upload url requested"    'files.getUploadURLExternal'
  sent "send: upload completed"        'files.completeUploadExternal'
  sent "send: file threaded under caption" 'thread_ts=1700000100.000100'

  stub_reset
  xml  "send: bare file, no caption" '<sent' send '#general' --file "$capf"
  unsent "send: bare file posts no caption message" 'chat.postMessage'
  rm -f "$capf"

  stub_reset
  xml  "send: DM by @handle opens a conversation" '<sent' send '@alice' 'ping'
  sent "send: DM resolved via conversations.open" 'conversations.open'
  sent "send: DM posts to the opened channel"     'channel=D300'

  stub_reset
  xml  "send: --mrkdwn uses the raw text field" '<sent' send '#general' '*bold*' --mrkdwn
  sent "send: --mrkdwn sends text=, not markdown_text=" 'text=*bold*'
  stub_reset
  xml  "send: default uses markdown_text" '<sent' send '#general' '**bold**'
  sent "send: default sends markdown_text=" 'markdown_text=**bold**'

  stub_reset
  oerr "send: --thread with no value -> missing_flag_value" missing_flag_value \
       cli send '#general' hi --thread
  oerr "send: --file with no value -> missing_flag_value" missing_flag_value \
       cli send '#general' hi --file
  stub_reset
  xml  "send: -- lets text start with a dash" '<sent' send '#general' -- '- item one'
  sent "send: the dashed text reaches the API" 'markdown_text=- item one'
  errs "send: a bare dash still errors, and names --" 'use -- before text' \
       cli send '#general' '- item one'

  errs "send: no args -> usage"        'usage: slacker.sh send' cli send
  errs "send: unknown flag"            'unknown flag'           cli send '#general' hi --nope
  stub_reset
  oerr "send: file not found -> file_not_found" file_not_found \
       cli send '#general' 'cap' --file /nonexistent/path.txt
  stub_reset
  STUB_VARIANT=denied oerr "send: API rejection surfaces the code" not_in_channel \
       cli send '#general' 'hello'
  stub_reset
  local upf; upf=$(mktemp "${TMPDIR:-/tmp}/slacker_up.XXXXXX"); printf 'bytes\n' > "$upf"
  STUB_FAIL='upload/v1' oerr "send: byte upload failure -> upload_failed" upload_failed \
       cli send '#general' --file "$upf"
  stub_reset
  # With a signature configured, a file caption carries it appended as mrkdwn
  # (the upload API has no blocks parameter).
  STUB_SIG='via bot' xml "send: file caption carries the signature" '<sent' \
       send '#general' 'the notes' --file "$upf" --mrkdwn
  sent "send: caption signature appended" 'via bot'
  rm -f "$upf"
  stub_reset
  STUB_VARIANT=nochannels oerr "send: channels cache failure surfaces the scope" missing_scope \
       cli send '#general' 'hello'

  echo "== transport: a multi-document response body =="
  stub_reset
  # curl --retry writes every attempt's body, so a retried 429 arrived
  # concatenated in front of the successful one. `.ok` read as "false true", so a
  # call that SUCCEEDED was reported as a failure (a write would be posted and
  # denied, and a retry would double-post), and the code attribute came back as
  # "ratelimited\nunknown" — a newline inside an XML attribute. slacker_api_raw
  # passes -o so curl truncates per retry; the code is also read from the first
  # document only, so a multi-document body can never produce a two-word code.
  cli read-channel '#general' >/dev/null 2>&1
  sent "transport: API calls pass -o so retries cannot concatenate" '-o'
  stub_reset
  out=$(STUB_VARIANT=concat cli read-channel '#general' 2>/dev/null)
  want  "transport: a concatenated body still yields one <error>" "$out" '<error'
  has   "transport: the code is a single token" 'code="ratelimited"' "$out"
  hasnt "transport: no second code welded on" 'unknown"' "$out"
  stub_reset

  echo "== actions/read-channel =="
  stub_reset
  # Regression: a non-numeric count reached $(( )) and aborted with a raw bash
  # arithmetic error and an empty stdout.
  oerr "read-channel: --limit abc -> bad_count"     bad_count cli read-channel '#general' --limit abc
  oerr "read-channel: --limit -5 -> bad_count"      bad_count cli read-channel '#general' --limit -5
  oerr "read-channel: --reply-cap abc -> bad_count" bad_count cli read-channel '#general' --reply-cap abc
  oerr "read-channel: --since with no value"  missing_flag_value cli read-channel '#general' --since
  stub_reset
  xml "read-channel: resolves ids to names" 'author="Alice"'  read-channel '#general'
  stub_reset
  xml "read-channel: decodes mentions"      '@Bob Tan'        read-channel '#general'
  stub_reset
  xml "read-channel: decodes channel links" '#random'         read-channel '#general'
  stub_reset
  xml "read-channel: marks bot authors"     'bot="true"'      read-channel '#general'
  stub_reset
  xml "read-channel: shows thread size"     'replies="2"'     read-channel '#general'
  stub_reset
  xml "read-channel: follows next_cursor to page 2" 'starting the rollout' read-channel '#general'
  sent "read-channel: page 2 sends the cursor back" 'cursor=PAGE2'
  sent "read-channel: builds the users cache"       'users.list'
  sent "read-channel: builds the channels cache"    'conversations.list'
  # The users cache itself paginates; page 2 holds the deactivated user and the
  # bot, so resolving either proves the cache followed its cursor.
  sent "read-channel: users cache follows its cursor" 'cursor=UPAGE2'
  stub_reset
  xml  "read-channel: page-2 users still resolve" 'author="deploybot"' read-channel '#general'
  stub_reset
  xml "read-channel: --limit caps and marks more" '<more' read-channel '#general' --limit 1
  stub_reset
  xml "read-channel: --since sends oldest=" '<channel' read-channel '#general' --since 2024-01-30
  sent "read-channel: --since maps to oldest=" 'oldest='
  stub_reset
  xml "read-channel: --threads inlines replies" 'watching metrics' read-channel '#general' --threads
  sent "read-channel: --threads calls conversations.replies" 'conversations.replies'
  stub_reset
  xml "read-channel: --threads follows the reply cursor" 'external chiming in' \
      read-channel '#general' --threads
  sent "read-channel: reply page 2 sends the cursor" 'cursor=RPAGE2'
  stub_reset
  # A cap smaller than the thread must mark the truncation, never swallow it.
  xml "read-channel: --reply-cap marks truncation" '<more' \
      read-channel '#general' --threads --reply-cap 1
  stub_reset
  xml "read-channel: DM target by @handle" '<channel' read-channel '@alice'
  stub_reset
  xml "read-channel: raw channel id target"  '<channel' read-channel C100
  stub_reset
  xml "read-channel: --no-threads is explicit and default" '<channel' read-channel '#general' --no-threads
  unsent "read-channel: --no-threads makes no replies call" 'conversations.replies'
  stub_reset
  # conversations.info returns neither a name nor a counterpart id, so the label
  # falls back to the channels cache (slacker_dm_label).
  STUB_VARIANT=dmlabel xml "read-channel: DM label falls back to the cache" \
      'name="dm:Bob Tan"' read-channel D300
  stub_reset
  xml "read-channel: --since accepts an hours span" '<channel' read-channel '#general' --since 24h
  sent "read-channel: 24h span maps to oldest=" 'oldest='
  stub_reset
  STUB_VARIANT=empty xml "read-channel: empty channel still renders" '<channel' read-channel '#general'
  stub_reset
  oerr "read-channel: unknown channel -> channel_not_found" channel_not_found \
       cli read-channel '#no-such-channel'
  stub_reset
  oerr "read-channel: bad --since -> bad_date" bad_date cli read-channel '#general' --since 'not-a-date'
  errs "read-channel: unknown flag" 'unknown flag' cli read-channel '#general' --nope

  echo "== actions/read-message =="
  stub_reset
  xml "read-message: marks the linked message" 'target="true"' read-message "$SLACKER_T_LINK"
  stub_reset
  xml "read-message: includes thread context"  'watching metrics' read-message "$SLACKER_T_LINK"
  stub_reset
  xml "read-message: resolves an external author via users.info" '<message' \
      read-message "$SLACKER_T_LINK"
  sent "read-message: augments unknown ids via users.info" 'users.info'
  stub_reset
  xml "read-message: --no-thread skips replies" '<message' read-message "$SLACKER_T_LINK" --no-thread
  unsent "read-message: --no-thread makes no replies call" 'conversations.replies'
  stub_reset
  xml "read-message: --channel/--ts targeting" '<message' \
      read-message --channel '#general' --ts 1700000300.000100
  stub_reset
  # A permalink pointing at a REPLY (ts != thread_ts) merges the full
  # conversation (root + replies) as context, with the reply as the target.
  out=$(cli read-message 'https://x.slack.com/archives/C100/p1700000310000100?thread_ts=1700000300.000100' 2>&1)
  want "read-message: reply permalink nests the full conversation" "$out" 'deploy is green'
  has "read-message: reply is the target" 'target="true"' "$out"
  oerr "read-message: garbage permalink -> bad_permalink" bad_permalink \
       cli read-message 'https://x.slack.com/nope'
  errs "read-message: unknown flag"        'unknown flag'                cli read-message --nope
  errs "read-message: --channel without --ts -> usage" 'usage: slacker.sh read-message' \
       cli read-message --channel '#general'
  # A permalink carrying thread_ts points at a reply, so the root comes straight
  # from the link and the whole conversation nests under the linked reply.
  stub_reset
  xml "read-message: reply link nests the full conversation" 'deploy is green' \
      read-message "$SLACKER_T_LINK?thread_ts=1700000300.000100&cid=C100"
  stub_reset
  # Standalone render, so no target= marker: there is no surrounding thread to
  # distinguish the linked message from.
  xml "read-message: reply link + --no-thread returns just that reply" 'nice, watching metrics' \
      read-message "https://x.slack.com/archives/C100/p1700000310000100?thread_ts=1700000300.000100" --no-thread
  sent "read-message: reply lookup uses conversations.replies" 'conversations.replies'

  echo "== actions/search =="
  stub_reset
  # Regression: .messages/.matches are shaped by contract, not by guarantee.
  # Indexing a missing or non-object payload aborted the render with a raw jq
  # error and an empty stdout; every other action tolerates the same shapes.
  STUB_VARIANT=nomatches xml "search: a payload with no matches still renders" \
       'shown="0"' search 'q'
  stub_reset
  STUB_VARIANT=notobject xml "search: a non-object messages payload still renders" \
       'shown="0"' search 'q'
  stub_reset
  oerr "search: --limit abc -> bad_count" bad_count cli search 'q' --limit abc
  oerr "search: --page abc -> bad_count"  bad_count cli search 'q' --page abc
  oerr "search: --in with no value" missing_flag_value cli search 'q' --in
  stub_reset
  stub_reset
  xml "search: renders matches"          '<match'            search 'deploy postmortem'
  stub_reset
  xml "search: reports paging"           'pages="2"'         search 'deploy'
  stub_reset
  xml "search: page marker when more remain" 'rerun with --page 2' search 'deploy'
  stub_reset
  xml "search: --in/--from become modifiers" '<results' search 'deploy' --in '#general' --from '@alice'
  sent "search: --in maps to in:"   'in:#general'
  sent "search: --from maps to from:" 'from:@alice'
  stub_reset
  xml "search: --since maps to after:" '<results' search 'deploy' --since 2024-01-30
  sent "search: after: shifted back one day for inclusivity" 'after:2024-01-29'
  stub_reset
  STUB_VARIANT=empty xml "search: zero matches hints to broaden" 'broaden the query' search 'nothing'
  stub_reset
  xml  "search: --limit caps the request count" '<results' search 'deploy' --limit 5
  sent "search: --limit maps to count=" 'count=5'
  stub_reset
  xml  "search: --limit above 100 is clamped" '<results' search 'deploy' --limit 500
  sent "search: clamped to count=100" 'count=100'
  stub_reset
  xml  "search: --page requests that page" '<results' search 'deploy' --page 2
  sent "search: --page maps to page=" 'page=2'
  errs "search: no query -> usage" 'usage: slacker.sh search' cli search
  errs "search: unknown flag"      'unknown flag'             cli search 'x' --nope
  stub_reset
  STUB_TOKEN='xoxb-bot-token' oerr "search: bot token -> not_allowed_token_type" \
       not_allowed_token_type cli search 'deploy'

  echo "== actions/whois =="
  stub_reset
  xml "whois: by handle"        'name="Alice"'   whois '@alice'
  stub_reset
  xml "whois: presence"         'presence="active"' whois 'alice'
  stub_reset
  xml "whois: dnd flag"         'dnd="true"'     whois 'alice'
  stub_reset
  xml "whois: by user id"       '<user'          whois U1
  stub_reset
  xml "whois: by email uses lookupByEmail" '<user' whois 'bob@example.com'
  sent "whois: email hits users.lookupByEmail"  'users.lookupByEmail'
  stub_reset
  xml "whois: --channels lists memberships" '<channels' whois 'alice' --channels
  sent "whois: --channels calls users.conversations" 'users.conversations'
  stub_reset
  oerr "whois: unknown name -> user_not_found" user_not_found cli whois 'nobody-here'
  stub_reset
  oerr "whois: ambiguous substring -> user_ambiguous" user_ambiguous cli whois 'a'
  errs "whois: no args -> usage" 'usage: slacker.sh whois' cli whois
  errs "whois: unknown flag"     'unknown flag'            cli whois --nope

  echo "== actions/channel-info =="
  stub_reset
  xml "channel-info: topic"    '<topic>ship it'    channel-info '#general'
  stub_reset
  xml "channel-info: purpose"  '<purpose'          channel-info '#general'
  stub_reset
  xml "channel-info: members resolved to names" '<member>Alice' channel-info '#general'
  stub_reset
  xml "channel-info: pins rendered" '<pin author="Alice"' channel-info '#general'
  stub_reset
  xml  "channel-info: raw channel id target" '<channel' channel-info C100
  errs "channel-info: no args -> usage" 'usage: slacker.sh channel-info' cli channel-info
  errs "channel-info: unknown flag"     'unknown flag'                   cli channel-info --nope

  echo "== actions/read-file =="
  stub_reset
  xml "read-file: text content inlined" 'Rollout plan' read-file F0900PLAN
  stub_reset
  xml "read-file: header carries the mime type" 'mime="text/markdown"' read-file F0900PLAN
  stub_reset
  xml "read-file: binary saved to the cache"    '<saved path=' read-file F0700LOGO
  stub_reset
  xml "read-file: id extracted from a permalink" '<file' read-file 'https://x.slack.com/files/U1/F0900PLAN/plan.md'
  stub_reset
  xml "read-file: external file has no url_private" 'no url_private' read-file F0600EXTR
  stub_reset
  xml "read-file: html reduced to text"      'Runbook'    read-file F0500HTML
  stub_reset
  # &amp; in the source decodes to & then re-escapes exactly once for the XML.
  xml "read-file: html entities decoded, escaped once" 'Restart the &amp; worker' read-file F0500HTML
  stub_reset
  # No users cache (missing scope), so the uploader falls back to the raw id
  # instead of failing the whole read.
  STUB_VARIANT=nousers xml "read-file: unresolvable uploader falls back to the id" \
      'user="U1"' read-file F0900PLAN
  oerr "read-file: no id in input -> no_file_id" no_file_id cli read-file 'just-some-text'
  errs "read-file: no args -> usage"  'usage: slacker.sh read-file' cli read-file
  errs "read-file: unknown flag"      'unknown flag'                cli read-file --nope
  stub_reset
  STUB_FAIL='files-pri' oerr "read-file: text download failure -> download_failed" \
       download_failed cli read-file F0900PLAN
  stub_reset
  STUB_FAIL='files-pri' oerr "read-file: binary download failure -> download_failed" \
       download_failed cli read-file F0700LOGO

  echo "== actions/read-canvas =="
  stub_reset
  xml "read-canvas: by --channel finds the canvas" 'Team Canvas' read-canvas --channel '#general'
  stub_reset
  xml "read-canvas: html reduced to text"          'Owner: Alice' read-canvas --channel '#general'
  stub_reset
  xml "read-canvas: by canvas id"                  '<canvas'      read-canvas F0800CANV
  stub_reset
  STUB_VARIANT=nocanvas oerr "read-canvas: channel without a canvas -> no_canvas" \
       no_canvas cli read-canvas --channel '#random'
  oerr "read-canvas: no id in input -> no_canvas_id" no_canvas_id cli read-canvas 'nothing-here'
  errs "read-canvas: no args -> usage" 'usage: slacker.sh read-canvas' cli read-canvas
  errs "read-canvas: unknown flag"     'unknown flag'                   cli read-canvas --nope
  stub_reset
  STUB_FAIL='files-pri' oerr "read-canvas: download failure -> download_failed" \
       download_failed cli read-canvas F0800CANV

  echo "== actions/create-canvas =="
  local mdf; mdf=$(mktemp "${TMPDIR:-/tmp}/slacker_md.XXXXXX")
  stub_reset
  xml "create-canvas: creates, then resolves the permalink" \
      'permalink="https://x.slack.com/docs/T1/F0800CANV"' \
      create-canvas '#general' --title 'Team Canvas'
  sent   "create-canvas: sends channel_id" 'channel_id=C100'
  sent   "create-canvas: sends the title"  'title=Team Canvas'
  unsent "create-canvas: no body without --markdown-file" 'document_content'
  out=$(cli create-canvas '#general' --title 'Team Canvas' 2>/dev/null)
  has    "create-canvas: empty canvas is called out" '<note>' "$out"
  stub_reset
  xml "create-canvas: a DM id works, name falls back to the id" 'channel="D0B9TBCA5L5"' \
      create-canvas D0B9TBCA5L5 --title 'DM Canvas'

  printf '# Title\n\n|a|b|\n|--|--|\n|1|2|\n' > "$mdf"
  stub_reset
  xml    "create-canvas: --markdown-file writes the body" '<canvas' \
         create-canvas '#general' --title 'T' --markdown-file "$mdf"
  sent   "create-canvas: body goes as a file reference" 'document_content@'
  unsent "create-canvas: body stays off argv" 'document_content={'
  out=$(cli create-canvas '#general' --title 'T' --markdown-file "$mdf" 2>/dev/null)
  hasnt  "create-canvas: content drops the empty note" '<note>' "$out"

  # A table split by blank lines renders as prose, so refuse it before the write.
  printf '## H\n\n| a | b |\n\n|---|---|\n\n| 1 | 2 |\n' > "$mdf"
  stub_reset
  oerr   "create-canvas: blank line in a table -> table_not_contiguous" \
         table_not_contiguous cli create-canvas '#general' --title 'T' --markdown-file "$mdf"
  unsent "create-canvas: refuses before calling the API" 'conversations.canvases.create'

  stub_reset
  STUB_VARIANT=exists oerr "create-canvas: existing canvas -> channel_canvas_already_exists" \
       channel_canvas_already_exists cli create-canvas '#general' --title 'T'
  errs "create-canvas: no --title -> usage" 'usage: slacker.sh create-canvas' cli create-canvas '#general'
  errs "create-canvas: no args -> usage"    'usage: slacker.sh create-canvas' cli create-canvas
  errs "create-canvas: unknown flag"        'unknown flag' cli create-canvas '#general' --nope
  oerr "create-canvas: --title without a value -> missing_flag_value" \
       missing_flag_value cli create-canvas '#general' --title
  oerr "create-canvas: missing markdown file -> markdown_file_missing" \
       markdown_file_missing cli create-canvas '#general' --title 'T' --markdown-file /no/such/file.md

  echo "== actions/edit-canvas =="
  printf '# Title\n\n|a|b|\n|--|--|\n|1|2|\n' > "$mdf"
  stub_reset
  xml  "edit-canvas: replaces the whole canvas" 'operation="replace"' \
       edit-canvas F0800CANV --markdown-file "$mdf"
  sent   "edit-canvas: sends canvas_id"                'canvas_id=F0800CANV'
  sent   "edit-canvas: changes go as a file reference" 'changes@'
  unsent "edit-canvas: changes stay off argv"          'changes=['
  xml  "edit-canvas: --append inserts at the end" 'operation="insert_at_end"' \
       edit-canvas F0800CANV --markdown-file "$mdf" --append
  stub_reset
  xml  "edit-canvas: accepts a canvas permalink" 'operation="replace"' \
       edit-canvas 'https://x.slack.com/docs/T1/F0800CANV' --markdown-file "$mdf"
  sent "edit-canvas: permalink resolves to the canvas id" 'canvas_id=F0800CANV'

  printf '## H\n\n| a | b |\n\n|---|---|\n\n| 1 | 2 |\n' > "$mdf"
  stub_reset
  oerr   "edit-canvas: blank line in a table -> table_not_contiguous" \
         table_not_contiguous cli edit-canvas F0800CANV --markdown-file "$mdf"
  unsent "edit-canvas: refuses before calling the API" 'canvases.edit'
  # Restore a valid body so this case tests the id check alone.
  printf '# Title\n\n|a|b|\n|--|--|\n|1|2|\n' > "$mdf"
  oerr "edit-canvas: no canvas id in input -> no_canvas_id" no_canvas_id \
       cli edit-canvas 'nothing-here' --markdown-file "$mdf"
  errs "edit-canvas: no args -> usage" 'usage: slacker.sh edit-canvas' cli edit-canvas
  errs "edit-canvas: unknown flag"     'unknown flag' cli edit-canvas F0800CANV --nope
  oerr "edit-canvas: --markdown-file without a value -> missing_flag_value" \
       missing_flag_value cli edit-canvas F0800CANV --markdown-file
  rm -f "$mdf"

  echo "== actions/usergroup =="
  stub_reset
  xml "usergroup: lists all groups"      'handle="platform"' usergroup
  stub_reset
  xml "usergroup: expands by handle"     '<member>Alice'     usergroup '@platform'
  stub_reset
  xml "usergroup: expands by name"       '<usergroup'        usergroup 'On Call'
  stub_reset
  xml "usergroup: expands by S-id"       '<usergroup'        usergroup S01
  stub_reset
  oerr "usergroup: unknown handle -> usergroup_not_found" usergroup_not_found \
       cli usergroup '@nope'
  errs "usergroup: unknown flag" 'unknown flag' cli usergroup --nope

  echo "== actions/edit, delete, react, pin =="
  stub_reset
  xml  "edit: by permalink" '<edited' edit "$SLACKER_T_LINK" 'corrected text'
  sent "edit: calls chat.update" 'chat.update'
  stub_reset
  xml  "edit: by --channel/--ts" '<edited' edit --channel '#general' --ts 1700000300.000100 'fixed'
  stub_reset
  xml  "edit: --mrkdwn uses the raw text field" '<edited' edit "$SLACKER_T_LINK" '*bold*' --mrkdwn
  sent "edit: --mrkdwn sends text=, not markdown_text=" 'text=*bold*'
  stub_reset
  xml  "edit: default uses markdown_text" '<edited' edit "$SLACKER_T_LINK" '**bold**'
  sent "edit: default sends markdown_text=" 'markdown_text=**bold**'
  stub_reset
  # Regression: edit used to send a bare text field, and chat.update replaces the
  # message, so the signature footer the send wrote was dropped. Signed edits must
  # carry blocks (footer included) plus the text fallback.
  STUB_SIG='via bot' xml "edit: signed edit keeps the footer" '<edited' \
       edit "$SLACKER_T_LINK" 'corrected text'
  sent "edit: signed edit sends blocks=" 'blocks='
  sent "edit: signed edit keeps the context footer" 'via bot'
  # Leading space on purpose: 'text=' alone is a substring of 'markdown_text=',
  # so the unsigned path would satisfy it too and the assertion would prove nothing.
  sent "edit: signed edit keeps a text fallback" ' text=corrected text'
  stub_reset
  # Unsigned stays byte-identical to the legacy path: no blocks parameter at all.
  xml    "edit: unsigned edit stays plain" '<edited' edit "$SLACKER_T_LINK" 'plain text'
  unsent "edit: unsigned edit sends no blocks=" 'blocks='

  stub_reset
  # Regression: a trailing flag left "$2" unset, and under `set -u` the action
  # died with a raw bash diagnostic and an empty stdout — no <error> to parse.
  oerr "edit: --channel with no value -> missing_flag_value" missing_flag_value \
       cli edit --channel
  oerr "edit: --ts with no value -> missing_flag_value" missing_flag_value \
       cli edit --channel '#general' --ts
  stub_reset
  # Regression: text starting with a dash parsed as a flag, so a Markdown bullet
  # (which SKILL.md advertises) could not be sent at all. -- ends flag parsing.
  xml  "edit: -- lets text start with a dash" '<edited' \
       edit "$SLACKER_T_LINK" -- '- item one'
  sent "edit: the dashed text reaches the API" 'markdown_text=- item one'
  errs "edit: a bare dash still errors, and names --" 'use -- before text' \
       cli edit "$SLACKER_T_LINK" '- item one'

  stub_reset
  # chat.update has two ceilings in two units, and the <next> has to name the one
  # that applies. Quoting 4000 bytes on the markdown_text path made the caller cut
  # a 12000-character CJK body to 1330; claiming send "has no such cap" told it to
  # delete the original and repost, which destroys the message and then fails.
  STUB_VARIANT=toolong oerr "edit: msg_too_long -> recover" msg_too_long \
       cli edit "$SLACKER_T_LINK" 'some text'
  stub_reset
  out=$(STUB_VARIANT=toolong cli edit "$SLACKER_T_LINK" 'some text' 2>/dev/null)
  want   "edit: unsigned names the 12000-character cap" "$out" '12000-character cap'
  hasnt  "edit: unsigned does not quote the byte cap"   '4000 bytes' "$out"
  hasnt  "edit: unsigned does not claim send is uncapped" 'no such cap' "$out"
  stub_reset
  out=$(STUB_SIG='via bot' STUB_VARIANT=toolong cli edit "$SLACKER_T_LINK" 'some text' 2>/dev/null)
  want "edit: signed names the 4000-byte cap"        "$out" '4000 bytes'
  want "edit: signed names what added the text param" "$out" 'SLACKER_SH_SIGNATURE'
  want "edit: signed still warns about send's ceiling" "$out" '12000 characters'

  errs "edit: no text -> usage" 'usage: slacker.sh edit' cli edit "$SLACKER_T_LINK"
  errs "edit: unknown flag"     'unknown flag'           cli edit "$SLACKER_T_LINK" --nope

  stub_reset
  xml  "delete: by permalink" '<deleted' delete "$SLACKER_T_LINK"
  sent "delete: calls chat.delete" 'chat.delete'
  stub_reset
  xml  "delete: by --channel/--ts" '<deleted' delete --channel '#general' --ts 1700000300.000100
  stub_reset
  xml  "delete: bare permalink as a positional" '<deleted' delete "$SLACKER_T_LINK"
  stub_reset
  # A bare non-URL positional is taken as the target and must fail as a bad
  # permalink, not be silently ignored.
  oerr "delete: non-permalink positional -> bad_permalink" bad_permalink cli delete 'not-a-link'
  errs "delete: no target -> usage" 'usage: slacker.sh delete' cli delete
  errs "delete: unknown flag"       'unknown flag'            cli delete --nope
  stub_reset
  # react's own guard only requires an emoji, so this is the one action that can
  # reach slacker_resolve_message with a channel but no ts.
  oerr "react: --channel without --ts -> missing_target" missing_target \
       cli react --channel '#general' rocket

  stub_reset
  xml "react: add" 'status="added"' react "$SLACKER_T_LINK" rocket
  stub_reset
  xml "react: strips colons from the emoji" 'emoji="rocket"' react "$SLACKER_T_LINK" ':rocket:'
  stub_reset
  xml "react: by --channel/--ts" 'status="added"' \
      react --channel '#general' --ts 1700000300.000100 rocket
  stub_reset
  STUB_VARIANT=already xml "react: adding an existing reaction is a no-op" \
      'status="already-present"' react "$SLACKER_T_LINK" rocket
  stub_reset
  STUB_VARIANT=weird oerr "react: an unmapped reaction error is still an <error>" \
      some_unmapped_react_error cli react "$SLACKER_T_LINK" rocket
  errs "react: unknown flag" 'unknown flag' cli react "$SLACKER_T_LINK" --nope
  stub_reset
  # The fixture answers no_reaction, which is a no-op success, not an error.
  xml "react: --remove on an absent reaction is a no-op" 'status="not-present"' \
      react "$SLACKER_T_LINK" rocket --remove
  errs "react: no emoji -> usage" 'usage: slacker.sh react' cli react "$SLACKER_T_LINK"

  stub_reset
  # The fixture answers already_pinned, likewise a no-op success.
  xml "pin: already pinned is a no-op" 'status="already-present"' pin "$SLACKER_T_LINK"
  stub_reset
  xml "pin: --remove" 'status="removed"' pin "$SLACKER_T_LINK" --remove
  stub_reset
  xml "pin: by --channel/--ts" 'status="already-present"' pin --channel '#general' --ts 1700000300.000100
  stub_reset
  # The live API answers no_pin where the spec says not_pinned; both are no-ops.
  STUB_VARIANT=nopin xml "pin: --remove on an unpinned message is a no-op" \
      'status="not-present"' pin "$SLACKER_T_LINK" --remove
  stub_reset
  STUB_VARIANT=weird oerr "pin: an unmapped pin error is still an <error>" \
      some_unmapped_pin_error cli pin "$SLACKER_T_LINK"
  stub_reset
  oerr "pin: non-permalink positional -> bad_permalink" bad_permalink cli pin 'not-a-link'
  errs "pin: no target -> usage" 'usage: slacker.sh pin' cli pin
  errs "pin: unknown flag"       'unknown flag'          cli pin --nope

  echo "== actions/status =="
  stub_reset
  xml  "status: sets text" '<status ' status 'Codex 94%, Claude 7d 88%'
  sent "status: calls users.profile.set" 'users.profile.set'
  sent "status: sends the text in the profile blob" '"status_text":"Codex 94%, Claude 7d 88%"'
  sent "status: default emoji" '"status_emoji":":speech_balloon:"'
  sent "status: no expiry by default" '"status_expiration":0'
  stub_reset
  xml  "status: --emoji with colons" '<status ' status 'heads down' --emoji ':dart:'
  sent "status: --emoji sent in colon form" '"status_emoji":":dart:"'
  stub_reset
  # react strips colons off an emoji; status has to put them back, because
  # users.profile.set stores the colon form verbatim.
  xml  "status: --emoji without colons" '<status ' status 'heads down' --emoji dart
  sent "status: bare emoji name gets its colons" '"status_emoji":":dart:"'
  stub_reset
  xml  "status: multiple positionals join into one status" '<status ' status heads down now
  sent "status: joined text" '"status_text":"heads down now"'
  stub_reset
  STUB_VARIANT=cleared xml "status: --clear empties text and emoji" 'text="" emoji=""' status --clear
  sent "status: --clear sends an empty status_text" '"status_text":""'
  sent "status: --clear sends an empty status_emoji" '"status_emoji":""'
  stub_reset
  STUB_VARIANT=expiring xml "status: --expires renders a humanized time" 'expires="20' \
      status 'in a meeting' --emoji calendar --expires +2h
  stub_reset
  xml "status: no expiry renders as never" 'expires="never"' status 'around'
  stub_reset
  # The rendered <status> echoes what Slack stored, not the argument, so a
  # server-side rewrite or truncation shows up in the result.
  xml "status: renders the stored profile, not the input" \
      'emoji=":robot_face:"' status 'whatever was sent'
  stub_reset
  # 101 code points. The guard counts code points via jq, so it must not fire on
  # 100 CJK characters (300 bytes) — that is the bash ${#text} byte-count trap.
  oerr "status: over 100 characters -> status_too_long" status_too_long \
       cli status "$(printf 'x%.0s' $(seq 101))"
  stub_reset
  xml "status: exactly 100 characters is allowed" '<status ' status "$(printf 'x%.0s' $(seq 100))"
  stub_reset
  # A literal CJK run, not printf '\uXXXX': bash 3.2's printf has no \u escape and
  # would send the escape text itself, quietly turning this into an ASCII case.
  cjk100=''
  # ${cjk100} braced, not $cjk100: a CJK character immediately after the name is
  # swallowed into it under a UTF-8 locale, so the bare form is an unbound variable.
  for _i in $(seq 10); do cjk100="${cjk100}中文狀態測試字串長度"; done
  xml "status: 100 CJK characters is allowed" '<status ' status "$cjk100"
  stub_reset
  STUB_VARIANT=noscope oerr "status: token without users.profile:write -> missing_scope" \
       missing_scope cli status 'nope'
  stub_reset
  oerr "status: --expires with junk -> bad_time" bad_time cli status 'later' --expires 'half past'
  stub_reset
  # Slack allows an emoji-only status, so --emoji with no text is a real call,
  # not a usage error. Only a bare `status` is.
  xml  "status: emoji only" '<status ' status --emoji palm_tree
  sent "status: emoji-only sends an empty status_text" '"status_text":""'
  sent "status: emoji-only still sends the emoji" '"status_emoji":":palm_tree:"'
  errs "status: no text -> usage"  'usage: slacker.sh status' cli status
  errs "status: unknown flag"      'unknown flag'             cli status 'x' --nope

  echo "== actions/schedule =="
  stub_reset
  xml  "schedule: create with a relative +2h" '<scheduled ' schedule '#general' 'standup' --at +2h
  sent "schedule: calls chat.scheduleMessage" 'chat.scheduleMessage'
  stub_reset
  xml  "schedule: create with an absolute time" '<scheduled ' \
       schedule '#general' 'standup' --at '2030-01-30 09:00'
  stub_reset
  xml  "schedule: --at +30m"          '<scheduled ' schedule '#general' 'soon'  --at +30m
  stub_reset
  xml  "schedule: --at +1d"           '<scheduled ' schedule '#general' 'later' --at +1d
  stub_reset
  xml  "schedule: --at a raw epoch"   '<scheduled ' schedule '#general' 'then'  --at 1800000000
  stub_reset
  xml  "schedule: to a raw user id opens a DM" '<scheduled ' schedule U2 'ping' --at +2h
  sent "schedule: raw user id resolved via conversations.open" 'conversations.open'
  stub_reset
  xml  "schedule: --list" '<scheduled_messages' schedule --list
  stub_reset
  xml  "schedule: --list scoped to a channel" '<scheduled_messages' schedule --list '#general'
  sent "schedule: scoped list sends channel=" 'channel=C100'
  stub_reset
  xml  "schedule: --cancel" '<canceled' schedule --cancel Q123 --channel '#general'
  stub_reset
  xml  "schedule: --mrkdwn uses the raw text field" '<scheduled ' \
       schedule '#general' '*bold*' --at +2h --mrkdwn
  sent "schedule: --mrkdwn sends text=, not markdown_text=" 'text=*bold*'
  errs "schedule: create without --at -> usage" 'usage: slacker.sh schedule' \
       cli schedule '#general' 'text'
  errs "schedule: --cancel without --channel -> usage" 'usage: slacker.sh schedule --cancel' \
       cli schedule --cancel Q123
  errs "schedule: unknown flag" 'unknown flag' cli schedule '#general' 'x' --nope
  stub_reset
  oerr "schedule: bad --at -> bad_time" bad_time cli schedule '#general' 'text' --at 'half past nope'

  echo "== dispatcher: interpreter guard =="
  stub_reset
  # The guard must be the first statement: `set -o pipefail` (line 5) and
  # ${BASH_SOURCE[0]} (line 10) both blow up first under a non-bash shell, so a
  # guard placed after either is unreachable exactly when it is needed. Assert the
  # message, not just the exit code — that is the whole point of the check.
  local g probe
  for g in sh zsh dash ksh; do
    command -v "$g" >/dev/null 2>&1 || continue
    # Probe what the shell reports for $BASH_VERSION. A shell that cannot even run
    # `-c echo` is reported as skipped rather than silently mis-branched (macOS
    # /bin/ksh exits 139 here), because an unusable shell proves nothing either way.
    # Single quotes deliberately: the probed shell expands this, not this one.
    # shellcheck disable=SC2016
    if ! probe=$("$g" -c 'echo "${BASH_VERSION:-none}"' 2>/dev/null); then
      ok "guard: $g skipped (shell unusable on this host)"
      continue
    fi
    case "$probe" in
      ''|none)
        # A real non-bash shell: must be turned away by name, not by a later
        # syntax error, so assert the message and not merely a nonzero exit.
        errs "guard: $g is refused by name" 'needs bash' "$g" "$STUB_ROOT/slacker.sh" help ;;
      *)
        # macOS /bin/sh IS bash in POSIX mode, so it must still work.
        out=$("$g" "$STUB_ROOT/slacker.sh" help 2>/dev/null)
        has "guard: $g is bash underneath, so it runs" 'read-channel' "$out" ;;
    esac
  done
  # A real bash must never trip either arm of the guard.
  out=$(cli help 2>/dev/null)
  has "guard: the running bash is accepted" 'read-channel' "$out"

  echo "== dispatcher: install shapes =="
  # These two paths are the reason the harness runs from a throwaway root, so
  # they need testing head-on rather than by accident.
  stub_reset
  local linkdir; linkdir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_link.XXXXXX")
  ln -s "$STUB_ROOT/slacker.sh" "$linkdir/slacker.sh"
  # Invoked through a symlink, SLACKER_ROOT must resolve to the real directory
  # so lib/ and actions/ are still found (the /usr/local/bin install shape).
  out=$(cli_at "$linkdir/slacker.sh" help 2>/dev/null)
  has "dispatcher: resolves through a symlink" 'read-channel' "$out"
  # And a relative symlink target, which the loop has to rebase onto the link's
  # own directory rather than the caller's cwd.
  ln -s "./slacker.sh" "$linkdir/slacker-rel.sh"
  out=$(cli_at "$linkdir/slacker-rel.sh" help 2>/dev/null)
  has "dispatcher: resolves a relative symlink" 'read-channel' "$out"
  rm -rf "$linkdir"

  stub_reset
  # .env next to slacker.sh supplies the token when the environment does not.
  printf 'SLACKER_SH_TOKEN=xoxp-from-dotenv\n' > "$STUB_ROOT/.env"
  STUB_TOKEN='' xml "dispatcher: .env supplies the token" '<user' whois '@alice'
  sent "dispatcher: .env token reaches the API" 'Authorization: Bearer xoxp-from-dotenv'
  rm -f "$STUB_ROOT/.env"

  echo "== transport and error surfacing =="
  stub_reset
  STUB_FAIL='slack.com/api' oerr "transport failure -> network_error" network_error \
       cli read-channel '#general'
  stub_reset
  # An unmapped Slack error code must still come back as a parseable <error>,
  # not a crash or a bare stderr line.
  STUB_VARIANT=weird oerr "unmapped API error -> parseable <error>" \
       a_brand_new_slack_error cli read-channel '#general'

  stub_cleanup

  echo "== install.sh: targets and detection =="
  # Every run is sandboxed: HOME points at a temp root, CLAUDE_CONFIG_DIR is
  # unset so detection can never see (let alone update) a real install, and
  # stdin is /dev/null so the script always takes its non-interactive path.
  local ih rc; ih=$(mktemp -d "${TMPDIR:-/tmp}/slacker_inst.XXXXXX")
  local inst; inst="$ih/.agents/skills/slacker-sh"
  if HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target agents \
       </dev/null >/dev/null 2>&1 \
     && [ -x "$inst/slacker.sh" ] && [ -f "$inst/SKILL.md" ] && [ -d "$inst/lib" ]; then
    ok "install: --target agents installs the payload"
  else
    no "install: --target agents installs the payload" "missing payload at $inst"
  fi
  # .dev/ must not ship.
  if [ ! -e "$inst/.dev" ]; then ok "install: .dev stays behind"
  else no "install: .dev stays behind" "found $inst/.dev"; fi
  # Refresh semantics: a stale file inside the payload is wiped by the reinstall.
  : > "$inst/lib/STALE"
  if HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --update \
       </dev/null >/dev/null 2>&1 && [ ! -e "$inst/lib/STALE" ]; then
    ok "install: --update refreshes the detected install"
  else
    no "install: --update refreshes the detected install" "stale file survived or update failed"
  fi
  # An existing install without --update and without a terminal aborts.
  HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" \
       </dev/null >/dev/null 2>"$ih/err"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- "--update" "$ih/err"; then
    ok "install: existing install aborts non-interactively"
  else
    no "install: existing install aborts non-interactively" "rc=$rc, stderr: $(head -1 "$ih/err")"
  fi
  # Other targets land in their own harness dir.
  if HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target codex \
       </dev/null >/dev/null 2>&1 && [ -x "$ih/.codex/skills/slacker-sh/slacker.sh" ]; then
    ok "install: --target codex"
  else
    no "install: --target codex" "missing $ih/.codex/skills/slacker-sh/slacker.sh"
  fi
  # Positional dest still works, and wins over detection.
  if HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" "$ih/custom" \
       </dev/null >/dev/null 2>&1 && [ -x "$ih/custom/slacker.sh" ]; then
    ok "install: positional dest"
  else
    no "install: positional dest" "missing $ih/custom/slacker.sh"
  fi
  # dest together with --target is a caller mistake.
  HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target agents "$ih/x" \
       </dev/null >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then ok "install: dest plus --target rejected"
  else no "install: dest plus --target rejected" "exited 0"; fi
  # An unknown target name is an error, not a silent fallback.
  HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target nope \
       </dev/null >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then ok "install: unknown target rejected"
  else no "install: unknown target rejected" "exited 0"; fi
  # A trailing slash on a harness name still maps to the harness dir, never to a
  # stray cwd-relative copy. Run from $ih so a stray write cannot land elsewhere.
  if ( cd "$ih" && HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target agents/ \
       </dev/null >/dev/null 2>&1 ) && [ -x "$ih/.agents/skills/slacker-sh/slacker.sh" ] \
     && [ ! -e "$ih/agents" ]; then
    ok "install: --target agents/ maps to the agents dir"
  else
    no "install: --target agents/ maps to the agents dir" "stray cwd copy or missing payload"
  fi
  # A relative path is a path, as the usage line and the prompt promise. Run
  # from $ih so the relative dest resolves there.
  if ( cd "$ih" && HOME="$ih" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target ./reldest \
       </dev/null >/dev/null 2>&1 ) && [ -x "$ih/reldest/slacker.sh" ]; then
    ok "install: --target takes a relative path"
  else
    no "install: --target takes a relative path" "missing $ih/reldest/slacker.sh"
  fi
  # The root path is not a destination. A clean HOME, so the rejection is what
  # fails the run and not some earlier install's abort.
  local ih3; ih3=$(mktemp -d "${TMPDIR:-/tmp}/slacker_inst.XXXXXX")
  HOME="$ih3" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" --target / \
       </dev/null >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then ok "install: --target / rejected"
  else no "install: --target / rejected" "exited 0"; fi
  # --target claude follows CLAUDE_CONFIG_DIR, the same override detection ranks
  # first, so the target and the update flow manage the same directory.
  if HOME="$ih" env CLAUDE_CONFIG_DIR="$ih/cc" bash "$ROOT/install.sh" --target claude \
       </dev/null >/dev/null 2>&1 && [ -x "$ih/cc/skills/slacker-sh/slacker.sh" ]; then
    ok "install: --target claude follows CLAUDE_CONFIG_DIR"
  else
    no "install: --target claude follows CLAUDE_CONFIG_DIR" "missing $ih/cc/skills/slacker-sh/slacker.sh"
  fi
  # A clean HOME with no install anywhere takes the back-compat default.
  local ih2; ih2=$(mktemp -d "${TMPDIR:-/tmp}/slacker_inst.XXXXXX")
  if HOME="$ih2" env -u CLAUDE_CONFIG_DIR bash "$ROOT/install.sh" \
       </dev/null >/dev/null 2>&1 \
     && [ -x "$ih2/.claude/skills/slacker-sh/slacker.sh" ]; then
    ok "install: fresh run defaults to the claude dir"
  else
    no "install: fresh run defaults to the claude dir" "missing default install"
  fi
  rm -rf "$ih" "$ih2" "$ih3"
}

# Run when executed directly; stay quiet (just define action_tests) when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helpers.sh
  . "$DIR/helpers.sh"
  action_tests
  summary
fi
