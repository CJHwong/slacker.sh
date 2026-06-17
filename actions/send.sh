# shellcheck shell=bash
# help: write | post a message, DM, or file
# actions/send.sh — post a message, optionally with file attachments.
# Text-only: chat.postMessage. With --file: the 3-step external upload flow
# (getUploadURLExternal -> POST bytes -> completeUploadExternal), where the
# message text becomes the upload's initial_comment.
# Sourced by slacker.sh with the action args as "$@".

# Resolve --thread (permalink or raw ts) to a thread_ts, echoed on stdout.
slacker_thread_ts() {
  local thread="$1"
  case "$thread" in
    http*) local parsed pt p2
           parsed=$(slacker_parse_permalink "$thread") || return 1
           pt=$(printf '%s' "$parsed" | cut -f3); p2=$(printf '%s' "$parsed" | cut -f2)
           printf '%s' "${pt:-$p2}" ;;
    *)     printf '%s' "$thread" ;;
  esac
}

slacker_send() {
  local channel="" text="" thread="" broadcast="" thread_ts="" no_unfurl="" raw_mrkdwn=""
  local files=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --thread)     thread="$2"; shift 2 ;;
      --broadcast)  broadcast="true"; shift ;;
      --no-unfurl)  no_unfurl="true"; shift ;;
      --mrkdwn)     raw_mrkdwn="true"; shift ;;
      --file)       files+=("$2"); shift 2 ;;
      -*)           echo "send: unknown flag $1" >&2; return 1 ;;
      *)            if [ -z "$channel" ]; then channel="$1"
                    elif [ -z "$text" ]; then text="$1"
                    else text="$text $1"; fi; shift ;;
    esac
  done
  if [ -z "$channel" ] || { [ -z "$text" ] && [ ${#files[@]} -eq 0 ]; }; then
    echo "usage: slacker.sh send <#ch|@user|id> <text> [--thread <permalink|ts>] [--broadcast] [--no-unfurl] [--mrkdwn] [--file <path>]..." >&2
    echo "  text is standard Markdown by default (**bold**, [label](url), - lists); Slack renders it." >&2
    echo "  --mrkdwn: treat text as raw Slack mrkdwn (*bold*, <url|label>) instead." >&2
    echo "  note: --file captions are raw Slack mrkdwn only (Slack's upload API ignores markdown_text)." >&2
    return 1
  fi

  local channels_file chan_id
  channels_file=$(slacker_channels_cache) || return 1
  chan_id=$(slacker_resolve_target "$channel" "$channels_file") || return 1
  [ -n "$thread" ] && { thread_ts=$(slacker_thread_ts "$thread") || return 1; }

  if [ ${#files[@]} -gt 0 ]; then
    # Render-friendly caption: with a caption and no explicit thread (and not
    # raw mode), post the caption as a markdown_text message and thread the
    # file(s) under it, so the caption renders (uploads can't render Markdown).
    if [ -n "$text" ] && [ -z "$thread_ts" ] && [ -z "$raw_mrkdwn" ]; then
      local cap_args=() cap_resp cap_ts
      [ -n "$no_unfurl" ] && cap_args+=(--data-urlencode "unfurl_links=false" --data-urlencode "unfurl_media=false")
      cap_resp=$(slacker_api chat.postMessage --data-urlencode "channel=$chan_id" \
        --data-urlencode "markdown_text=$text" "${cap_args[@]}") || return 1
      cap_ts=$(printf '%s' "$cap_resp" | jq -r '.ts')
      slacker_send_with_files "$channel" "$chan_id" "" "$cap_ts" "${files[@]}"
      return $?
    fi
    slacker_send_with_files "$channel" "$chan_id" "$text" "$thread_ts" "${files[@]}"
    return $?
  fi

  local thread_arg=() resp ts perma
  if [ -n "$thread_ts" ]; then
    thread_arg=(--data-urlencode "thread_ts=$thread_ts")
    [ -n "$broadcast" ] && thread_arg+=(--data-urlencode "reply_broadcast=true")
  fi
  [ -n "$no_unfurl" ] && thread_arg+=(--data-urlencode "unfurl_links=false" --data-urlencode "unfurl_media=false")
  # Default: markdown_text — Slack converts standard Markdown to rich_text, which
  # renders correctly regardless of CJK word-boundary quirks. --mrkdwn sends raw.
  local text_field="markdown_text"; [ -n "$raw_mrkdwn" ] && text_field="text"
  resp=$(slacker_api chat.postMessage --data-urlencode "channel=$chan_id" \
    --data-urlencode "$text_field=$text" "${thread_arg[@]}") || return 1
  ts=$(printf '%s' "$resp" | jq -r '.ts')
  perma=$(slacker_api chat.getPermalink --data-urlencode "channel=$chan_id" \
    --data-urlencode "message_ts=$ts" 3>/dev/null | jq -r '.permalink // ""') || perma=""

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<sent channel=\"" + attr($name) + "\" id=\"" + attr($cid)
    + "\" ts=\"" + attr($ts) + "\" permalink=\"" + attr($perma) + "\"/>"
  ' --arg name "$channel" --arg cid "$chan_id" --arg ts "$ts" --arg perma "$perma"
}

slacker_send_with_files() {
  local name="$1" chan_id="$2" text="$3" thread_ts="$4"; shift 4
  local uploads="[]" path len fn up url fid resp

  for path in "$@"; do
    [ -f "$path" ] || { slacker_error file_not_found escalate "file not found: $path." \
      "Check the path and retry."; return 1; }
    len=$(slacker_fsize "$path"); fn=$(basename "$path")
    up=$(slacker_api files.getUploadURLExternal \
      --data-urlencode "filename=$fn" --data-urlencode "length=$len") || return 1
    url=$(printf '%s' "$up" | jq -r '.upload_url')
    fid=$(printf '%s' "$up" | jq -r '.file_id')
    curl -sSL --data-binary @"$path" "$url" >/dev/null \
      || { slacker_error upload_failed escalate "byte upload failed for $path." \
           "Retry; if it persists the file may be too large or the upload URL expired."; return 1; }
    uploads=$(jq -cn --argjson a "$uploads" --arg id "$fid" --arg t "$fn" '$a + [{id:$id,title:$t}]')
  done

  # NB: completeUploadExternal ignores markdown_text and treats initial_comment as
  # raw Slack mrkdwn (verified) — file captions are the one non-Markdown surface.
  local comp_args=(--data-urlencode "files=$uploads" --data-urlencode "channel_id=$chan_id")
  [ -n "$text" ]      && comp_args+=(--data-urlencode "initial_comment=$text")
  [ -n "$thread_ts" ] && comp_args+=(--data-urlencode "thread_ts=$thread_ts")
  resp=$(slacker_api files.completeUploadExternal "${comp_args[@]}") || return 1

  # When threaded (e.g. under a rendered caption), report the parent permalink.
  local parent_perma=""
  if [ -n "$thread_ts" ]; then
    parent_perma=$(slacker_api chat.getPermalink --data-urlencode "channel=$chan_id" \
      --data-urlencode "message_ts=$thread_ts" 3>/dev/null | jq -r '.permalink // ""') || parent_perma=""
  fi

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<sent channel=\"" + attr($name) + "\" id=\"" + attr($cid) + "\""
    + (if $tts != "" then " thread_ts=\"" + attr($tts) + "\"" else "" end)
    + (if $pp != "" then " permalink=\"" + attr($pp) + "\"" else "" end) + ">\n"
    + (([ $res.files[] | "  <file id=\"" + attr(.id) + "\" title=\"" + attr(.title // "")
          + "\" permalink=\"" + attr(.permalink // "") + "\"/>\n" ] | add) // "")
    + "</sent>"
  ' --arg name "$name" --arg cid "$chan_id" --argjson res "$resp" \
    --arg tts "$thread_ts" --arg pp "$parent_perma"
}

slacker_send "$@"
