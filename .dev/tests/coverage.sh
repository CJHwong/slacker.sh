#!/usr/bin/env bash
# coverage.sh — line coverage for the shipped bash, in pure bash.
#
# Runs the offline suite under `set -x` with a PS4 that stamps every executed
# command with its file and line, then reports covered/executable lines per file
# and enforces a floor so coverage can only ratchet up.
#
#   ./.dev/tests/coverage.sh                 report
#   SLACKER_COV_FLOOR=90 ./.dev/tests/coverage.sh   report and fail under 90%
#   SLACKER_COV_DETAIL=lib/http.sh ./.dev/tests/coverage.sh   list that file's misses
#
# No new dependency: PS4 with ${BASH_SOURCE}/${LINENO} behaves identically on
# bash 3.2 and 5.x. kcov/bashcov would work but would break the repo's
# bash + jq + curl invariant, and kcov cannot instrument bash 3.2 at all.
#
# Two things this does NOT measure, so don't read the number as "everything":
#   - lib/render.jq is jq, not bash. It is the best-tested part of the engine
#     (unit.sh is mostly render fixtures) but no bash tracer can see it.
#   - Platform-exclusive branches. slacker_mtime/slacker_fsize are
#     `stat -c … || stat -f …` one-liners, so the *line* is covered on both
#     macOS and Linux, but only one arm ever runs per OS. Line coverage is
#     honest here; branch coverage would need both CI legs unioned.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"

TRACE=$(mktemp "${TMPDIR:-/tmp}/slacker_cov.XXXXXX")
HITS=$(mktemp "${TMPDIR:-/tmp}/slacker_hits.XXXXXX")
# Child slacker.sh runs append here (see cli() in helpers.sh); kept separate
# from $TRACE because fd 9 writes to that at its own offset.
SLACKER_COV_TRACE=$(mktemp "${TMPDIR:-/tmp}/slacker_covc.XXXXXX")
export SLACKER_COV_TRACE

# Child shells get PS4 through BASH_ENV, not through the environment. Exported
# PS4 is NOT portable: bash 5.3 imports it, bash 5.2 ignores it and falls back to
# "+ ", which silently produced zero child coverage on Linux while macOS looked
# fine. Every non-interactive bash reads BASH_ENV, so this works on 3.2 too.
SLACKER_COV_PS4=$(mktemp "${TMPDIR:-/tmp}/slacker_ps4.XXXXXX")
export SLACKER_COV_PS4
# The single quotes are the point: PS4 must reach the child unexpanded so it
# expands per-command there.
# shellcheck disable=SC2016
printf 'PS4=%s\n' "'+COV:\${BASH_SOURCE}:\${LINENO}:'" > "$SLACKER_COV_PS4"
trap 'rm -f "$TRACE" "$HITS" "$HITS.exec" "$HITS.got" "$SLACKER_COV_TRACE" "$SLACKER_COV_PS4"' EXIT INT TERM

