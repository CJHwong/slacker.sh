# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# helpers.sh — shared harness for the slacker.sh test suite.
# Sourced by run.sh and the unit/live modules (never run on its own). Resolves
# the skill root, sources its libs, and provides the reporter + result tally.
# Sourcing twice is a no-op, so each module can require it independently.
# The `assert && ok || no` reporter pattern is intentional (ok/no never fail).
# shellcheck disable=SC2015
set -uo pipefail
[ -n "${SLACKER_TEST_HELPERS:-}" ] && return 0
SLACKER_TEST_HELPERS=1

# .dev/tests/ sits two levels under the repo root, which IS the skill.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export SLACKER_ROOT="$ROOT"
# shellcheck source=/dev/null
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
# shellcheck source=../../lib/http.sh
. "$ROOT/lib/http.sh"
# shellcheck source=../../lib/cache.sh
. "$ROOT/lib/cache.sh"
# shellcheck source=../../lib/parse.sh
. "$ROOT/lib/parse.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s :: %s\n' "$1" "$2"; }

# eq NAME EXPECTED ACTUAL : assert two strings are equal.
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want [$2] got [$3]"; fi; }
# has NAME SUBSTR STRING : assert STRING contains SUBSTR.
has(){ case "$3" in *"$2"*) ok "$1" ;; *) no "$1" "missing [$2] in: $3" ;; esac; }

xml_ok(){ printf '%s' "$1" | xmllint --noout - >/dev/null 2>&1; }
# fx EXPR : evaluate a render.jq expression and print its output.
fx(){ jq -rn -L "$ROOT/lib" "include \"render\"; $1" 2>&1; }
# want NAME OUTPUT SUBSTR : OUTPUT is well-formed XML AND contains SUBSTR.
want(){ local n="$1" out="$2" sub="$3"
  if ! xml_ok "<r>$out</r>"; then no "$n" "invalid xml"; return; fi
  printf '%s' "$out" | grep -qF "$sub" && ok "$n" || no "$n" "missing: $sub"; }
# grace NAME CMD... : pass on valid-XML output OR a clean missing-scope error
# (so scope-gated actions don't fail the suite on a token lacking that scope).
grace(){ local n="$1"; shift; local tmpf out err
  tmpf=$(mktemp); out=$("$@" 2>"$tmpf"); err=$(cat "$tmpf"); rm -f "$tmpf"
  if [ -n "$out" ] && xml_ok "<r>$out</r>"; then ok "$n"
  elif printf '%s' "$err" | grep -q 'missing scope'; then ok "$n (scope-gated)"
  else no "$n" "neither valid output nor scope error: $(printf '%s' "$err" | head -1)"; fi; }
# errs NAME SUBSTR CMD... : the command fails AND its stderr contains SUBSTR.
errs(){ local n="$1" sub="$2"; shift 2; local tmpf err rc
  tmpf=$(mktemp); "$@" >/dev/null 2>"$tmpf"; rc=$?; err=$(cat "$tmpf"); rm -f "$tmpf"
  if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qF "$sub"; then ok "$n"
  else no "$n" "rc=$rc, stderr=$(printf '%s' "$err" | head -1)"; fi; }

# summary : print the tally; succeed only when nothing failed. Call once, last.
summary(){ echo; echo "== $PASS passed, $FAIL failed =="; [ "$FAIL" -eq 0 ]; }
