# shellcheck shell=bash
# help: read | list user groups, or expand one to members
# actions/usergroup.sh — list user groups, or expand one to its members.
#   slacker.sh usergroup                 -> all groups
#   slacker.sh usergroup <@handle|name|S-id> -> that group's members (resolved)
# Composes usergroups.list + usergroups.users.list. Sourced with args as "$@".

slacker_usergroup() {
  local input=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) echo "usergroup: unknown flag $1" >&2; return 1 ;;
      *)  input="$1"; shift ;;
    esac
  done

  local groups
  groups=$(slacker_api usergroups.list --data-urlencode "include_count=true") || return 1

  if [ -z "$input" ]; then
    jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
      ($g.usergroups) as $gs |
      "<usergroups count=\"" + (($gs | length) | tostring) + "\">\n"
      + (([ $gs[] | "  <usergroup id=\"" + attr(.id) + "\" handle=\"" + attr(.handle)
            + "\" name=\"" + attr(.name) + "\" count=\"" + ((.user_count // 0) | tostring) + "\"/>\n" ] | add) // "")
      + "</usergroups>"
    ' --argjson g "$groups"
    return 0
  fi

  local q="${input#@}" sid meta members users_file umap
  case "$q" in
    S[A-Z0-9]*) sid="$q" ;;
    *) sid=$(printf '%s' "$groups" | jq -r --arg q "$q" '
         ($q | ascii_downcase) as $ql |
         [ .usergroups[] | select((.handle | ascii_downcase) == $ql or (.name | ascii_downcase) == $ql) ][0].id // ""') ;;
  esac
  if [ -z "$sid" ]; then echo "usergroup: '$input' not found" >&2; return 1; fi

  meta=$(printf '%s' "$groups" | jq -c --arg id "$sid" '(.usergroups[] | select(.id == $id)) // {id:$id,handle:"",name:""}')
  members=$(slacker_api usergroups.users.list --data-urlencode "usergroup=$sid" | jq -c '.users // []') || members='[]'

  users_file=$(slacker_users_cache) || return 1
  umap=$(mktemp "${TMPDIR:-/tmp}/slacker_umap.XXXXXX")
  printf '%s' "$members" | jq '[ .[] | {user: .} ]' | slacker_augment_users "$users_file" > "$umap"

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    ($users[0]) as $u |
    "<usergroup id=\"" + attr($meta.id) + "\" handle=\"" + attr($meta.handle)
    + "\" name=\"" + attr($meta.name) + "\" count=\"" + (($members | length) | tostring) + "\">\n"
    + (([ $members[] | "  <member>" + ((user_name($u; .) // .) | xml_escape) + "</member>\n" ] | add) // "")
    + "</usergroup>"
  ' --slurpfile users "$umap" --argjson meta "$meta" --argjson members "$members"
  rm -f "$umap"
}

slacker_usergroup "$@"
