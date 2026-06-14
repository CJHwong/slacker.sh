#!/usr/bin/env bash
# install.sh — install the slacker-sh skill into the agent's global skills path.
# Copies the skill payload (leaving .dev/ behind), so the install is self-contained.
#   ./install.sh [dest]    # from a clone (default dest: ~/.claude/skills/slacker-sh)
#   curl -fsSL https://raw.githubusercontent.com/CJHwong/slacker.sh/main/install.sh | bash
set -euo pipefail

dest="${1:-$HOME/.claude/skills/slacker-sh}"
tarball="${SLACKER_SH_TARBALL:-https://github.com/CJHwong/slacker.sh/archive/refs/heads/main.tar.gz}"
payload="SKILL.md slacker.sh lib actions reference"

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
