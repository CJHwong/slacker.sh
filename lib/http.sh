# shellcheck shell=bash
# lib/http.sh — transport. curl + auth, error surfacing, pagination.
# Sourced by slacker.sh. Depends on: curl, jq, $SLACKER_SH_TOKEN.

# Exported so parallel workers (xargs bash -c, see read-channel) inherit it.
export SLACKER_API_BASE="https://slack.com/api"

# Portable file stat. GNU form (-c) first: BSD stat rejects it cleanly with no
# stdout, but GNU stat's -f is "filesystem mode" and leaks a block to stdout
# before failing — so BSD-first would pollute the result on Linux.
slacker_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
slacker_fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }

# Emit a structured <error> as XML and return 1. Output goes to fd 3 (a dup of
# the process's real stdout, opened once by the dispatcher) so it escapes any
# command-substitution capture and lands as the command's single result — at any
# nesting depth, callers keep `|| return 1` unchanged. When fd 3 is closed (e.g.
# unit tests sourcing lib/ directly) it falls back to stdout. `action` is the
# agent's next move: "recover" (run the suggested command) or "escalate" (stop
# and ask the human). The command name comes from $SLACKER_SH_CMD (set by the
# dispatcher). $1 code, $2 action, $3 message, $4 next-step.
slacker_error() {
  local code="$1" action="$2" message="$3" next="$4" xml
  xml=$(jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
      "<error command=\"" + attr($cmd) + "\" code=\"" + attr($code)
      + "\" action=\"" + attr($action) + "\">\n"
      + "  <message>" + ($message | xml_escape) + "</message>\n"
      + "  <next>" + ($next | xml_escape) + "</next>\n"
      + "</error>"' \
    --arg cmd "${SLACKER_SH_CMD:-slacker.sh}" --arg code "$code" \
    --arg action "$action" --arg message "$message" --arg next "$next")
  if { printf '%s\n' "$xml" >&3; } 2>/dev/null; then :; else printf '%s\n' "$xml"; fi
  return 1
}

# Fail with a structured error if no token, and warn if it looks like the wrong
# type. The warnings stay on stderr — they're advisory, not a failed result.
slacker_require_token() {
  if [ -z "${SLACKER_SH_TOKEN:-}" ]; then
    slacker_error no_token escalate \
      "SLACKER_SH_TOKEN is not set." \
      "A human must configure a Slack user token (xoxp-...): put it in .env next to slacker.sh or export SLACKER_SH_TOKEN (see reference/setup.md). Do not retry until it is set."
    return 1
  fi
  case "$SLACKER_SH_TOKEN" in
    xoxp-*) : ;; # user token, full surface incl. search — preferred
    xoxb-*) echo "slacker.sh: warn — bot token detected; search will fail and you must /invite the bot to each channel" >&2 ;;
    *)      echo "slacker.sh: warn — token doesn't look like xoxp-/xoxb-" >&2 ;;
  esac
}

