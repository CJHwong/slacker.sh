# shellcheck shell=bash
# actions/read-message.sh — read a message in full context.
# Resolves a permalink (or --channel/--ts) to a message. If it belongs to a
# thread, inlines the whole thread with target="true" on the linked message.
# --no-thread collapses to just that single message.
# Sourced by slacker.sh with the action args as "$@".

slacker_read_message() {
  local url="" chan="" ts="" with_thread=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel)    chan="$2"; shift 2 ;;
      --ts)         ts="$2"; shift 2 ;;
      --no-thread)  with_thread=0; shift ;;
      -*)           echo "read-message: unknown flag $1" >&2; return 1 ;;
      *)            url="$1"; shift ;;
    esac
  done

  local users_file channels_file chan_id msg_ts thread="" single_msg=""
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1

  if [ -n "$url" ]; then
    local parsed
    parsed=$(slacker_parse_permalink "$url") || return 1
    chan_id=$(printf '%s' "$parsed" | cut -f1)
    msg_ts=$(printf '%s' "$parsed" | cut -f2)
    thread=$(printf '%s' "$parsed" | cut -f3)
  else
    if [ -z "$chan" ] || [ -z "$ts" ]; then
      echo "usage: slacker.sh read-message <permalink> | --channel <#ch|id> --ts <ts> [--no-thread]" >&2
      return 1
    fi
    chan_id=$(slacker_resolve_channel "$chan" "$channels_file") || return 1
    msg_ts="$ts"
  fi

  # Find the thread root, if any.
  local root=""
  if [ -n "$thread" ] && [ "$thread" != "$msg_ts" ]; then
    root="$thread"                      # link points at a reply
  else
    # latest=ts (no oldest) is reliable; the zero-width latest==oldest window can
    # return empty. Take the newest message <= ts and confirm it IS the target.
    local hbody rc
    hbody=$(slacker_api conversations.history --data-urlencode "channel=$chan_id" \
      --data-urlencode "latest=$msg_ts" \
      --data-urlencode "inclusive=true" --data-urlencode "limit=1") || return 1
    single_msg=$(printf '%s' "$hbody" | jq -c --arg t "$msg_ts" '(.messages[0] | select(.ts == $t)) // empty')
    rc=$(printf '%s' "$single_msg" | jq -r '.reply_count // 0' 2>/dev/null); [ -n "$rc" ] || rc=0
    [ "$rc" -gt 0 ] && root="$msg_ts"
  fi

  # Threaded + thread wanted. The outer <message> is always the linked message;
  # the whole conversation is nested as context.
  #   root link  -> outer = root, nested thread = replies
  #   reply link -> outer = the reply, nested thread = full conversation (root + replies)
  if [ "$with_thread" -eq 1 ] && [ -n "$root" ]; then
    # A thread can be large; keep the conversation in files and pass via stdin/
    # --slurpfile so nothing big hits the command line (ARG_MAX-safe).
    local rdata convof trunc focus threadsf umap
    rdata=$(slacker_fetch_replies "$chan_id" "$root" "${SLACKER_REPLY_CAP:-200}") || return 1
    convof=$(mktemp "${TMPDIR:-/tmp}/slacker_convo.XXXXXX")
    printf '%s' "$rdata" | jq -c '.messages' > "$convof"
    trunc=$(printf '%s' "$rdata" | jq -c 'if .truncated then [{slacker_more:true}] else [] end')
    focus=$(jq -c --arg t "$msg_ts" '(.[] | select(.ts == $t)) // .[0]' "$convof")
    # threads map {msg_ts: context}; context = whole convo (reply link) or replies (root link)
    threadsf=$(mktemp "${TMPDIR:-/tmp}/slacker_thr.XXXXXX")
    if [ "$msg_ts" = "$root" ]; then
      jq -c --arg t "$msg_ts" --arg r "$root" --argjson tr "$trunc" '{($t): ([.[] | select(.ts != $r)] + $tr)}' "$convof" > "$threadsf"
    else
      jq -c --arg t "$msg_ts" --argjson tr "$trunc" '{($t): (. + $tr)}' "$convof" > "$threadsf"
    fi
    umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
    slacker_augment_users "$users_file" < "$convof" > "$umap"
    jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
      ($users[0]) as $u | ($channels[0]) as $c | ($threads[0]) as $tmap |
      ($focus | render_msg($u; $c; $tmap; $target))
    ' \
      --slurpfile users "$umap" \
      --slurpfile channels "$channels_file" \
      --slurpfile threads "$threadsf" \
      --argjson focus "$focus" \
      --arg target "$msg_ts"
    rm -f "$umap" "$convof" "$threadsf"
    return 0
  fi

  # Single message: standalone, --no-thread, or a reply with --no-thread.
  local msg umap
  if [ -n "$single_msg" ]; then
    msg="$single_msg"
  elif [ -n "$thread" ]; then
    local rbody
    rbody=$(slacker_api conversations.replies --data-urlencode "channel=$chan_id" \
      --data-urlencode "ts=${root:-$thread}" --data-urlencode "limit=200") || return 1
    msg=$(printf '%s' "$rbody" | jq -c --arg t "$msg_ts" '(.messages[] | select(.ts == $t)) // empty')
  fi
  if [ -z "$msg" ] || [ "$msg" = "null" ]; then
    echo "read-message: message $msg_ts not found in $chan_id" >&2
    echo "  (if it's a thread reply, pass the full permalink so thread_ts is known)" >&2
    return 1
  fi

  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  printf '%s' "$msg" | slacker_augment_users "$users_file" > "$umap"
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($users[0]) as $u | ($channels[0]) as $c |
    ($msg | render_msg($u; $c; {}; ""))
  ' \
    --slurpfile users "$umap" \
    --slurpfile channels "$channels_file" \
    --argjson msg "$msg"
  rm -f "$umap"
}

slacker_read_message "$@"
