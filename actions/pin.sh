# shellcheck shell=bash
# help: write | pin or unpin a message
# actions/pin.sh — pin (or unpin) a message.
# pins.add / pins.remove. Target by permalink or --channel/--ts. Mirrors react.
# Sourced by slacker.sh with the action args as "$@".

slacker_pin() {
  local url="" chan="" ts="" remove=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) chan="$2"; shift 2 ;;
      --ts)      ts="$2"; shift 2 ;;
      --remove)  remove="true"; shift ;;
      http*)     url="$1"; shift ;;
      -*)        echo "pin: unknown flag $1" >&2; return 1 ;;
      *)         url="$1"; shift ;;
    esac
  done
  if [ -z "$url" ] && { [ -z "$chan" ] || [ -z "$ts" ]; }; then
    echo "usage: slacker.sh pin <permalink>|--channel <ch> --ts <ts> [--remove]" >&2
    return 1
  fi

  local channels_file parsed cid mts method verb
  channels_file=$(slacker_channels_cache) || return 1
  parsed=$(slacker_resolve_message "$url" "$chan" "$ts" "$channels_file") || return 1
  cid=$(printf '%s' "$parsed" | cut -f1); mts=$(printf '%s' "$parsed" | cut -f2)

  method="pins.add"; verb="added"
  [ -n "$remove" ] && { method="pins.remove"; verb="removed"; }
  # Raw call so an already-in-the-requested-state response is an accurate no-op
  # status (exit 0), not an error. Mirrors react.
  local resp err
  resp=$(slacker_api_raw "$method" --data-urlencode "channel=$cid" --data-urlencode "timestamp=$mts") || return 1
  if [ "$(printf '%s' "$resp" | jq -r '.ok')" != "true" ]; then
    err=$(printf '%s' "$resp" | jq -r '.error // "unknown"')
    case "$err" in
      already_pinned)    verb="already-present" ;;
      no_pin|not_pinned) verb="not-present" ;;  # live API returns no_pin (spec says not_pinned)
      *) slacker_explain_error "$method" "$err" "$resp"; return 1 ;;
    esac
  fi
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<pin status=\"" + attr($verb) + "\" channel=\"" + attr($cid) + "\" ts=\"" + attr($ts) + "\"/>"
  ' --arg verb "$verb" --arg cid "$cid" --arg ts "$mts"
}

slacker_pin "$@"
