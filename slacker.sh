#!/usr/bin/env bash
# slacker.sh — agent-friendly Slack actions.
# Each action composes several Slack Web API methods into one fully-resolved
# XML payload. Usage: slacker.sh <action> [args]
set -euo pipefail

# Resolve through symlinks so a `ln -s …/slacker.sh /usr/local/bin/slacker.sh`
# install still finds lib/ and actions/ in the real repo (BASH_SOURCE would
# otherwise point at the symlink's dir). readlink (no -f) keeps this portable.
src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SLACKER_ROOT="$(cd -P "$(dirname "$src")" && pwd)"
export SLACKER_ROOT

# Required tools.
for _dep in jq curl; do
  command -v "$_dep" >/dev/null 2>&1 || { echo "slacker.sh: missing required dependency: $_dep" >&2; exit 1; }
done

# Run-scoped temp dir: every action's mktemp lands here (via TMPDIR) and is
# removed on any exit — normal, error, or interrupt — so nothing leaks.
SLACKER_RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/slacker_run.XXXXXX")
export TMPDIR="$SLACKER_RUN_TMP"
trap 'rm -rf "$SLACKER_RUN_TMP"' EXIT INT TERM

# fd 3 is a dup of the real stdout. slacker_error writes structured <error> XML
# there so it escapes any internal command-substitution capture and reaches the
# caller as the command's single result (see lib/http.sh). Stdout still carries
# exactly one XML document per run — the payload, or an <error>.
exec 3>&1

# Load the token from .env at runtime (never printed).
if [ -f "$SLACKER_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SLACKER_ROOT/.env"
  set +a
fi

# shellcheck source=lib/http.sh
. "$SLACKER_ROOT/lib/http.sh"
# shellcheck source=lib/cache.sh
. "$SLACKER_ROOT/lib/cache.sh"
# shellcheck source=lib/parse.sh
. "$SLACKER_ROOT/lib/parse.sh"

# List the commands of one group ($1=read|write), reading each action's
# "# help: <group> | <description>" header. $2 is the section title.
slacker__list_commands() {
  echo "$2:"
  local f line group desc
  for f in "$SLACKER_ROOT"/actions/*.sh; do
    line=$(sed -n 's/^# help: *//p' "$f" | head -1)
    [ -n "$line" ] || continue
    group=${line%%|*}; group=${group%% *}
    desc=${line#*|}; desc=${desc# }
    [ "$group" = "$1" ] || continue
    printf '  %-13s %s\n' "$(basename "$f" .sh)" "$desc"
  done
}

slacker_print_help() {
  cat <<'EOF'
slacker.sh — agent-friendly Slack CLI

Each command composes several Slack Web API calls into one fully-resolved XML
payload: ids become names, mentions and links decoded, threads and reactions
folded in, timestamps humanized.

Usage:
  slacker.sh <command> [args]
  slacker.sh <command> -h     show a command's flags

EOF
  slacker__list_commands read  "Read commands"
  echo
  slacker__list_commands write "Write commands (visible to others)"
  cat <<'EOF'

Environment:
  SLACKER_SH_TOKEN            Slack user token (xoxp-...), required
  SLACKER_SH_SIGNATURE        message footer (default on); set empty/0/off to
                              disable, or a string to override the footer text
  SLACKER_CACHE_TTL           users/channels cache TTL in seconds (default 3600)
  SLACKER_CONCURRENCY         parallel thread fetches for --threads (default 8)
  SLACKER_SH_NO_UPDATE_CHECK  set 1 to silence the update notice
  SLACKER_SH                  path to slacker.sh, if not on PATH

Docs: https://github.com/CJHwong/slacker.sh
EOF
}

action="${1:-}"
case "$action" in
  help|-h|--help) slacker_print_help; exit 0 ;;
  "")             slacker_print_help >&2; exit 1 ;;
esac
shift

script="$SLACKER_ROOT/actions/$action.sh"
if [ ! -f "$script" ]; then
  echo "slacker.sh: unknown command '$action'" >&2
  echo "run 'slacker.sh help' for the command list" >&2
  exit 1
fi

# The command name for the <error command="..."> attribute (see slacker_error).
export SLACKER_SH_CMD="$action"

# `<command> -h|--help` -> show that command's usage. Clearing the args makes the
# action fall through to its own usage line. This stays token-free because the
# token is only required at the first API call (see slacker_api), so flags are
# discoverable before setup.
case "${1:-}" in -h|--help) set -- ;; esac

slacker_check_update || true
# shellcheck source=/dev/null
. "$script"
