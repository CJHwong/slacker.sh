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

# Fail loudly if no token, and warn if it looks like the wrong type.
slacker_require_token() {
  if [ -z "${SLACKER_SH_TOKEN:-}" ]; then
    echo "slacker.sh: SLACKER_SH_TOKEN not set (put it in .env or export it)" >&2
    return 1
  fi
  case "$SLACKER_SH_TOKEN" in
    xoxp-*) : ;; # user token, full surface incl. search — preferred
    xoxb-*) echo "slacker.sh: warn — bot token detected; search will fail and you must /invite the bot to each channel" >&2 ;;
    *)      echo "slacker.sh: warn — token doesn't look like xoxp-/xoxb-" >&2 ;;
  esac
}

# Translate a Slack error code into an actionable line so the agent (or user)
# knows how to mitigate. $1 method, $2 error code, $3 full JSON body.
slacker_explain_error() {
  local method="$1" err="$2" body="$3" hint="" extra=""
  case "$err" in
    missing_scope)
      extra=$(printf '%s' "$body" | jq -r '.needed // empty')
      hint="SLACKER_SH_TOKEN is missing scope(s)${extra:+: $extra}. Add them to the Slack app, reinstall, and update the token." ;;
    not_allowed_token_type)
      hint="wrong token type for this method. e.g. search needs a USER token (xoxp-); some admin methods need others." ;;
    invalid_auth|not_authed|token_revoked|token_expired|account_inactive)
      hint="token is invalid/expired/revoked. Check SLACKER_SH_TOKEN in .env." ;;
    channel_not_found)
      hint="channel not found. If it's a Slack Connect / ext-shared channel it won't resolve by name (not in conversations.list) — pass its id (Cxxxx)." ;;
    not_in_channel|is_archived|channel_not_open)
      hint="can't access this channel ($err). A user token must be a member; archived/closed channels can't be read this way." ;;
    user_not_found)
      hint="user not found in the workspace directory (may be external/Slack Connect). Pass the user id (Uxxxx)." ;;
    users_not_found)
      hint="one or more users not found; check the ids." ;;
    no_permission|restricted_action|cant_update_message|cant_delete_message|message_not_found)
      hint="not permitted or target missing ($err). You can usually only edit/delete your own messages; for a reply pass the full permalink." ;;
    thread_not_found)
      hint="thread not found; pass the full permalink (it carries thread_ts)." ;;
    file_not_found|file_deleted)
      hint="file is missing or deleted ($err)." ;;
    msg_too_long)
      hint="message text exceeds Slack's limit (~40k chars); split it." ;;
    already_reacted|no_reaction)
      hint="reaction state already as requested ($err)." ;;
    rate_limited|ratelimited)
      hint="still rate-limited after retries; wait and try again." ;;
    *) hint="" ;;
  esac
  if [ -n "$hint" ]; then
    echo "slacker.sh: $method failed [$err] — $hint" >&2
  else
    echo "slacker.sh: API error on $method: $err" >&2
  fi
}

# slacker_api <method> [curl --data-urlencode args...]
# Returns the JSON body on stdout. Non-zero + stderr message on transport or API error.
# curl --retry honors Retry-After on 429/503, so rate limits self-heal.
slacker_api() {
  # Enforce the token here (once), not in the dispatcher, so usage/help works
  # before a token is configured — the cost is only paid on a real API call.
  [ -n "${_SLACKER_TOKEN_OK:-}" ] || { slacker_require_token || return 1; _SLACKER_TOKEN_OK=1; }
  local method="$1"; shift
  local body
  body=$(curl -sS --retry 3 --retry-connrefused \
    -X POST "$SLACKER_API_BASE/$method" \
    -H "Authorization: Bearer ${SLACKER_SH_TOKEN}" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
    "$@") || { echo "slacker.sh: network/curl failure calling $method (check connectivity)" >&2; return 1; }

  if [ "$(printf '%s' "$body" | jq -r '.ok')" != "true" ]; then
    slacker_explain_error "$method" "$(printf '%s' "$body" | jq -r '.error // "unknown"')" "$body"
    return 1
  fi
  printf '%s' "$body"
}

# slacker_fetch_paginated <method> <array_field> [extra --data-urlencode args...]
# Follows response_metadata.cursor to completion, returns the concatenated array.
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
    cursor=$(printf '%s' "$body" | jq -r '.response_metadata.cursor // ""')
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
    cursor=$(printf '%s' "$body" | jq -r '.response_metadata.cursor // ""')
    if [ "$(printf '%s' "$body" | jq -r '.has_more')" = "true" ] && [ -n "$cursor" ]; then
      [ "$got" -ge "$cap" ] && { truncated=true; break; }
    else
      break
    fi
  done
  jq -cn --slurpfile m "$tmp" --argjson t "$truncated" '{messages:$m, truncated:$t}'
  rm -f "$tmp"
}
