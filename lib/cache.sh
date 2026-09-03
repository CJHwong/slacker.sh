# shellcheck shell=bash
# lib/cache.sh — the resolution engine.
# Dumps users.list + conversations.list to disk as id->name maps so every
# ID->name lookup is one disk read instead of an API call. TTL refresh.
# Sourced by slacker.sh. Depends on: lib/http.sh, jq, date, stat (macOS).

# Namespace the cache per token so switching workspaces can't resolve IDs
# against the wrong workspace's users/channels. The token hash stands in for
# the workspace without storing the token or making an extra API call.
#
# Digest tools are tried in order and NONE of them is required. `shasum` is a
# perl script: it ships on macOS and most Debian images but not on Alpine or
# other slim containers. This runs at source time under the dispatcher's
# `set -euo pipefail`, so when it was a bare `| shasum |` pipeline a missing
# shasum returned 127 and killed slacker.sh before it produced any output at
# all — empty stdout, empty stderr, no <error> for the caller to parse. Cache
# namespacing is a convenience; it must never be able to take the command down.
#
# shasum-first keeps the key byte-identical for existing macOS users, so their
# cache directory does not move.
slacker__token_key() {
  local token="${SLACKER_SH_TOKEN:-anon}" digest=""
  digest=$(printf '%s' "$token" | shasum  2>/dev/null) || digest=""
  [ -n "$digest" ] || digest=$(printf '%s' "$token" | sha1sum 2>/dev/null) || digest=""
  [ -n "$digest" ] || digest=$(printf '%s' "$token" | cksum   2>/dev/null) || digest=""
  [ -n "$digest" ] || { printf 'nodigest'; return 0; }
  printf '%s' "$digest" | tr -cd '0-9a-zA-Z' | cut -c1-12
}
SLACKER_TOKEN_KEY=$(slacker__token_key)
SLACKER_CACHE_DIR="${SLACKER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/slacker_sh/${SLACKER_TOKEN_KEY:-anon}}"
SLACKER_CACHE_TTL="${SLACKER_CACHE_TTL:-3600}" # seconds

