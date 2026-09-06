#!/usr/bin/env bash
# install.sh — install the slacker-sh skill into an agent harness's skills path.
# Copies the skill payload (leaving .dev/ behind), so the install is self-contained.
#   ./install.sh                    # interactive; detects existing installs first
#   ./install.sh --target agents    # one of agents, claude, codex
#   ./install.sh --update           # refresh the first detected install, no prompt
#   ./install.sh [dest]             # explicit destination (back-compat)
#   curl -fsSL https://raw.githubusercontent.com/CJHwong/slacker.sh/main/install.sh | bash
# A piped run has no terminal, so it is non-interactive: a fresh install
# proceeds, an existing one aborts until you pass --update or a destination.
set -euo pipefail

payload="SKILL.md slacker.sh lib actions reference"
tarball="${SLACKER_SH_TARBALL:-https://github.com/CJHwong/slacker.sh/archive/refs/heads/main.tar.gz}"

usage() {
  echo "usage: install.sh [--target agents|claude|codex|<path>] [--update] [dest]"
  echo "  --target  install into a harness's skills dir (agents = ~/.agents/skills,"
  echo "            the shared hub; claude = ~/.claude/skills; codex = ~/.codex/skills)"
  echo "  --update  refresh the first detected install without prompting"
  echo "  dest      explicit destination directory (wins over --target)"
}

dest="" target="" do_update=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --target)  [ $# -ge 2 ] || { echo "install.sh: --target needs a value" >&2; exit 1; }
               target="$2"; shift ;;
    --update)  do_update=1 ;;
    -*)        echo "install.sh: unknown flag $1" >&2; usage >&2; exit 1 ;;
    *)         [ -z "$dest" ] || { echo "install.sh: pass one destination" >&2; exit 1; }
               dest="$1" ;;
  esac
  shift
done

# Harness skills dirs. $HOME-scoped so tests can sandbox the whole flow.
agents_dest="$HOME/.agents/skills/slacker-sh"
claude_dest="$HOME/.claude/skills/slacker-sh"
codex_dest="$HOME/.codex/skills/slacker-sh"

# Map a --target name to its destination; a path passes through untouched.
resolve_target() {
  case "$1" in
    agents) printf '%s' "$agents_dest" ;;
    claude) printf '%s' "$claude_dest" ;;
    codex)  printf '%s' "$codex_dest" ;;
    */)     printf '%s' "${1%/}" ;;
    /*)     printf '%s' "$1" ;;
    *)      return 1 ;;
  esac
}

# Existing installs across the known locations, physical-path deduped, first
# hit first (CLAUDE_CONFIG_DIR is the most specific override).
detect_installs() {
  local d real
  for d in "${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/skills/slacker-sh}" \
           "$agents_dest" "$claude_dest" "$codex_dest"; do
    [ -n "$d" ] || continue
    [ -e "$d/slacker.sh" ] || continue
    real="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    printf '%s\n' "$real"
  done | awk '!seen[$0]++'
}

# An interactive run has a terminal on stdin; a piped one does not.
ask() { # $1 question; answer in $ans (empty when non-interactive)
  ans=""
  [ -t 0 ] || return 1
  printf '%s' "$1" >&2
  IFS= read -r ans || return 1
}

src="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || src=""

# No payload beside this script (piped via curl | bash)? Fetch a tarball instead
# (curl + tar, no git).
have_local=1
for item in $payload; do
  if [ -z "$src" ] || [ ! -e "$src/$item" ]; then have_local=0; break; fi
done
if [ "$have_local" -eq 0 ]; then
  command -v tar >/dev/null 2>&1 || { echo "install.sh: need 'tar' to fetch the skill (or run me from a clone)" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; mkdir -p "$tmp/repo"
  echo "fetching $tarball …"
  curl -fsSL "$tarball" | tar -xzf - -C "$tmp/repo" --strip-components=1 \
    || { echo "install.sh: download/unpack failed: $tarball" >&2; exit 1; }
  src="$tmp/repo"
fi

# Destination: an explicit dest wins, then --target, then detection + ask.
if [ -n "$dest" ] && [ -n "$target" ]; then
  echo "install.sh: pass a dest or --target, not both" >&2; exit 1
fi
if [ -z "$dest" ] && [ -n "$target" ]; then
  dest="$(resolve_target "$target")" || { echo "install.sh: unknown target '$target' (agents, claude, codex, or a path)" >&2; exit 1; }
fi

found="$(detect_installs)"
if [ -z "$dest" ]; then
  if [ -n "$found" ]; then
    first="$(printf '%s\n' "$found" | head -1)"
    if [ "$do_update" -eq 1 ]; then
      dest="$first"
    elif [ -t 0 ]; then
      echo "existing install(s):"
      printf '%s\n' "$found" | sed 's/^/  /'
      printf '  1) update %s\n  2) install somewhere else\n  3) cancel\n' "$first" >&2
      ask "choice [1]: " || { echo "cancelled." >&2; exit 0; }
      case "${ans:-1}" in
        1|"") dest="$first" ;;
        2)    printf 'target (agents, claude, codex, or a path): ' >&2
              ask "" || true
              [ -n "$ans" ] || { echo "install.sh: no target given" >&2; exit 1; }
              dest="$(resolve_target "$ans")" || { echo "install.sh: unknown target '$ans'" >&2; exit 1; } ;;
        *)    echo "cancelled." >&2; exit 0 ;;
      esac
    else
      echo "install.sh: found an existing install at $first" >&2
      echo "  re-run with --update to refresh it, or pass a destination" >&2
      exit 1
    fi
  else
    dest="$claude_dest"
  fi
fi

mkdir -p "$dest"
for item in $payload; do
  [ -e "$src/$item" ] || { echo "install.sh: $item missing from $src" >&2; exit 1; }
  rm -rf "${dest:?}/$item"   # refresh cleanly so deleted files don't linger
  cp -R "$src/$item" "$dest/$item"
done

echo "installed slacker-sh -> $dest"
if [ ! -f "$dest/.env" ] && [ -z "${SLACKER_SH_TOKEN:-}" ]; then
  echo "next: add your Slack user token —"
  echo "  echo 'SLACKER_SH_TOKEN=xoxp-…' > \"$dest/.env\"   (see $dest/reference/setup.md)"
fi