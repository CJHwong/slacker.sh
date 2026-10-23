# shellcheck shell=bash
# help: read | every conversation this token can see: channels, DMs, group DMs, archived included
# actions/list-conversations.sh — the starting point for a full export.
# One conversations.list sweep (the same one the channels cache makes), followed
# to its last cursor, rendered with the type and state of each conversation.
# Sourced by slacker.sh with the action args as "$@".

slacker_list_conversations() {
  if [ $# -gt 0 ]; then
    echo "usage: slacker.sh list-conversations" >&2
    return 1
  fi

  local users_file convs
  users_file=$(slacker_users_cache) || return 1
  convs=$(mktemp "${TMPDIR:-/tmp}/slacker_convs.XXXXXX")
  slacker_fetch_paginated conversations.list channels \
    --data-urlencode "types=public_channel,private_channel,mpim,im" \
    --data-urlencode "exclude_archived=false" > "$convs" || { rm -f "$convs"; return 1; }

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($users[0]) as $u | ($convs[0]) as $cs |
    def type_of: if .is_im then "im" elif .is_mpim then "mpim"
                 elif .is_private then "private_channel" else "public_channel" end;
    "<conversations count=\"" + ($cs | length | tostring) + "\">\n"
    + (([ $cs[] |
        "  <conversation id=\"" + attr(.id) + "\" type=\"" + type_of + "\""
        + (if .is_im then " user=\"" + attr(user_name($u; .user) // .user // "") + "\""
           else " name=\"" + attr(.name // "") + "\"" end)
        + (if .is_archived then " archived=\"true\"" else "" end)
        + (if .is_member then " member=\"true\"" else "" end)
        + (if .num_members != null then " members=\"" + (.num_members | tostring) + "\"" else "" end)
        + "/>\n" ] | add) // "")
    + "</conversations>"
  ' --slurpfile users "$users_file" --slurpfile convs "$convs"
  local rc=$?
  rm -f "$convs"
  return "$rc"
}

slacker_list_conversations "$@"
