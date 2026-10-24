#!/usr/bin/env bash
# Offline export contract regressions through the real dispatcher and curl stub.
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2015

export_action_tests() {
  echo '== resumable one-request exports =='
  local out rc flag kind cutoff=1700000400.000000
  stub_reset
  out=$(STUB_VARIANT=export-start cli read-channel C100 --export --before "$cutoff" --limit 2 2>/dev/null)
  want 'export history: page receipt' "$out" 'history_page="true"'
  has 'export history: exclusive cutoff' "before=\"$cutoff\"" "$out"
  has 'export history: one API receipt' 'api_requests="1"' "$out"
  has 'export history: cursor available' 'next_cursor="PAGE2"' "$out"
  has 'export history: timestamp available' 'next_before="1700000250.000100"' "$out"
  has 'export history: thread identity' 'thread_ts="1700000300.000100"' "$out"
  has 'export history: no false retention assertion' 'history_limited="unknown"' "$out"
  eq 'export history: only one request' 1 "$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
  sent 'export: disables retries' '--retry 0'
  sent 'export: bounded connect' '--connect-timeout 10'
  sent 'export: bounded request' '--max-time 55'
  sent 'export: explicit exclusive bounds' 'inclusive=false'
  unsent 'export: no metadata lookup' 'conversations.info'
  unsent 'export: no user directory build' 'users.list'
  unsent 'export: no channel directory build' 'conversations.list'

  stub_reset
  out=$(STUB_VARIANT=export-history cli read-channel C100 --export --before "$cutoff" --after 1700000200.000001 --limit 2 2>/dev/null)
  want 'export history: retained flag' "$out" 'history_limited="true"'
  has 'export history: broadcast original root' 'thread_ts="1700000201.000001"' "$out"
  has 'export history: exact fraction retained' 'ts="1700000300.000101"' "$out"
  sent 'export history: exact lower bound' 'oldest=1700000200.000001'
  sent 'export history: exact upper bound' "latest=$cutoff"

  stub_reset
  out=$(STUB_VARIANT=export-terminal cli read-channel C100 --export --before "$cutoff" --cursor SAVED --limit 2 2>/dev/null)
  want 'export history: empty terminal' "$out" 'count="0" has_more="false"'
  hasnt 'export history: terminal no more marker' '<more' "$out"
  sent 'export history: saved cursor preserved' 'cursor=SAVED'

  stub_reset
  out=$(STUB_VARIANT=export-start cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --limit 2 2>/dev/null)
  want 'export replies: page receipt' "$out" 'reply_page="true"'
  has 'export replies: original author ID' 'id="U2"' "$out"
  has 'export replies: bound root identity' 'root_ts="1700000300.000100"' "$out"
  has 'export replies: no nested lossy reply' '<message thread_ts="1700000300.000100"' "$out"
  has 'export replies: forward cursor' 'next_cursor="RPAGE2"' "$out"
  has 'export replies: explicit ascending order' 'order="ascending"' "$out"
  eq 'export replies: only one request' 1 "$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
  unsent 'export replies: no parent history lookup' 'conversations.history'
  sent 'export replies: requested page limit' 'limit=2'
  sent 'export replies: fixed cutoff' "latest=$cutoff"
  stub_reset
  STUB_VARIANT=export-start xml 'export replies: limit plus parent accepted' 'count="2"' read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --limit 1

  stub_reset
  STUB_VARIANT=export-long xml 'export replies: full page plus parent accepted' 'count="201" has_more="true"' read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --limit 200

  stub_reset
  out=$(STUB_VARIANT=export-replies cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --cursor RPAGE2 --limit 1 2>/dev/null)
  want 'export replies: author and edit preserved' "$out" 'id="U2"'
  has 'export replies: edit flag' 'edited="true"' "$out"
  has 'export replies: terminal receipt' 'has_more="false"' "$out"
  sent 'export replies: exact resume cursor' 'cursor=RPAGE2'

  stub_reset
  out=$(cli list-conversations --export --limit 3 2>/dev/null)
  want 'export inventory: page receipt' "$out" 'inventory_page="true"'
  has 'export inventory: stable DM counterpart' 'user_id="U2"' "$out"
  has 'export inventory: resume cursor' 'next_cursor="LPAGE2"' "$out"
  has 'export inventory: explicit page count' 'pages="1"' "$out"
  eq 'export inventory: only one request' 1 "$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
  sent 'export inventory: all types' 'types=public_channel,private_channel,mpim,im'
  sent 'export inventory: archived included' 'exclude_archived=false'
  stub_reset
  out=$(STUB_VARIANT=export-inventory cli list-conversations --export --cursor LPAGE2 --limit 2 2>/dev/null)
  want 'export inventory: archived private' "$out" 'type="private_channel" archived="true"'
  has 'export inventory: group DM' 'type="mpim"' "$out"
  hasnt 'export inventory: terminal marker absent' '<more' "$out"
  sent 'export inventory: saved cursor' 'cursor=LPAGE2'

  # Missing and malformed caches must stay offline, with IDs as names.
  stub_reset
  printf 'not JSON\n' > "$STUB_CACHE/users.json"
  printf '[]\n' > "$STUB_CACHE/channels.json"
  xml 'export: invalid caches fall back safely' 'id="U2"' read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff"
  eq 'export: invalid cache still one call' 1 "$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
  stub_reset
  printf '{"U2":{"n":"Fixture & Name"}}' > "$STUB_CACHE/users.json"
  printf '{"C100":"cached-channel"}' > "$STUB_CACHE/channels.json"
  out=$(cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" 2>/dev/null)
  want 'export: valid cache name' "$out" 'name="cached-channel"'
  has 'export: valid cached author escaped' 'author="Fixture &amp; Name"' "$out"

  for flag in --before --after --cursor --limit --channel --ts; do
    stub_reset
    oerr "export: missing value $flag" missing_flag_value cli read-message --export "$flag"
    unsent "export: missing $flag has no request" 'CALL'
  done
  for flag in 0 201; do
    stub_reset
    oerr "export: invalid limit $flag" invalid_export_bounds cli read-channel C100 --export --before "$cutoff" --limit "$flag"
  done
  stub_reset
  oerr 'export: nonnumeric limit rejected' bad_count cli read-channel C100 --export --before "$cutoff" --limit abc
  oerr 'export: named channel rejected' invalid_export_bounds cli read-channel '#general' --export --before "$cutoff"
  oerr 'export: no implicit cutoff' invalid_export_bounds cli read-channel C100 --export
  oerr 'export: reversed history window' invalid_export_bounds cli read-channel C100 --export --before "$cutoff" --after 1700000500.000000
  oerr 'export: relative cutoff rejected' invalid_export_bounds cli read-channel C100 --export --before 7d
  oerr 'export: root must precede cutoff' invalid_export_bounds cli read-message --export --channel C100 --ts "$cutoff" --before "$cutoff"
  oerr 'export: replies reject lower bound' invalid_export_bounds cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --after 1
  oerr 'export: inventory rejects time bound' invalid_export_bounds cli list-conversations --export --before "$cutoff"
  oerr 'export: inventory rejects channel flag' invalid_export_arguments cli list-conversations --export --channel C100
  oerr 'export: history rejects root flag' invalid_export_arguments cli read-channel C100 --export --ts 1
  oerr 'export: bundled threads rejected' invalid_export_arguments cli read-channel C100 --export --before "$cutoff" --threads
  oerr 'export: extra positional rejected' invalid_export_arguments cli read-channel C100 C200 --export --before "$cutoff"
  oerr 'export: reply URL rejected' invalid_export_arguments cli read-message --export "$SLACKER_T_LINK"
  oerr 'export: unknown option rejected' invalid_export_arguments cli list-conversations --export --unknown
  oerr 'export: control character cursor rejected' invalid_export_bounds cli list-conversations --export --cursor $'bad\ncursor'
  unsent 'export: invalid requests never hit API' 'CALL'

  # Errors must be the only XML document, never success with a missing thread.
  for kind in export-rate export-scope; do
    stub_reset
    if [ "$kind" = export-rate ]; then flag=ratelimited; else flag=missing_scope; fi
    STUB_VARIANT="$kind" oerr "export replies: $flag stops" "$flag" cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff"
    eq "export replies: $flag has one attempt" 1 "$(wc -l < "$STUB_STATE/calls.log" | tr -d ' ')"
  done
  out=$(STUB_VARIANT=export-rate cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" 2>/dev/null)
  has 'export rate limit: no retry claim' 'no retries were made' "$out"
  has 'export rate limit: requires collector decision' 'action="escalate"' "$out"
  stub_reset
  STUB_FAIL=conversations.history oerr 'export history: transport failure stops' network_error cli read-channel C100 --export --before "$cutoff"
  stub_reset
  STUB_FAIL=conversations.list oerr 'export inventory: transport failure stops' network_error cli list-conversations --export

  # Every fixture below is a previously plausible silent truncation/corruption.
  for kind in export-duplicate export-outside export-wrong-thread export-unsorted export-no-cursor export-oversize export-bad-retention export-bad-metadata export-bad-type; do
    stub_reset
    STUB_VARIANT="$kind" oerr "export replies: reject $kind" invalid_export_page cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --limit 2
  done
  stub_reset
  STUB_VARIANT=export-multidoc oerr 'export: multiple documents fail at transport parser' unknown cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff"
  stub_reset
  STUB_VARIANT=export-repeated oerr 'export replies: repeated cursor stops' invalid_export_page cli read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff" --cursor AGAIN
  stub_reset
  STUB_VARIANT=export-unpageable oerr 'export history: empty incomplete stops' invalid_export_page cli read-channel C100 --export --before "$cutoff"
  stub_reset
  STUB_VARIANT=export-below oerr 'export history: exact lower bound exclusive' invalid_export_page cli read-channel C100 --export --before "$cutoff" --after 1700000300.000100
  stub_reset
  STUB_VARIANT=export-history-oversize oerr 'export history: page cap enforced' invalid_export_page cli read-channel C100 --export --before "$cutoff" --limit 1
  stub_reset
  STUB_VARIANT=export-empty-cursor xml 'export history: empty cursor page can advance' 'next_cursor="EMPTY2"' read-channel C100 --export --before "$cutoff"
  stub_reset
  STUB_VARIANT=export-bad-inventory oerr 'export inventory: duplicate IDs stop' invalid_export_page cli list-conversations --export
  stub_reset
  STUB_VARIANT=export-unpageable-inventory oerr 'export inventory: missing cursor stops' invalid_export_page cli list-conversations --export
  stub_reset
  STUB_VARIANT=export-zero-replies xml 'export replies: empty terminal allowed' 'count="0" has_more="false"' read-message --export --channel C100 --ts 1700000300.000100 --before "$cutoff"
  stub_reset
  STUB_VARIANT=export-render-error oerr 'export: rendering failure remains one error document' invalid_export_page cli read-channel C100 --export --before "$cutoff"
  stub_reset
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=helpers.sh
  . "$DIR/helpers.sh"
  SLACKER_T_LINK='https://x.slack.com/archives/C100/p1700000300000100'
  export_action_tests
  stub_cleanup
  summary
fi