# Translate a Slack error code into a structured <error> whose `action` and
# `next` tell the agent its next move. $1 method, $2 error code, $3 full JSON
# body. (already_reacted/no_reaction/already_pinned/not_pinned never reach here
# — react/pin treat them as a no-op success before this is called.)
slacker_explain_error() {
  local method="$1" err="$2" body="$3" action message next extra
  case "$err" in
    missing_scope)
      extra=$(printf '%s' "$body" | jq -r '.needed // empty')
      action=escalate
      message="$method needs OAuth scope(s) the token lacks${extra:+: $extra}."
      next="A human must add the scope(s) to the Slack app, reinstall it, and update SLACKER_SH_TOKEN. Do not retry until then." ;;
    not_allowed_token_type)
      action=escalate
      message="$method rejected the token type (e.g. search needs a user token, xoxp-)."
      next="A human must reconfigure SLACKER_SH_TOKEN with the right token type. Do not retry." ;;
    invalid_auth|not_authed|token_revoked|token_expired|account_inactive)
      action=escalate
      message="$method failed: the token is invalid, expired, or revoked ($err)."
      next="A human must update SLACKER_SH_TOKEN in .env. Do not retry." ;;
    channel_not_found)
      action=escalate
      message="$method: channel not found, so the name is not in the workspace directory. A Slack Connect channel hosted in another workspace may be absent from it."
      next="Ask the user for the channel id (Cxxxx) or a permalink, then retry." ;;
    not_in_channel|is_archived|channel_not_open)
      action=escalate
      message="$method: can't access this channel ($err) — a user token must be a member, and archived/closed channels can't be read this way (or joined)."
      next="Tell the user; they need to add you to the channel (or unarchive it). Don't retry as-is." ;;
    channel_canvas_already_exists)
      # Slack answers this when a channel already has a canvas. Do not turn it
      # into a one-canvas rule: a DM does NOT behave this way (a second create
      # there simply makes another canvas, verified live), so the claim would be
      # false for half the targets. What is true is that a retry cannot succeed.
      action=recover
      message="$method: Slack reports that this channel already has a canvas."
      next="Read its id with: slacker.sh channel-info <#chan>. Then write to it with: edit-canvas <id> --markdown-file <path>, or target a different channel." ;;
    canvas_not_found)
      # Almost always a mistyped or stale canvas id, so retrying the same call is
      # pointless. canvas.delete has no undo, which makes guessing here worse than
      # stopping: deleting the wrong canvas cannot be reversed.
      action=recover
      message="$method: no canvas with that id, or it was already deleted."
      next="Check the id with: slacker.sh read-canvas <id>. Do not retry the same id, and do not guess a different one, because a canvas cannot be restored after deletion." ;;
    user_not_found)
      action=escalate
      message="$method: user not found in the workspace directory (may be external/Slack Connect)."
      next="Ask the user for the user id (Uxxxx), or an email (whois resolves an email exactly)." ;;
    users_not_found)
      action=escalate
      message="$method: one or more user ids weren't found."
      next="Ask the user to confirm the ids." ;;
    no_permission|restricted_action|cant_update_message|cant_delete_message|message_not_found)
      action=escalate
      message="$method: not permitted or target missing ($err). You can only edit/delete your own messages."
      next="For a thread reply, pass the full permalink; otherwise surface this to the user." ;;
    thread_not_found)
      action=recover
      message="$method: thread not found."
      next="Pass the full permalink (it carries thread_ts), then retry." ;;
    file_not_found|file_deleted)
      action=escalate
      message="$method: the file is missing or deleted ($err)."
      next="Tell the user the file is gone." ;;
    msg_too_long)
      # Two different ceilings in two different units, both measured against the
      # live API. chat.update takes 12000 CHARACTERS via markdown_text, but only
      # 4000 BYTES once the request carries a `text` parameter, which a configured
      # signature (blocks need a text fallback) or --mrkdwn adds. Quoting one
      # number for both made the caller cut a 12000-character CJK body to 1330.
      # chat.postMessage caps at 12000 characters, so "delete and repost with
      # send" is not an escape hatch above that: it destroys the original and
      # then fails. Never suggest it without naming send's own ceiling.
      action=recover
      case "$method" in
        chat.update)
          if [ -n "${SLACKER_SH_SENT_TEXT_PARAM:-}" ]; then
            message="$method: the body exceeds 4000 bytes. This request carries a text parameter, which caps at 4000 bytes; a configured SLACKER_SH_SIGNATURE or --mrkdwn adds one. Bytes, not characters, so CJK costs 3 each (about 1330 characters)."
            next="Cut the body under 4000 bytes and retry. Unsetting the signature or dropping --mrkdwn raises the ceiling to 12000 characters. send caps at 12000 characters too, so only delete and repost if the body fits that."
          else
            message="$method: the body exceeds chat.update's 12000-character cap on markdown_text. Characters, not bytes, so 12000 CJK characters are fine."
            next="Cut the body under 12000 characters and retry. send has the same 12000-character ceiling, so deleting and reposting will not rescue a longer body; send it as a file with --file instead."
          fi ;;
        *)
          message="$method: the message text exceeds Slack's 12000-character cap."
          next="Split the text into chunks under 12000 characters (post the remainder as thread replies), or resend it as a file with --file." ;;
      esac ;;
    # The Slack List write codes, each seen live from slackLists.items.update.
    # invalid_arguments names the offending field only in response_metadata,
    # so that text goes into the message; without it the code says nothing.
    invalid_arguments)
      extra=$(printf '%s' "$body" | jq -r '(.response_metadata.messages // []) | join("; ")' 2>/dev/null)
      action=recover
      message="$method rejected the request shape${extra:+: $extra}."
      next="Fix the argument Slack names, then retry." ;;
    invalid_option_id|invalid_date|invalid_input_type)
      action=recover
      message="$method: a value does not fit its column ($err)."
      next="Read the list with read-list to see the column types and options, then retry with a value that fits." ;;
    invalid_row_id|row_not_found|invalid_column_id|column_not_found)
      action=recover
      message="$method: the row or column is gone ($err). The list changed since it was read."
      next="Run the same command again. It reads the list fresh, and --where finds the row by its content." ;;
    uneditable_column|access_denied|list_not_found)
      action=escalate
      message="$method: this list or column cannot be edited with this token ($err)."
      next="Tell the user. They must open the list in Slack, or ask its owner for edit access." ;;
    rate_limited|ratelimited)
      action=recover
      message="$method: still rate-limited after automatic retries."
      next="Wait a bit, then run the same command again." ;;
    *)
      action=escalate
      message="$method: unhandled Slack API error '$err'."
      next="See https://api.slack.com/methods/$method for '$err'; surface it to the user." ;;
  esac
  slacker_error "$err" "$action" "$message" "$next"
}

