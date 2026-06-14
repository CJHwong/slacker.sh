#!/usr/bin/env bash
# run.sh — entry point for the slacker.sh test suite. Runs the offline unit tests
# always, then the live integration tests unless skipped or no token is set. Each
# layer lives in its own file (helpers/unit/live); this just wires them together
# and prints one tally.
#   ./.dev/tests/run.sh                    everything (from repo root)
#   SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh   unit only (no token needed)
#   ./.dev/tests/unit.sh                      unit only, directly
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=unit.sh
. "$DIR/unit.sh"
# shellcheck source=live.sh
. "$DIR/live.sh"

unit_tests
if [ "${SLACKER_SKIP_LIVE:-}" = "1" ] || [ -z "${SLACKER_SH_TOKEN:-}" ]; then
  echo; echo "== live: SKIPPED =="
else
  live_tests
fi
summary
