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

# xmllint is documented as optional and test-only, so its absence must degrade to
# "skip the well-formedness check", not fail every XML assertion. It is announced
# once rather than silently downgrading the suite's rigor.
if command -v xmllint >/dev/null 2>&1; then
  SLACKER_HAVE_XMLLINT=1
else
  SLACKER_HAVE_XMLLINT=
  echo "helpers.sh: xmllint not found — XML well-formedness checks are SKIPPED" >&2
fi
xml_ok(){
  [ -n "$SLACKER_HAVE_XMLLINT" ] || return 0
  printf '%s' "$1" | xmllint --noout - >/dev/null 2>&1
}
# fx EXPR : evaluate a render.jq expression and print its output.
fx(){ jq -rn -L "$ROOT/lib" "include \"render\"; $1" 2>&1; }
# wantfx NAME EXPR SUBSTR : evaluate EXPR through fx, then assert like `want`.
# Always call fx through this rather than inline as `want "$(fx "…\"x\"…")"`:
# bash 3.2 mis-parses a backslash-escaped quote inside a $(…) that itself sits
# inside a double-quoted argument, word-splitting the argument and shredding the
# jq program. Assigning inside the helper keeps the substitution out of argv.
wantfx(){ local n="$1" expr="$2" sub="$3" out; out=$(fx "$expr"); want "$n" "$out" "$sub"; }
# want NAME OUTPUT SUBSTR : OUTPUT is well-formed XML AND contains SUBSTR.
want(){ local n="$1" out="$2" sub="$3"
  if ! xml_ok "<r>$out</r>"; then no "$n" "invalid xml"; return; fi
  printf '%s' "$out" | grep -qF "$sub" && ok "$n" || no "$n" "missing: $sub"; }
# grace NAME CMD... : pass when the result is well-formed XML — a success payload
# OR a structured <error> (e.g. a scope-gated action on a token lacking that
# scope). Every result is parseable XML now, so this just checks well-formedness.
grace(){ local n="$1"; shift; local out
  out=$("$@" 2>/dev/null)
  if [ -n "$out" ] && xml_ok "<r>$out</r>"; then ok "$n"
  else no "$n" "no valid XML: $(printf '%s' "$out" | head -1)"; fi; }
# errs NAME SUBSTR CMD... : the command fails AND its stderr contains SUBSTR.
# Used for usage/help/unknown-flag text, which stays on stderr (not a result).
errs(){ local n="$1" sub="$2"; shift 2; local tmpf err rc
  tmpf=$(mktemp); "$@" >/dev/null 2>"$tmpf"; rc=$?; err=$(cat "$tmpf"); rm -f "$tmpf"
  if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qF "$sub"; then ok "$n"
  else no "$n" "rc=$rc, stderr=$(printf '%s' "$err" | head -1)"; fi; }
# oerr NAME CODE CMD... : the command fails AND emits a well-formed <error
# code="CODE"> as its result on stdout (via fd 3 in the binary, or the fd-3-closed
# fallback when a lib function is called directly in-process).
oerr(){ local n="$1" code="$2"; shift 2; local out rc
  out=$("$@" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] && xml_ok "<r>$out</r>" && printf '%s' "$out" | grep -qF "code=\"$code\""; then ok "$n"
  else no "$n" "rc=$rc, out=$(printf '%s' "$out" | head -1)"; fi; }

# --- offline binary harness --------------------------------------------------
# Drives the real slacker.sh end to end with stub/curl first on $PATH, so every
# action runs its true code path (dispatcher, caches, pagination, rendering)
# without a network or a token.
#
# The binary is invoked from a throwaway root: a copy of slacker.sh beside
# symlinks to lib/ and actions/. slacker.sh derives SLACKER_ROOT from its own
# path and sources "$SLACKER_ROOT/.env" if present, so running the repo copy
# would silently pull in a developer's real token and settings and make local
# results diverge from CI. The copy has no .env, so the environment set here is
# the whole environment.
STUB_DIR="$ROOT/.dev/tests/stub"
SLACKER_STUB_DIR="$ROOT/.dev/tests/fixtures"; export SLACKER_STUB_DIR
STUB_ROOT="" STUB_STATE="" STUB_CACHE=""

# stub_reset : fresh fixture counters, call log, and users/channels cache.
# Call before each action test so call ordering and pagination are deterministic.
stub_reset(){
  if [ -z "$STUB_ROOT" ]; then
    STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/slacker_root.XXXXXX")
    cp "$ROOT/slacker.sh" "$STUB_ROOT/slacker.sh"
    ln -s "$ROOT/lib" "$STUB_ROOT/lib"
    ln -s "$ROOT/actions" "$STUB_ROOT/actions"
  fi
  [ -n "$STUB_STATE" ] && rm -rf "$STUB_STATE"
  STUB_STATE=$(mktemp -d "${TMPDIR:-/tmp}/slacker_stub.XXXXXX")
  STUB_CACHE="$STUB_STATE/cache"
  mkdir -p "$STUB_CACHE"
}

