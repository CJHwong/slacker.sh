# shellcheck shell=bash
# help: write | schedule a message, list, or cancel
# actions/schedule.sh — schedule a message, list scheduled, or cancel one.
#   slacker.sh schedule <#ch|@user> "text" --at <when> [--mrkdwn]
#   slacker.sh schedule --list [<#ch|@user>]
#   slacker.sh schedule --cancel <scheduled_id> --channel <#ch>
# <when>: epoch | "YYYY-MM-DD HH:MM" | +30m/+2h/+1d.
# Composes chat.scheduleMessage / scheduledMessages.list / deleteScheduledMessage.

slacker_schedule() {
  local target="" text="" at="" mode="create" raw_mrkdwn="" cancel_id="" chan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --at)      at="$2"; shift 2 ;;
      --list)    mode="list"; shift ;;
      --cancel)  mode="cancel"; cancel_id="$2"; shift 2 ;;
      --channel) chan="$2"; shift 2 ;;
      --mrkdwn)  raw_mrkdwn="true"; shift ;;
      -*)        echo "schedule: unknown flag $1" >&2; return 1 ;;
      *)         if [ -z "$target" ]; then target="$1"
                 elif [ -z "$text" ]; then text="$1"
                 else text="$text $1"; fi; shift ;;
    esac
  done

  local channels_file; channels_file=$(slacker_channels_cache) || return 1

  case "$mode" in
    list)
      local args=() cid resp users_file
      if [ -n "$target" ]; then cid=$(slacker_resolve_target "$target" "$channels_file") || return 1; args=(--data-urlencode "channel=$cid"); fi
      resp=$(slacker_api chat.scheduledMessages.list "${args[@]}") || return 1
      users_file=$(slacker_users_cache) || users_file=/dev/null
      jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
        ($users[0] // {}) as $u | ($channels[0]) as $c | ($res.scheduled_messages // []) as $m |
        "<scheduled_messages count=\"" + (($m | length) | tostring) + "\">\n"
        + (([ $m[] | "  <message id=\"" + attr(.id) + "\" channel=\"" + attr($c[.channel_id] // .channel_id)
              + "\" post_at=\"" + ((.post_at // "") | fmt_ts) + "\">"
              + ((.text // "") | resolve_text($u; $c) | xml_escape) + "</message>\n" ] | add) // "")
        + "</scheduled_messages>"
      ' --slurpfile users "$users_file" --slurpfile channels "$channels_file" --argjson res "$resp"
      ;;
    cancel)
      if [ -z "$cancel_id" ] || [ -z "$chan" ]; then
        echo "usage: slacker.sh schedule --cancel <scheduled_id> --channel <#ch>" >&2; return 1
      fi
      local cid; cid=$(slacker_resolve_target "$chan" "$channels_file") || return 1
      slacker_api chat.deleteScheduledMessage --data-urlencode "channel=$cid" \
        --data-urlencode "scheduled_message_id=$cancel_id" >/dev/null || return 1
      jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
        "<canceled scheduled_id=\"" + attr($id) + "\" channel=\"" + attr($cid) + "\"/>"
      ' --arg id "$cancel_id" --arg cid "$cid"
      ;;
    create)
      if [ -z "$target" ] || [ -z "$text" ] || [ -z "$at" ]; then
        echo "usage: slacker.sh schedule <#ch|@user> \"text\" --at <epoch|'YYYY-MM-DD HH:MM'|+30m> [--mrkdwn]" >&2; return 1
      fi
      local cid post_at field resp sid pa
      cid=$(slacker_resolve_target "$target" "$channels_file") || return 1
      post_at=$(slacker_when_epoch "$at") || return 1
      field=$(slacker_text_field "$raw_mrkdwn")
      resp=$(slacker_api chat.scheduleMessage --data-urlencode "channel=$cid" \
        --data-urlencode "post_at=$post_at" --data-urlencode "$field=$text") || return 1
      sid=$(printf '%s' "$resp" | jq -r '.scheduled_message_id // ""')
      pa=$(printf '%s' "$resp" | jq -r '.post_at // ""')
      jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
        "<scheduled channel=\"" + attr($cid) + "\" scheduled_id=\"" + attr($sid)
        + "\" post_at=\"" + ($pa | fmt_ts) + "\" post_at_ts=\"" + attr($pa) + "\"/>"
      ' --arg cid "$cid" --arg sid "$sid" --arg pa "$pa"
      ;;
  esac
}

slacker_schedule "$@"
