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
  errs "dispatcher: <cmd> -h -> action usage"   'usage: slacker.sh send' cli send -h
  # -h must work before a token exists: the token is enforced at the first API
  # call, not in the dispatcher.
  STUB_TOKEN='' errs "dispatcher: -h works with no token" 'usage: slacker.sh read-channel' cli read-channel -h
  STUB_TOKEN='' oerr "no token -> no_token" no_token cli whois @alice

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

  echo "== actions/read-channel =="
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
}

# Run when executed directly; stay quiet (just define action_tests) when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helpers.sh
  . "$DIR/helpers.sh"
  action_tests
  summary
fi