# stub_cleanup : drop the throwaway root and scratch state.
stub_cleanup(){
  [ -n "$STUB_STATE" ] && rm -rf "$STUB_STATE"
  [ -n "$STUB_ROOT" ] && rm -rf "$STUB_ROOT"
  STUB_ROOT="" STUB_STATE=""
  return 0
}

# cli ARGS... : run slacker.sh offline. Stdout is the one XML result.
#
# Under coverage (SLACKER_COV_TRACE set) the binary is launched with `bash -x`
# so the child's lines are traced too — it is a separate process, so it inherits
# the exported PS4 but not the parent's xtrace setting. Its trace arrives on the
# child's stderr (bash 3.2 has no BASH_XTRACEFD), so the two streams are split
# back apart here: PS4-stamped lines go to the trace file, everything else is
# re-emitted as real stderr so the suite's stderr assertions still hold.
cli(){ cli_at "$STUB_ROOT/slacker.sh" "$@"; }

# cli_at PATH ARGS... : same, but through an explicit slacker.sh path — used to
# exercise the symlink install shape.
cli_at(){
  local bin="$1"; shift
  if [ -z "${SLACKER_COV_TRACE:-}" ]; then
    _cli_env "$bin" "$@"
    return $?
  fi
  local errf rc
  errf=$(mktemp "${TMPDIR:-/tmp}/slacker_cli_err.XXXXXX")
  # Two things must be right for the child to be traced at all, and both were
  # wrong at first in ways that looked fine on macOS:
  #   - BASH_XTRACEFD must NOT reach the child. It names fd 9 in the *parent*; a
  #     child inheriting the name without a valid fd silently discards its whole
  #     trace (GNU bash 5.2).
  #   - PS4 must arrive via BASH_ENV, not the environment. bash 5.3 imports an
  #     exported PS4; bash 5.2 ignores it and uses "+ ", which yields no COV
  #     records at all.
  ( unset BASH_XTRACEFD
    BASH_ENV="$SLACKER_COV_PS4" _cli_env bash -x "$bin" "$@" ) 2>"$errf"
  rc=$?
  grep -a  '^+*COV:' "$errf" >> "$SLACKER_COV_TRACE" || true
  grep -av '^+*COV:' "$errf" >&2 || true
  rm -f "$errf"
  return $rc
}

# _cli_env CMD... : the offline environment every cli invocation runs under.
_cli_env(){
  PATH="$STUB_DIR:$PATH" \
  SLACKER_STUB_STATE="$STUB_STATE" \
  SLACKER_SH_TOKEN="${STUB_TOKEN-xoxp-test-token}" \
  SLACKER_CACHE_DIR="$STUB_CACHE" \
  SLACKER_CACHE_TTL="${STUB_TTL:-3600}" \
  SLACKER_SH_NO_UPDATE_CHECK=1 \
  SLACKER_SH_SIGNATURE="${STUB_SIG:-off}" \
  SLACKER_STUB_FAIL="${STUB_FAIL:-}" \
  SLACKER_STUB_VARIANT="${STUB_VARIANT:-}" \
  "$@"
}

# xml NAME SUBSTR ARGS... : `cli ARGS...` succeeds, emits well-formed XML, and
# that XML contains SUBSTR.
xml(){ local n="$1" sub="$2"; shift 2; local out rc
  out=$(cli "$@" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then no "$n" "exit $rc: $(printf '%s' "$out" | head -1)"; return; fi
  want "$n" "$out" "$sub"; }

# sent NAME SUBSTR : some request the stub recorded contains SUBSTR.
sent(){ local n="$1" sub="$2"
  if grep -qF -- "$sub" "$STUB_STATE/calls.log" 2>/dev/null; then ok "$n"
  else no "$n" "no recorded request contains: $sub"; fi; }

# unsent NAME SUBSTR : no request the stub recorded contains SUBSTR.
unsent(){ local n="$1" sub="$2"
  if grep -qF -- "$sub" "$STUB_STATE/calls.log" 2>/dev/null; then
    no "$n" "a request unexpectedly contains: $sub"
  else ok "$n"; fi; }

# summary : print the tally; succeed only when nothing failed. Call once, last.
summary(){ echo; echo "== $PASS passed, $FAIL failed =="; [ "$FAIL" -eq 0 ]; }