# slacker_api_raw <method> [curl --data-urlencode args...]
# POSTs and returns the raw JSON body on stdout, WITHOUT checking .ok — the
# caller inspects .error itself (used by react/pin to treat already_reacted /
# no_reaction / already_pinned / not_pinned as a no-op success). A transport
# failure still emits a structured <error> and returns non-zero.
slacker_api_raw() {
  # Enforce the token here (once), not in the dispatcher, so usage/help works
  # before a token is configured — the cost is only paid on a real API call.
  [ -n "${_SLACKER_TOKEN_OK:-}" ] || { slacker_require_token || return 1; _SLACKER_TOKEN_OK=1; }
  local method="$1"; shift
  # --retry writes EVERY attempt's body, so a retried 429 leaves the rate-limit
  # body concatenated in front of the successful one. jq then reads two
  # documents from it: `.ok` becomes "false true", which does not equal "true",
  # so a call that SUCCEEDED is reported as a failure — for a write that means
  # the message was posted and the agent is told it was not, and a retry
  # double-posts. The <error> code came out as two words ("ratelimited
  # unknown") too, which no caller can switch on. -o truncates the file on each
  # retry, so only the final attempt survives.
  local respf rc
  respf=$(mktemp "${TMPDIR:-/tmp}/slacker_resp.XXXXXX")
  curl -sS --retry 3 --retry-connrefused \
    -X POST "$SLACKER_API_BASE/$method" \
    -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
    -o "$respf" "$@"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$respf"
    slacker_error network_error escalate \
      "network/curl failure calling $method." \
      "Check connectivity, then retry the command."
    return 1
  fi
  cat "$respf"
  rm -f "$respf"
}

# slacker_api <method> [curl --data-urlencode args...]
# Returns the JSON body on stdout. On an API error, emits a structured <error>
# (see slacker_explain_error) and returns non-zero.
# curl --retry honors Retry-After on 429/503, so rate limits self-heal.
slacker_api() {
  local method="$1" body
  body=$(slacker_api_raw "$@") || return 1
  if [ "$(printf '%s' "$body" | jq -r '.ok')" != "true" ]; then
    # Which parameter carries the body decides chat.update's ceiling, and only
    # the request knows. Matched as a prefix so markdown_text= does not count.
    local _arg
    SLACKER_SH_SENT_TEXT_PARAM=""
    for _arg in "$@"; do
      case "$_arg" in text=*) SLACKER_SH_SENT_TEXT_PARAM=1; break ;; esac
    done
    # Read the code from the FIRST document only. -o stops curl concatenating
    # retry bodies, but a proxy or a future change could still hand us more than
    # one, and a bare `jq -r .error` over two documents produced a code attribute
    # with a newline inside it ("ratelimited\nunknown") that no caller can match.
    local errcode
    errcode=$(printf '%s' "$body" | jq -s -r '(.[0].error? // "unknown")' 2>/dev/null)
    [ -n "$errcode" ] || errcode=unknown
    slacker_explain_error "$method" "$errcode" "$body"
    return 1
  fi
  printf '%s' "$body"
}

# slacker_fetch_paginated <method> <array_field> [extra --data-urlencode args...]
# Follows response_metadata.next_cursor to completion, returns the concatenated array.
# Pages stream to a temp file as JSONL and are slurped at the end, so large
# result sets (thousands of users) never hit ARG_MAX the way --argjson would.
slacker_fetch_paginated() {
  local method="$1" field="$2"; shift 2
  local cursor="" body tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/slacker_page.XXXXXX")
  while :; do
    if [ -n "$cursor" ]; then
      body=$(slacker_api "$method" --data-urlencode "limit=1000" --data-urlencode "cursor=$cursor" "$@") || { rm -f "$tmp"; return 1; }
    else
      body=$(slacker_api "$method" --data-urlencode "limit=1000" "$@") || { rm -f "$tmp"; return 1; }
    fi
    printf '%s' "$body" | jq -c ".$field // [] | .[]" >> "$tmp" || { rm -f "$tmp"; return 1; }
    cursor=$(printf '%s' "$body" | jq -r '.response_metadata.next_cursor // ""')
    [ -n "$cursor" ] || break
  done
  jq -cs '.' "$tmp"
  rm -f "$tmp"
}

