# shellcheck shell=bash
# actions/delete.sh — delete a message (own messages only; irreversible).
# chat.delete. Target by permalink or --channel/--ts.
# Sourced by slacker.sh with the action args as "$@".

slacker_delete() {
  local url="" chan="" ts=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) chan="$2"; shift 2 ;;
      --ts)      ts="$2"; shift 2 ;;
      http*)     url="$1"; shift ;;
      -*)        echo "delete: unknown flag $1" >&2; return 1 ;;
      *)         url="$1"; shift ;;
    esac
  done
  if [ -z "$url" ] && { [ -z "$chan" ] || [ -z "$ts" ]; }; then
    echo "usage: slacker.sh delete <permalink>|--channel <ch> --ts <ts>" >&2
    return 1
  fi

  local channels_file parsed cid mts
  channels_file=$(slacker_channels_cache) || return 1
  parsed=$(slacker_resolve_message "$url" "$chan" "$ts" "$channels_file") || return 1
  cid=$(printf '%s' "$parsed" | cut -f1); mts=$(printf '%s' "$parsed" | cut -f2)

  slacker_api chat.delete --data-urlencode "channel=$cid" --data-urlencode "ts=$mts" >/dev/null || return 1
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<deleted channel=\"" + attr($cid) + "\" ts=\"" + attr($ts) + "\"/>"
  ' --arg cid "$cid" --arg ts "$mts"
}

slacker_delete "$@"
