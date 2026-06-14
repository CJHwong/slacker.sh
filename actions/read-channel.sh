# shellcheck shell=bash
# help: read | channel/DM history (threads shown as replies="N")
# actions/read-channel.sh — the flagship composite.
# One intention ("show me what's happening in #channel") composed from
# conversations.list + conversations.history + users.list + conversations.replies
# + conversations.info, rendered into a single fully-resolved XML payload.
# Sourced by slacker.sh with the action args as "$@".
# Shared helpers (slacker_resolve_channel, slacker_to_epoch) live in lib/parse.sh.

# Parallel worker: fetch one thread and write its {ts: replies(+marker)} map to a
# file. Run via xargs -P (see below); reads its inputs from the SLACKER_RC_* env.
slacker__rc_reply_worker() {
  local pts="$1" rdata
  [ -n "$pts" ] || return 0
  rdata=$(slacker_fetch_replies "$SLACKER_RC_CHAN" "$pts" "$SLACKER_RC_CAP") || return 0
  printf '%s' "$rdata" | jq -c --arg p "$pts" \
    '{($p): ([.messages[] | select(.ts != $p)] + (if .truncated then [{slacker_more:true}] else [] end))}' \
    > "$SLACKER_RC_DIR/$pts.json"
}

slacker_read_channel() {
  # Threads are NOT inlined by default — each message shows replies="N" instead,
  # so the agent sees thread sizes cheaply and can read-message to drill in.
  # --threads inlines them (one Slack call per thread; slower on busy channels).
  local channel="" since="" limit=200 with_threads=0 reply_cap=200
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)      since="$2"; shift 2 ;;
      --limit)      limit="$2"; shift 2 ;;
      --reply-cap)  reply_cap="$2"; shift 2 ;;
      --threads)    with_threads=1; shift ;;
      --no-threads) with_threads=0; shift ;;  # explicit; this is also the default
      -*)           echo "read-channel: unknown flag $1" >&2; return 1 ;;
      *)            channel="$1"; shift ;;
    esac
  done
  if [ -z "$channel" ]; then
    echo "usage: slacker.sh read-channel <#ch|@user|id> [--since <date|7d>] [--limit N] [--threads] [--reply-cap N]" >&2
    return 1
  fi

  local users_file channels_file chan_id
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1
  chan_id=$(slacker_resolve_target "$channel" "$channels_file") || return 1

  local oldest_arg=()
  if [ -n "$since" ]; then
    local oldest; oldest=$(slacker_to_epoch "$since") || return 1
    oldest_arg=(--data-urlencode "oldest=$oldest")
  fi

  # Paginate history up to limit into a JSONL temp file (one message per line),
  # so nothing large is ever passed on the command line (ARG_MAX-safe).
  local msgsf threadsf cursor="" body got=0 more=false page
  msgsf=$(mktemp "${TMPDIR:-/tmp}/slacker_msgs.XXXXXX")
  while :; do
    page=$(( limit - got )); [ "$page" -gt 200 ] && page=200
    if [ "$page" -le 0 ]; then more=true; break; fi
    if [ -n "$cursor" ]; then
      body=$(slacker_api conversations.history --data-urlencode "channel=$chan_id" \
        --data-urlencode "limit=$page" --data-urlencode "cursor=$cursor" "${oldest_arg[@]}") || { rm -f "$msgsf"; return 1; }
    else
      body=$(slacker_api conversations.history --data-urlencode "channel=$chan_id" \
        --data-urlencode "limit=$page" "${oldest_arg[@]}") || { rm -f "$msgsf"; return 1; }
    fi
    printf '%s' "$body" | jq -c '.messages[]?' >> "$msgsf"
    got=$(grep -c . "$msgsf" 2>/dev/null || printf 0)
    cursor=$(printf '%s' "$body" | jq -r '.response_metadata.cursor // ""')
    if [ "$(printf '%s' "$body" | jq -r '.has_more')" = "true" ] && [ -n "$cursor" ]; then
      if [ "$got" -ge "$limit" ]; then more=true; break; fi
    else
      break
    fi
  done

  # Inline thread replies into a JSONL temp file of {ts: replies} maps. Each
  # parent's conversations.replies is fetched in parallel (one Slack call per
  # thread is the read-channel bottleneck) bounded by SLACKER_CONCURRENCY.
  threadsf=$(mktemp "${TMPDIR:-/tmp}/slacker_thr.XXXXXX")
  if [ "$with_threads" -eq 1 ]; then
    local parents wdir
    parents=$(jq -r 'select((.reply_count // 0) > 0) | (.thread_ts // .ts)' "$msgsf" | sort -u)
    if [ -n "$parents" ]; then
      wdir=$(mktemp -d "${TMPDIR:-/tmp}/slacker_thrd.XXXXXX")
      export SLACKER_RC_CHAN="$chan_id" SLACKER_RC_CAP="$reply_cap" SLACKER_RC_DIR="$wdir"
      export -f slacker__rc_reply_worker slacker_fetch_replies slacker_api slacker_explain_error
      printf '%s\n' "$parents" \
        | xargs -P "${SLACKER_CONCURRENCY:-8}" -I {} bash -c 'slacker__rc_reply_worker "$@"' _ {} 2>/dev/null || true
      cat "$wdir"/*.json > "$threadsf" 2>/dev/null || true
    fi
  fi

  # Channel meta (name + topic) for the wrapper element.
  local info name topic meta
  info=$(slacker_api conversations.info --data-urlencode "channel=$chan_id") || info='{}'
  name=$(printf '%s' "$info" | jq -r '.channel.name // empty')
  if [ -z "$name" ]; then
    # DM: conversations.info gives the counterpart user id directly.
    local dmuser; dmuser=$(printf '%s' "$info" | jq -r '.channel.user // empty')
    if [ -n "$dmuser" ]; then
      name="dm:$(jq -r --arg id "$dmuser" '.[$id].n // $id' "$users_file")"
    else
      name=$(slacker_dm_label "$(jq -r --arg id "$chan_id" '.[$id] // $id' "$channels_file")" "$users_file")
    fi
  fi
  topic=$(printf '%s' "$info" | jq -r '.channel.topic.value // ""')
  meta=$(jq -n --arg id "$chan_id" --arg name "$name" --arg topic "$topic" '{id:$id,name:$name,topic:$topic}')

  # Resolve external/unknown users referenced here (msgs + threads, via files).
  local umap; umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  jq -cn --slurpfile m "$msgsf" --slurpfile t "$threadsf" '{m:$m,t:$t}' \
    | slacker_augment_users "$users_file" > "$umap"

  # Render. --slurpfile turns each JSONL file into an array; threads merge to a map.
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($users[0]) as $u | ($channels[0]) as $c | ($threads | add // {}) as $t |
    "<channel name=\"" + attr($meta.name) + "\" id=\"" + attr($meta.id) + "\""
      + (if ($meta.topic // "") != "" then " topic=\"" + attr($meta.topic) + "\"" else "" end) + ">\n"
    + (($msgs | reverse | map(render_msg($u; $c; $t; ""))) | add // "")
    + (if $more then "  <more note=\"limit reached — use --since or a larger --limit for older messages\"/>\n" else "" end)
    + "</channel>"
  ' \
    --slurpfile users "$umap" \
    --slurpfile channels "$channels_file" \
    --slurpfile threads "$threadsf" \
    --slurpfile msgs "$msgsf" \
    --argjson meta "$meta" \
    --argjson more "$more"
  rm -f "$umap" "$msgsf" "$threadsf"
}

slacker_read_channel "$@"
