# shellcheck shell=bash
# help: write | add or remove a reaction
# actions/react.sh — add (or remove) a reaction.
# Composes reactions.add / reactions.remove. Target by permalink or --channel/--ts.
# Sourced by slacker.sh with the action args as "$@".

slacker_react() {
  local url="" emoji="" chan="" ts="" remove=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) chan="$2"; shift 2 ;;
      --ts)      ts="$2"; shift 2 ;;
      --remove)  remove="true"; shift ;;
      http*)     url="$1"; shift ;;
      -*)        echo "react: unknown flag $1" >&2; return 1 ;;
      *)         emoji="$1"; shift ;;
    esac
  done
  emoji="${emoji#:}"; emoji="${emoji%:}"
  [ -n "$emoji" ] || { echo "usage: slacker.sh react <permalink>|--channel <ch> --ts <ts> <emoji> [--remove]" >&2; return 1; }

  local channels_file parsed chan_id msg_ts
  channels_file=$(slacker_channels_cache) || return 1
  parsed=$(slacker_resolve_message "$url" "$chan" "$ts" "$channels_file") || return 1
  chan_id=$(printf '%s' "$parsed" | cut -f1)
  msg_ts=$(printf '%s' "$parsed" | cut -f2)

  local method="reactions.add" verb="added"
  [ -n "$remove" ] && { method="reactions.remove"; verb="removed"; }
  slacker_api "$method" --data-urlencode "channel=$chan_id" \
    --data-urlencode "timestamp=$msg_ts" --data-urlencode "name=$emoji" >/dev/null || return 1

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<reaction status=\"" + attr($verb) + "\" emoji=\"" + attr($emoji)
    + "\" channel=\"" + attr($cid) + "\" ts=\"" + attr($ts) + "\"/>"
  ' --arg verb "$verb" --arg emoji "$emoji" --arg cid "$chan_id" --arg ts "$msg_ts"
}

slacker_react "$@"
