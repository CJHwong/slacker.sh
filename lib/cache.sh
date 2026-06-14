# shellcheck shell=bash
# lib/cache.sh — the resolution engine.
# Dumps users.list + conversations.list to disk as id->name maps so every
# ID->name lookup is one disk read instead of an API call. TTL refresh.
# Sourced by slacker.sh. Depends on: lib/http.sh, jq, date, stat (macOS).

# Namespace the cache per token so switching workspaces can't resolve IDs
# against the wrong workspace's users/channels. The token hash stands in for
# the workspace without storing the token or making an extra API call.
SLACKER_TOKEN_KEY=$(printf '%s' "${SLACKER_SH_TOKEN:-anon}" | shasum 2>/dev/null | cut -c1-12)
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

# True (0) if file is missing or older than TTL.
slacker_cache_stale() {
  local file="$1"
  [ -f "$file" ] || return 0
  local age=$(( $(date +%s) - $(slacker_mtime "$file") ))
  [ "$age" -ge "$SLACKER_CACHE_TTL" ]
}

# Builds (if stale) and echoes the path to the users map.
# Each entry: { n: display name, r: real name, h: handle, d: deleted? }.
# n powers rendering; r/h power fuzzy lookup; d marks deactivated users.
slacker_users_cache() {
  local file="$SLACKER_CACHE_DIR/users.json"
  if slacker_cache_stale "$file"; then
    echo "slacker.sh: building users cache..." >&2
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
    echo "slacker.sh: resolving $n unknown user(s) via users.info..." >&2
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      info=$(slacker_api users.info --data-urlencode "user=$id" 2>/dev/null) || continue
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

# Builds (if stale) and echoes the path to the channels id->name map.
slacker_channels_cache() {
  local file="$SLACKER_CACHE_DIR/channels.json"
  if slacker_cache_stale "$file"; then
    echo "slacker.sh: building channels cache..." >&2
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
