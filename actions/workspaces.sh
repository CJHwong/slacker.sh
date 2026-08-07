# shellcheck shell=bash
# help: read | list configured workspaces and the active one
# actions/workspaces.sh — config introspection, no API calls.
# Lists every workspace whose token is defined (SLACKER_SH_TOKEN_<name>) plus
# the default token's "default" entry, and names the active one: the workspace
# selected by SLACKER_SH_WORKSPACE, or "default" when no selector is set.
# Works without a token (like help) and even when the selector is broken, so
# it is the debug tool for workspace-selection errors.
# Sourced by slacker.sh with the action args as "$@".

slacker_workspaces() {
  [ $# -eq 0 ] || { echo "workspaces: takes no arguments" >&2; return 1; }

  local names=() v names_json active="" broken=""
  # The default token (SLACKER_SH_TOKEN) is a first-class workspace. The
  # dispatcher snapshots it as SLACKER_SH_DEFAULT_TOKEN before a selection can
  # overwrite SLACKER_SH_TOKEN, so this stays correct when a workspace is active.
  [ -n "${SLACKER_SH_DEFAULT_TOKEN:-}" ] && names+=("default")
  # compgen lists only SLACKER_SH_TOKEN_<name> vars (the plain SLACKER_SH_TOKEN
  # does not match the trailing underscore). No output -> the loop never runs.
  for v in $(compgen -A variable 'SLACKER_SH_TOKEN_'); do
    names+=("${v#SLACKER_SH_TOKEN_}")
  done
  # Branch on empty: expanding an empty array under `set -u` is fatal on
  # bash < 4.4 (the documented trap), so the empty case never expands it.
  if [ ${#names[@]} -eq 0 ]; then
    names_json='[]'
  else
    names_json=$(printf '%s\n' "${names[@]}" | jq -R . | jq -cs .)
  fi

  # active always names a real workspace (or is empty); a selector that names
  # no configured token is reported as `broken`, never as active, so an agent
  # can't mistake a misconfiguration for a valid workspace.
  if [ -n "${SLACKER_SH_WORKSPACE:-}" ]; then
    tok="SLACKER_SH_TOKEN_${SLACKER_SH_WORKSPACE}"
    if [ -n "${!tok+x}" ]; then
      active="$SLACKER_SH_WORKSPACE"
    else
      broken="$SLACKER_SH_WORKSPACE"
    fi
  elif [ -n "${SLACKER_SH_DEFAULT_TOKEN:-}" ]; then
    active="default"
  fi

  jq -rn -L "$SLACKER_ROOT/lib" 'include "render";
    "<workspaces active=\"" + attr($active) + "\""
    + (if $broken != "" then " broken=\"" + attr($broken) + "\"" else "" end)
    + ">\n"
    + ([ $names[] | "  <workspace name=\"" + attr(.) + "\"/>\n" ] | add // "")
    + "</workspaces>"
  ' --argjson names "$names_json" --arg active "$active" --arg broken "$broken"
}

slacker_workspaces "$@"