# Notify-only update check. At most once a day (throttled by a marker file's
# mtime) and only when slacker.sh is installed as a git clone with an upstream:
# fetch, and if HEAD is behind upstream, print one stderr line naming the pull
# command. Never mutates the repo and never runs remote code — it's a courtesy,
# so every failure path (no git, no upstream, offline) is non-fatal. The marker
# is token-independent (parent of the per-token cache dir) and is stamped before
# the fetch so a slow/offline check can't turn into a per-call retry storm.
# Disable entirely with SLACKER_SH_NO_UPDATE_CHECK=1.
slacker_check_update() {
  [ "${SLACKER_SH_NO_UPDATE_CHECK:-0}" = "1" ] && return 0
  command -v git >/dev/null 2>&1 || return 0
  local base marker age
  base=$(dirname "$SLACKER_CACHE_DIR")
  marker="$base/.update_check"
  if [ -f "$marker" ]; then
    age=$(( $(date +%s) - $(slacker_mtime "$marker") ))
    [ "$age" -lt 86400 ] && return 0
  fi
  mkdir -p "$base" 2>/dev/null || return 0
  : > "$marker" 2>/dev/null || return 0
  git -C "$SLACKER_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local upstream behind
  upstream=$(git -C "$SLACKER_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 0
  [ -n "$upstream" ] || return 0
  git -C "$SLACKER_ROOT" fetch -q 2>/dev/null || return 0
  behind=$(git -C "$SLACKER_ROOT" rev-list --count 'HEAD..@{u}' 2>/dev/null) || return 0
  if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
    echo "slacker.sh: update available ($behind commit(s) behind $upstream) — run 'git -C $SLACKER_ROOT pull --ff-only'" >&2
  fi
}

# True (0) if file is missing or older than TTL. $2 overrides the configured TTL.
slacker_cache_stale() {
  local file="$1" ttl="${2:-$SLACKER_CACHE_TTL}"
  [ -f "$file" ] || return 0
  local age=$(( $(date +%s) - $(slacker_mtime "$file") ))
  [ "$age" -ge "$ttl" ]
}

# Builds (if stale) and echoes the path to the users map.
# Each entry: { n: display name, r: real name, h: handle, d: deleted? }.
# n powers rendering; r/h power fuzzy lookup; d marks deactivated users.
slacker_users_cache() {
  local file="$SLACKER_CACHE_DIR/users.json"
  if slacker_cache_stale "$file"; then
    if [ -n "${SLACKER_SH_VERBOSE:-}" ]; then echo "slacker.sh: building users cache..." >&2; fi
    mkdir -p "$SLACKER_CACHE_DIR"
    # Abort if the fetch failed (e.g. no token) instead of leaving an empty file
    # that later jq reads would choke on with a misleading error.
    if slacker_fetch_paginated users.list members \
      | jq 'map({ (.id): {
              n: ((.profile.display_name | select(. != "")) // .real_name // .name // .id),
              r: (.real_name // ""),
              h: (.name // ""),
              d: (.deleted // false)
            } }) | add' \
      > "$file.tmp" && [ -s "$file.tmp" ]; then
      mv "$file.tmp" "$file"
    else
      rm -f "$file.tmp"; return 1
    fi
  fi
  printf '%s' "$file"
}

# On-demand resolution for ids absent from users.list (Slack Connect / external
# users). Reads JSON to scan from stdin, looks up any unknown user ids via
# users.info, persists them to users_extra.json, and prints the merged map
# (base + extra) to stdout. $1 = base users.json path.
slacker_augment_users() {
  local base="$1"
  local extra="$SLACKER_CACHE_DIR/users_extra.json"
  [ -f "$extra" ] || printf '{}' > "$extra"
  local scan ids_json misses id info obj n
  scan=$(cat)
  ids_json=$(printf '%s' "$scan" | jq -c '
    ([ .. | objects | (.user?, (.reactions[]?.users[]?), (.attachments[]?.author_id?)) ]
     + [ .. | strings | scan("<@([UW][A-Z0-9]+)") | (if type == "array" then .[0] else . end) ])
    | flatten | map(select(type == "string" and test("^[UW][A-Z0-9]+$"))) | unique')
  misses=$(jq -rn --argjson ids "$ids_json" --slurpfile base "$base" --slurpfile extra "$extra" '
    (($base[0] // {}) + ($extra[0] // {})) as $known | $ids[] | select(($known[.] // null) == null)')
  if [ -n "$misses" ]; then
    n=$(printf '%s\n' "$misses" | grep -c .)
    if [ -n "${SLACKER_SH_VERBOSE:-}" ]; then echo "slacker.sh: resolving $n unknown user(s) via users.info..." >&2; fi
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # Best-effort: a miss here just leaves the id unresolved. Suppress fd 3 so a
      # failure can't leak an <error> onto the caller's payload.
      info=$(slacker_api users.info --data-urlencode "user=$id" 2>/dev/null 3>/dev/null) || continue
      obj=$(printf '%s' "$info" | jq -c '.user | { (.id): {
              n: ((.profile.display_name | select(. != "")) // .real_name // .name // .id),
              r: (.real_name // ""), h: (.name // ""), d: (.deleted // false), ext: true } }') || continue
      [ -n "$obj" ] && jq -cn --slurpfile e "$extra" --argjson o "$obj" '($e[0] // {}) * $o' > "$extra.tmp" && mv "$extra.tmp" "$extra"
    done <<EOF
$misses
EOF
  fi
  jq -s '(.[0] // {}) * (.[1] // {})' "$base" "$extra"
}

# Rebuild the channels / users map ignoring TTL, at most once a minute.
#
# Exit codes:
#   0  the map was rebuilt, so the caller can retry its lookup
#   1  the one-minute floor blocked it, so no rebuild was attempted
#   2  the rebuild ran and failed
#
# One code per outcome because the caller reports a different <next> for each.
# A single "it failed" told the operator the directory had been rebuilt in the
# two states where it had not, which sent them hunting for a Slack Connect user
# who was in the workspace all along.
#
# A name we cannot resolve is the one moment the directory is worth distrusting,
# and it is the only signal we get: with SLACKER_CACHE_TTL set high the map never
# expires on its own, and a workspace that has grown since the snapshot returns
# not-found for a channel or a person that plainly exists.
#
# It is the whole list or nothing. Slack has no resolve-by-name endpoint, and
# conversations.info / users.info need an id, so a name miss cannot be patched
# the way slacker_augment_channels and slacker_augment_users patch an id miss.
#
# The one-minute floor is the guard against a typo re-listing the workspace on
# every call. It uses the cache file's own mtime rather than a shell flag because
# callers resolve inside $(...), and a flag set in that subshell would not
# survive back to the parent.
slacker_channels_cache_refresh() {
  local file="$SLACKER_CACHE_DIR/channels.json"
  slacker_cache_stale "$file" 60 || return 1
  SLACKER_CACHE_TTL=0 slacker_channels_cache >/dev/null 3>/dev/null || return 2
}

slacker_users_cache_refresh() {
  local file="$SLACKER_CACHE_DIR/users.json"
  slacker_cache_stale "$file" 60 || return 1
  SLACKER_CACHE_TTL=0 slacker_users_cache >/dev/null 3>/dev/null || return 2
}

# Builds (if stale) and echoes the path to the channels id->name map.
slacker_channels_cache() {
  local file="$SLACKER_CACHE_DIR/channels.json"
  if slacker_cache_stale "$file"; then
    if [ -n "${SLACKER_SH_VERBOSE:-}" ]; then echo "slacker.sh: building channels cache..." >&2; fi
    mkdir -p "$SLACKER_CACHE_DIR"
    if slacker_fetch_paginated conversations.list channels \
      --data-urlencode "types=public_channel,private_channel,mpim,im" \
      --data-urlencode "exclude_archived=false" \
      | jq 'map({ (.id): (.name // .user // .id) }) | add' \
      > "$file.tmp" && [ -s "$file.tmp" ]; then
      mv "$file.tmp" "$file"
    else
      rm -f "$file.tmp"; return 1
    fi
  fi
  printf '%s' "$file"
}

# On-demand resolution for channel ids absent from conversations.list (a channel
# created since the snapshot, or one this token cannot list). Reads JSON to scan
# from stdin, looks up any unknown channel ids via conversations.info, persists
# them to channels_extra.json, and prints the merged map (base + extra) to
# stdout. $1 = base channels.json path.
#
# An id miss is repairable one call at a time, unlike the name miss
# the refresh functions handle: conversations.info takes an id. So an unknown
# id rendered in a payload costs one API call, not a whole workspace re-list.
slacker_augment_channels() {
  local base="$1"
  local extra="$SLACKER_CACHE_DIR/channels_extra.json"
  [ -f "$extra" ] || printf '{}' > "$extra"
  local scan ids_json misses id info obj n
  scan=$(cat)
  ids_json=$(printf '%s' "$scan" | jq -c '
    ([ .. | objects | (.channel_id?, .channel?, (.channel? | objects | .id)) ]
     + [ .. | strings | scan("<#([CGD][A-Z0-9]+)") | (if type == "array" then .[0] else . end) ])
    | flatten | map(select(type == "string" and test("^[CGD][A-Z0-9]+$"))) | unique')
  misses=$(jq -rn --argjson ids "$ids_json" --slurpfile base "$base" --slurpfile extra "$extra" '
    (($base[0] // {}) + ($extra[0] // {})) as $known | $ids[] | select(($known[.] // null) == null)')
  if [ -n "$misses" ]; then
    n=$(printf '%s\n' "$misses" | grep -c .)
    if [ -n "${SLACKER_SH_VERBOSE:-}" ]; then echo "slacker.sh: resolving $n unknown channel(s) via conversations.info..." >&2; fi
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # Best-effort: a miss here just leaves the id unresolved. Suppress fd 3 so a
      # failure can't leak an <error> onto the caller's payload.
      info=$(slacker_api conversations.info --data-urlencode "channel=$id" 2>/dev/null 3>/dev/null) || continue
      # .user is the DM counterpart: same shape the base builder stores, so
      # slacker_dm_label still renders it as dm:Name.
      obj=$(printf '%s' "$info" | jq -c '.channel | { (.id): (.name // .user // .id) }') || continue
      [ -n "$obj" ] && jq -cn --slurpfile e "$extra" --argjson o "$obj" '($e[0] // {}) * $o' > "$extra.tmp" && mv "$extra.tmp" "$extra"
    done <<EOF
$misses
EOF
  fi
  jq -s '(.[0] // {}) * (.[1] // {})' "$base" "$extra"
}
