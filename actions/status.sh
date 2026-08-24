# shellcheck shell=bash
# help: write | set or clear your profile status
# actions/status.sh — set the authenticated user's custom status.
# users.profile.set. The rendered <status> echoes what Slack stored, not what was
# sent, so a server-side truncation or rewrite is visible in the result.
# Sourced by slacker.sh with the action args as "$@".

slacker_status() {
  local text="" emoji=":speech_balloon:" emoji_given="" clear="" expires="0"
  while [ $# -gt 0 ]; do
    case "$1" in
      --emoji)   emoji="$2"; emoji_given="true"; shift 2 ;;
      --expires) expires="$2"; shift 2 ;;
      --clear)   clear="true"; shift ;;
      -*)        echo "status: unknown flag $1" >&2; return 1 ;;
      *)         if [ -z "$text" ]; then text="$1"; else text="$text $1"; fi; shift ;;
    esac
  done

  if [ -n "$clear" ]; then
    text=""; emoji=""; expires=0
  elif [ -z "$text" ] && [ -z "$emoji_given" ]; then
    echo "usage: slacker.sh status <text> [--emoji <:name:>] [--expires <when>] | --clear" >&2
    return 1
  else
    # Slack accepts an emoji-only status, so --emoji alone is a valid call. Only
    # a bare `status` with neither is a usage error.
    # Accept `dart` or `:dart:`; users.profile.set wants the colon form.
    emoji="${emoji#:}"; emoji="${emoji%:}"
    [ -n "$emoji" ] && emoji=":${emoji}:"
    if [ "$expires" != "0" ]; then
      expires=$(slacker_when_epoch "$expires") || return 1
    fi
  fi

  # Slack's status_text ceiling is 100 and it is a hard error (`too_long`), not a
  # truncation — probed live, 100 accepted / 101 rejected. It counts code points,
  # not bytes: 100 CJK characters (300 bytes) is accepted. So count with jq, never
  # ${#text}, which counts bytes under a non-UTF-8 locale and would reject a valid
  # CJK status at a third of the real limit. Catching it here rather than letting
  # the API answer keeps the message actionable and saves the round trip.
  local len
  len=$(jq -rn --arg t "$text" '$t | length')
  if [ "$len" -gt 100 ]; then
    slacker_error status_too_long recover \
      "status text is $len characters; Slack rejects status_text over 100 (too_long)." \
      "Shorten the text to 100 characters or fewer, then retry. The limit counts characters, not bytes, so CJK costs 1 each."
    return 1
  fi

  local profile body
  profile=$(jq -cn --arg text "$text" --arg emoji "$emoji" --argjson exp "$expires" \
    '{status_text:$text, status_emoji:$emoji, status_expiration:$exp}')
  body=$(slacker_api users.profile.set --data-urlencode "profile=$profile") || return 1

  printf '%s' "$body" | jq -r -L "$SLACKER_ROOT/lib" 'include "render";
    .profile as $p |
    "<status text=\"" + attr($p.status_text // "")
    + "\" emoji=\"" + attr($p.status_emoji // "")
    + "\" expires=\"" + (($p.status_expiration // 0) | if . == 0 then "never" else (. | fmt_ts) end)
    + "\"/>"'
}

slacker_status "$@"
