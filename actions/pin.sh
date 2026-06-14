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
  slacker_api "$method" --data-urlencode "channel=$cid" --data-urlencode "timestamp=$mts" >/dev/null || return 1
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<pin status=\"" + attr($verb) + "\" channel=\"" + attr($cid) + "\" ts=\"" + attr($ts) + "\"/>"
  ' --arg verb "$verb" --arg cid "$cid" --arg ts "$mts"
}

slacker_pin "$@"
