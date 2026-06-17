# shellcheck shell=bash
# help: read | person dossier: presence, dnd, tz, shared channels
# actions/whois.sh — person dossier.
# users.info + users.getPresence + dnd.info, with optional --channels
# (users.conversations). Accepts @name / name / Uxxxx / email.
# Sourced by slacker.sh with the action args as "$@".

slacker_whois() {
  local who="" with_channels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channels) with_channels="true"; shift ;;
      -*)         echo "whois: unknown flag $1" >&2; return 1 ;;
      *)          who="$1"; shift ;;
    esac
  done
  [ -n "$who" ] || { echo "usage: slacker.sh whois <@user|name|Uxxxx|email> [--channels]" >&2; return 1; }

  local users_file uid info presence dnd channels='[]'
  users_file=$(slacker_users_cache) || return 1
  uid=$(slacker_resolve_user "$who" "$users_file") || return 1

  info=$(slacker_api users.info --data-urlencode "user=$uid") || return 1
  presence=$(slacker_api users.getPresence --data-urlencode "user=$uid" 3>/dev/null) || presence='{}'
  dnd=$(slacker_api dnd.info --data-urlencode "user=$uid" 3>/dev/null) || dnd='{}'
  if [ -n "$with_channels" ]; then
    channels=$(slacker_fetch_paginated users.conversations channels \
      --data-urlencode "user=$uid" --data-urlencode "types=public_channel,private_channel" \
      --data-urlencode "exclude_archived=true" 3>/dev/null) || channels='[]'
  fi

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($info.user) as $u | ($presence) as $p | ($dnd) as $d |
    "<user id=\"" + attr($u.id)
    + "\" name=\"" + attr((($u.profile.display_name // "") | select(. != "")) // $u.real_name // $u.name)
    + "\" presence=\"" + attr($p.presence // "unknown") + "\""
    + (if ($d.snooze_enabled == true) or ($d.dnd_enabled == true) then " dnd=\"true\"" else "" end)
    + (if $u.is_bot then " bot=\"true\"" else "" end)
    + (if $u.is_admin then " admin=\"true\"" else "" end)
    + (if $u.deleted then " deactivated=\"true\"" else "" end) + ">\n"
    + "  <real_name>" + ($u.real_name // "" | xml_escape) + "</real_name>\n"
    + (if ($u.profile.title // "") != "" then "  <title>" + ($u.profile.title | xml_escape) + "</title>\n" else "" end)
    + (if ($u.profile.email // "") != "" then "  <email>" + ($u.profile.email | xml_escape) + "</email>\n" else "" end)
    + (if ($u.tz_label // $u.tz // "") != "" then "  <timezone>" + ($u.tz_label // $u.tz | xml_escape) + "</timezone>\n" else "" end)
    + (if ($u.profile.status_text // "") != "" then "  <status>" + ($u.profile.status_text | xml_escape) + "</status>\n" else "" end)
    + (if ($channels | length) > 0
       then "  <channels count=\"" + (($channels | length) | tostring) + "\">\n"
            + ([ $channels[] | "    <channel>" + ((.name // .id) | xml_escape) + "</channel>\n" ] | add)
            + "  </channels>\n"
       else "" end)
    + "</user>"
  ' --argjson info "$info" --argjson presence "$presence" --argjson dnd "$dnd" --argjson channels "$channels"
}

slacker_whois "$@"
