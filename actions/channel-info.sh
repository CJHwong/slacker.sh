# shellcheck shell=bash
# actions/channel-info.sh — channel dossier.
# Composes conversations.info + conversations.members + pins.list, with member
# and author IDs resolved to names. One XML record.
# Sourced by slacker.sh with the action args as "$@".

slacker_channel_info() {
  local channel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) echo "channel-info: unknown flag $1" >&2; return 1 ;;
      *)  channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: slacker.sh channel-info <#channel|id>" >&2; return 1; }

  local users_file channels_file chan_id info pins
  users_file=$(slacker_users_cache) || return 1
  channels_file=$(slacker_channels_cache) || return 1
  chan_id=$(slacker_resolve_channel "$channel" "$channels_file") || return 1

  info=$(slacker_api conversations.info --data-urlencode "channel=$chan_id" \
    --data-urlencode "include_num_members=true") || return 1
  pins=$(slacker_api pins.list --data-urlencode "channel=$chan_id") || pins='{"items":[]}'
  # members can be thousands; keep them in a file (ARG_MAX-safe).
  local membersf; membersf=$(mktemp "${TMPDIR:-/tmp}/slacker_mem.XXXXXX")
  slacker_fetch_paginated conversations.members members --data-urlencode "channel=$chan_id" > "$membersf" || printf '[]' > "$membersf"

  # Resolve any external/unknown authors (creator, members, pin authors).
  local umap; umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  jq -n --argjson info "$info" --slurpfile members "$membersf" --argjson pins "$pins" \
    '{creator:{user:$info.channel.creator}, members:[$members[0][]|{user:.}], pins:$pins}' \
    | slacker_augment_users "$users_file" > "$umap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($users[0]) as $u | ($channels[0]) as $c | ($info.channel) as $ch | ($members[0]) as $mem |
    "<channel id=\"" + attr($ch.id) + "\" name=\"" + attr($ch.name) + "\""
    + (if $ch.is_private then " private=\"true\"" else "" end)
    + (if $ch.is_archived then " archived=\"true\"" else "" end)
    + " created=\"" + (($ch.created // "") | fmt_ts) + "\""
    + " creator=\"" + attr(user_name($u; $ch.creator) // $ch.creator // "") + "\">\n"
    + (if ($ch.topic.value // "") != "" then "  <topic>" + ($ch.topic.value | xml_escape) + "</topic>\n" else "" end)
    + (if ($ch.purpose.value // "") != "" then "  <purpose>" + ($ch.purpose.value | xml_escape) + "</purpose>\n" else "" end)
    + "  <members count=\"" + (($mem | length) | tostring) + "\">\n"
    + (([ $mem[] | "    <member>" + ((user_name($u; .) // .) | xml_escape) + "</member>\n" ] | add) // "")
    + "  </members>\n"
    + (($pins.items // []) as $pn
       | if ($pn | length) == 0 then ""
         else "  <pinned count=\"" + (($pn | length) | tostring) + "\">\n"
           + (([ $pn[] | select(.message != null)
                 | "    <pin author=\"" + attr(user_name($u; .message.user) // .message.user // "") + "\">"
                   + ((.message.text // "") | resolve_text($u; $c) | xml_escape) + "</pin>\n" ] | add) // "")
           + "  </pinned>\n"
         end)
    + "</channel>"
  ' \
    --slurpfile users "$umap" \
    --slurpfile channels "$channels_file" \
    --slurpfile members "$membersf" \
    --argjson info "$info" \
    --argjson pins "$pins"
  rm -f "$umap" "$membersf"
}

slacker_channel_info "$@"