# slacker_fetch_replies <channel> <ts> [cap]
# Pulls a thread (parent + replies) following the cursor up to `cap` messages.
# Returns {messages:[...], truncated:bool}; truncated=true means more remain.
slacker_fetch_replies() {
  local channel="$1" ts="$2" cap="${3:-200}"
  local cursor="" body got=0 truncated=false tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/slacker_rep.XXXXXX")
  while :; do
    if [ -n "$cursor" ]; then
      body=$(slacker_api conversations.replies --data-urlencode "channel=$channel" --data-urlencode "ts=$ts" --data-urlencode "limit=200" --data-urlencode "cursor=$cursor") || { rm -f "$tmp"; return 1; }
    else
      body=$(slacker_api conversations.replies --data-urlencode "channel=$channel" --data-urlencode "ts=$ts" --data-urlencode "limit=200") || { rm -f "$tmp"; return 1; }
    fi
    printf '%s' "$body" | jq -c '.messages[]?' >> "$tmp"
    got=$(grep -c . "$tmp" 2>/dev/null || printf 0)
    cursor=$(printf '%s' "$body" | jq -r '.response_metadata.next_cursor // ""')
    if [ "$(printf '%s' "$body" | jq -r '.has_more')" = "true" ] && [ -n "$cursor" ]; then
      [ "$got" -ge "$cap" ] && { truncated=true; break; }
    else
      break
    fi
  done
  jq -cn --slurpfile m "$tmp" --argjson t "$truncated" '{messages:$m, truncated:$t}'
  rm -f "$tmp"
}

# slacker_fetch_list <list-id> <outfile>
# Downloads a Slack List as the JSON document its file serves (the schema plus
# every row) into <outfile>. That route needs files:read only, where
# slackLists.items.list would need lists:read. Sets SLACKER_SH_LIST_TITLE and
# SLACKER_SH_LIST_PERMALINK for the caller, so it must not run in a subshell.
# shellcheck disable=SC2034  # SLACKER_SH_LIST_TITLE is read by the calling action.
slacker_fetch_list() {
  local listid="$1" outf="$2" info ftype url
  SLACKER_SH_LIST_TITLE=""
  SLACKER_SH_LIST_PERMALINK=""
  info=$(slacker_api files.info --data-urlencode "file=$listid") || return 1
  ftype=$(printf '%s' "$info" | jq -r '.file.filetype // ""')
  url=$(printf   '%s' "$info" | jq -r '.file.url_private // ""')
  SLACKER_SH_LIST_TITLE=$(printf '%s' "$info" | jq -r '.file.title // .file.name // .file.id')
  SLACKER_SH_LIST_PERMALINK=$(printf '%s' "$info" | jq -r '.file.permalink // ""')

  # A wrong type here is the user pointing at the wrong thing, and the sibling
  # action that does handle it is worth naming rather than making them guess.
  if [ "$ftype" != "list" ]; then
    slacker_error not_a_list escalate \
      "file $listid is a '$ftype', not a Slack List." \
      "Read it with read-file, or read-canvas for a canvas."
    return 1
  fi
  [ -n "$url" ] || { slacker_error no_list_url escalate "list $listid has no download url." \
    "Open the permalink instead: $SLACKER_SH_LIST_PERMALINK"; return 1; }

  curl -fsSL -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" "$url" -o "$outf" \
    || { slacker_error download_failed escalate "couldn't download list $listid." \
         "Open the permalink instead: $SLACKER_SH_LIST_PERMALINK"; return 1; }

  # Everything downstream runs jq over this file. A non-JSON body (an error page,
  # a truncated transfer) would kill the first of them mid-pipeline and leave the
  # caller with an empty stdout and no <error> to parse, so check it once here.
  jq -e 'type == "object"' < "$outf" >/dev/null 2>&1 \
    || { slacker_error bad_list_payload escalate \
         "list $listid downloaded, but its body is not the JSON document a list serves." \
         "Open the permalink instead: $SLACKER_SH_LIST_PERMALINK"; return 1; }
}
