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

action="${1:-}"
if [ -z "$action" ]; then
  echo "usage: slacker.sh <action> [args]" >&2
  printf 'actions:' >&2
  for f in "$SLACKER_ROOT"/actions/*.sh; do printf ' %s' "$(basename "$f" .sh)" >&2; done
  echo >&2
  exit 1
fi
shift

script="$SLACKER_ROOT/actions/$action.sh"
if [ ! -f "$script" ]; then
  echo "slacker.sh: unknown action '$action'" >&2
  exit 1
fi

slacker_require_token
slacker_check_update || true
# shellcheck source=/dev/null
. "$script"
