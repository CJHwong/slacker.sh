# shellcheck shell=bash
# help: write | edit one of your messages
# actions/edit.sh — edit a message (own messages only).
# chat.update with markdown_text by default (--mrkdwn for raw Slack mrkdwn).
# Sourced by slacker.sh with the action args as "$@".

slacker_edit() {
  local url="" chan="" ts="" text="" raw_mrkdwn=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) chan="$2"; shift 2 ;;
      --ts)      ts="$2"; shift 2 ;;
      --mrkdwn)  raw_mrkdwn="true"; shift ;;
      http*)     url="$1"; shift ;;
      -*)        echo "edit: unknown flag $1" >&2; return 1 ;;
      *)         if [ -z "$text" ]; then text="$1"; else text="$text $1"; fi; shift ;;
    esac
  done
  if [ -z "$text" ]; then
    echo "usage: slacker.sh edit <permalink>|--channel <ch> --ts <ts> \"new text\" [--mrkdwn]" >&2
    return 1
  fi

  local channels_file parsed cid mts field perma
  channels_file=$(slacker_channels_cache) || return 1
  parsed=$(slacker_resolve_message "$url" "$chan" "$ts" "$channels_file") || return 1
  cid=$(printf '%s' "$parsed" | cut -f1); mts=$(printf '%s' "$parsed" | cut -f2)

  field=$(slacker_text_field "$raw_mrkdwn")
  slacker_api chat.update --data-urlencode "channel=$cid" --data-urlencode "ts=$mts" \
    --data-urlencode "$field=$text" >/dev/null || return 1
  perma=$(slacker_api chat.getPermalink --data-urlencode "channel=$cid" \
    --data-urlencode "message_ts=$mts" 3>/dev/null | jq -r '.permalink // ""') || perma=""

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<edited channel=\"" + attr($cid) + "\" ts=\"" + attr($ts) + "\" permalink=\"" + attr($perma) + "\"/>"
  ' --arg cid "$cid" --arg ts "$mts" --arg perma "$perma"
}

slacker_edit "$@"
