# shellcheck shell=bash
# help: write | open or resume a DM with one or more people
# actions/open-dm.sh — explicit conversation opening, without sending a message.
# Resolve the entire audience before conversations.open; return its receipt even
# when a subsequent membership read fails, so callers never blindly recreate it.

slacker_open_dm() {
  [ "$#" -gt 0 ] || {
    echo "usage: slacker.sh open-dm <@user|name|id|email>..." >&2
    echo "  1–8 other people; the token owner is included automatically. Sends no message." >&2
    return 1
  }
  local input
  for input in "$@"; do
    case "$input" in
      -*) echo "open-dm: unknown flag $input" >&2; return 1 ;;
      '') slacker_error bad_participants recover "A participant is empty." \
            "Pass each person as a separate handle, name, user id, or email."; return 1 ;;
    esac
  done

  local auth self users_file uid ids="" count=0
  auth=$(slacker_api auth.test) || return 1
  self=$(printf '%s' "$auth" | jq -er '.user_id | select(type == "string" and test("^[UW][A-Z0-9]+$"))') || {
    slacker_error bad_identity escalate "auth.test returned no valid user identity." \
      "Check the configured Slack user account before opening a conversation."
    return 1
  }
  users_file=$(slacker_users_cache) || return 1
  for input in "$@"; do
    uid=$(slacker_resolve_user "$input" "$users_file" strict) || return 1
    if ! printf '%s' "$uid" | jq -Re 'test("^[UW][A-Z0-9]+$")' >/dev/null; then
      slacker_error bad_participants recover "Not a single Slack user id: $uid." \
        "Pass each participant separately; do not use comma-separated ids."
      return 1
    fi
    [ "$uid" = "$self" ] && continue
    case ",$ids," in *",$uid,"*) continue ;; esac
    ids="${ids:+$ids,}$uid"
    count=$((count + 1))
    if [ "$count" -gt 8 ]; then
      slacker_error too_many_users recover "A DM supports at most 8 other people." \
        "Choose up to 8 distinct people, excluding the token owner."
      return 1
    fi
  done
  if [ "$count" -eq 0 ]; then
    slacker_error not_enough_users recover "No other participants were supplied." \
      "Name at least one person other than the token owner."
    return 1
  fi

  # Resolve missing directory entries before the write, including the caller.
  # Unlike best-effort read enrichment, failure here must prevent the mutation.
  local expected map info
  expected=$(jq -cn --arg csv "$self,$ids" '$csv | split(",")')
  map=$(mktemp "${TMPDIR:-/tmp}/slacker_dm_users.XXXXXX")
  cp "$users_file" "$map"
  while IFS= read -r uid; do
    if ! jq -e --arg id "$uid" '.[$id] != null' "$map" >/dev/null; then
      info=$(slacker_api users.info --data-urlencode "user=$uid") || return 1
      if ! printf '%s' "$info" | jq -e --arg id "$uid" '.user.id == $id' >/dev/null; then
        slacker_error bad_identity escalate "users.info returned a different participant." \
          "Check the requested user ids; no conversation was opened."
        return 1
      fi
      jq --argjson info "$info" --arg id "$uid" \
        '.[$id] = {n:(($info.user.profile.display_name | select(. != "")) // $info.user.real_name // $id),
                    d:($info.user.deleted // false)}' "$map" > "$map.tmp"
      mv "$map.tmp" "$map"
    fi
    if jq -e --arg id "$uid" '.[$id].d == true' "$map" >/dev/null; then
      slacker_error user_disabled escalate "Participant $uid is deactivated." \
        "Choose an active participant; no conversation was opened."
      return 1
    fi
  done <<EOF
$(printf '%s' "$expected" | jq -r '.[]')
EOF

  local response cid kind=im verified=false members verification_error="" note=""
  [ "$count" -gt 1 ] && kind=mpim
  response=$(slacker_api conversations.open --data-urlencode "users=$ids" \
    --data-urlencode "return_im=true") || return 1
  cid=$(printf '%s' "$response" | jq -er '.channel.id | select(type == "string" and test("^[CGD][A-Z0-9]+$"))') || {
    slacker_error bad_open_response escalate "Slack accepted the open but returned no valid conversation id." \
      "The conversation may exist. Inspect list-conversations before retrying; do not blindly repeat the write."
    return 1
  }

  # Capture fd 3 too: a failed verification belongs inside the successful open
  # receipt, rather than leaking a second XML document or hiding the open.
  if members=$(slacker_fetch_paginated conversations.members members \
      --data-urlencode "channel=$cid" 3>&1); then
    if printf '%s' "$members" | jq -e --argjson expected "$expected" \
        'type == "array" and (sort == ($expected | sort))' >/dev/null 2>&1; then
      verified=true
    else
      note="Conversation opened, but the returned members do not match the requested audience. Inspect channel-info before sending."
    fi
  else
    verification_error="$members"
    note="Conversation opened, but membership verification failed. Inspect channel-info before sending; do not repeat the open blindly."
  fi
  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    render_opened_dm($users[0]; $expected; $cid; $kind; $verified; $note; $error)
  ' --slurpfile users "$map" --argjson expected "$expected" --arg cid "$cid" \
    --arg kind "$kind" --argjson verified "$verified" --arg note "$note" --arg error "$verification_error"
}

slacker_open_dm "$@"