# Collect the trace on fd 9. Bash 4.1+ can point xtrace straight at it and keep
# stderr clean; 3.2 has no BASH_XTRACEFD, so stderr is redirected wholesale and
# the suite's own stderr assertions are skipped for the coverage pass (run.sh
# asserts them in the normal pass).
exec 9>"$TRACE"
if [ "${BASH_VERSINFO[0]}" -gt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then
  export BASH_XTRACEFD=9
else
  exec 2>&9
fi

# shellcheck source=helpers.sh
# shellcheck disable=SC1091
. "$DIR/helpers.sh"
# shellcheck source=unit.sh
# shellcheck disable=SC1091
. "$DIR/unit.sh"
# shellcheck source=actions.sh
# shellcheck disable=SC1091
. "$DIR/actions.sh"

export PS4='+COV:${BASH_SOURCE}:${LINENO}:'
set -x
unit_tests   >/dev/null 2>&9
action_tests >/dev/null 2>&9
set +x
exec 9>&-

# Merge the in-process trace with the child-process traces and normalize each
# absolute path down to its repo-relative name. Paths are normalized by shape
# rather than by stripping $ROOT, because the action tests execute a copy of
# slacker.sh from a throwaway directory whose lib/ and actions/ are symlinks —
# so those records carry the temp root, not the repo root. Anything that is not
# shipped code (the test files themselves) drops out here.
cat "$TRACE" "$SLACKER_COV_TRACE" 2>/dev/null \
  | grep -ao 'COV:[^:]*:[0-9]*:' \
  | sed -e 's/^COV://' -e 's/:$//' \
        -e 's|^.*/lib/|lib/|' \
        -e 's|^.*/actions/|actions/|' \
        -e 's|^.*/slacker\.sh:|slacker.sh:|' \
  | grep -E '^(slacker\.sh|lib/|actions/)' \
  | sort -u > "$HITS"

printf '%-28s %8s %8s %7s\n' FILE COVERED EXEC PCT
printf '%-28s %8s %8s %7s\n' '----' '-------' '----' '---'

total_hit=0 total_exec=0 report="" audit=""
for f in slacker.sh lib/http.sh lib/cache.sh lib/parse.sh actions/*.sh; do
  # Denominator = the static estimate UNION the lines bash actually traced.
  #
  # Static analysis alone cannot be exact here: for a multi-line simple command
  # bash reports the line where the command *ends*, not where it starts, so a
  # `$( … )` spanning four lines is traced against its closing line. Anything
  # observed is executable by proof, so unioning it in can only make the
  # denominator more correct — and it guarantees covered never exceeds total.
  awk -f "$DIR/execlines.awk" -v mode=list "$ROOT/$f" | sort -u > "$HITS.exec"
  grep "^$f:" "$HITS" | sed "s|^$f:||" | sort -u > "$HITS.got"
  leak=$(comm -13 "$HITS.exec" "$HITS.got" | tr '\n' ' ')
  [ -n "$leak" ] && audit="$audit  $f: only observed, not predicted: $leak
"
  exec_n=$(sort -u "$HITS.exec" "$HITS.got" | grep -c .)
  hit_n=$(grep -c .   "$HITS.got")
  total_hit=$((total_hit + hit_n)); total_exec=$((total_exec + exec_n))
  report="$report$(awk -v f="$f" -v h="$hit_n" -v d="$exec_n" \
    'BEGIN{printf "%-28s %8d %8d %6.1f%%\n", f, h, d, (d ? 100*h/d : 100)}')
"
done
printf '%s' "$report"

pct=$(awk -v h="$total_hit" -v d="$total_exec" 'BEGIN{printf "%.1f", (d ? 100*h/d : 100)}')
printf '%-28s %8s %8s %7s\n' '----' '-------' '----' '---'
printf '%-28s %8d %8d %6.1f%%\n' TOTAL "$total_hit" "$total_exec" "$pct"

# Lines the static filter did not predict but bash traced anyway. Expected and
# harmless (see the union above) — surfaced only on request, so a growing gap
# is visible if execlines.awk ever drifts badly.
if [ -n "${SLACKER_COV_AUDIT:-}" ] && [ -n "$audit" ]; then
  echo
  echo "execlines.awk gap (observed but not predicted; folded into the total):"
  printf '%s' "$audit"
fi

if [ -n "${SLACKER_COV_DETAIL:-}" ]; then
  detail_files="$SLACKER_COV_DETAIL"
  [ "$detail_files" = "all" ] && detail_files="slacker.sh lib/http.sh lib/cache.sh lib/parse.sh $(cd "$ROOT" && echo actions/*.sh)"
  for f in $detail_files; do
    awk -f "$DIR/execlines.awk" -v mode=list "$ROOT/$f" | sort -u > "$HITS.exec"
    grep "^$f:" "$HITS" | sed "s|^$f:||" | sort -u > "$HITS.got"
    miss=$(comm -23 "$HITS.exec" "$HITS.got")
    [ -n "$miss" ] || continue
    echo
    echo "uncovered lines in $f:"
    printf '%s\n' "$miss" | while read -r ln; do
      [ -n "$ln" ] || continue
      printf '  %s:%s: %s\n' "$f" "$ln" "$(sed -n "${ln}p" "$ROOT/$f")"
    done
  done
fi

floor="${SLACKER_COV_FLOOR:-0}"
echo
if awk -v p="$pct" -v f="$floor" 'BEGIN{exit !(p + 0.05 < f)}'; then
  echo "== coverage $pct% is below the floor of $floor% =="
  exit 1
fi
echo "== coverage $pct% (floor $floor%) =="
