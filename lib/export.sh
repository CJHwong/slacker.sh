# shellcheck shell=bash
# One validated API page for collectors. No cache refresh, enrichment, hidden
# pagination, concurrent workers, or retries: the caller owns pacing and resume.

slacker_sh_export_page() {
  # Dynamic scope lets the error explainer describe this no-retry operation.
  # shellcheck disable=SC2034
  local SLACKER_SH_EXPORT_MODE=1
  local kind="$1"; shift
  local channel="" root="" before="" after="" cursor="" limit=200
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --export) shift ;;
      --before|--after|--cursor|--limit|--channel|--ts)
        slacker_flag_value "$1" "$#" || return 1
        case "$1" in
          --before) before="$2" ;; --after) after="$2" ;;
          --cursor) cursor="$2" ;; --limit) limit="$2" ;;
          --channel) [ "$kind" = replies ] || break; channel="$2" ;;
          --ts) [ "$kind" = replies ] || break; root="$2" ;;
        esac
        shift 2 ;;
      -*) break ;;
      *)
        [ "$kind" = history ] && [ -z "$channel" ] || break
        channel="$1"; shift ;;
    esac
  done
  if [ "$#" -ne 0 ]; then
    slacker_error invalid_export_arguments recover \
      'Export accepts stable IDs, exact timestamp bounds, --cursor and --limit only.' \
      'Use read-channel ID --export --before TS; read-message --export --channel ID --ts ROOT --before TS; or list-conversations --export.'
    return 1
  fi
  slacker_count_value --limit "$limit" || return 1
  if ! jq -en -L "$SLACKER_ROOT/lib" 'include "render";
    export_request_valid($kind; $channel; $root; $before; $after; $cursor; $limit)
  ' --arg kind "$kind" --arg channel "$channel" --arg root "$root" \
    --arg before "$before" --arg after "$after" --arg cursor "$cursor" --arg limit "$limit" >/dev/null; then
    slacker_error invalid_export_bounds recover \
      'Export requires a stable conversation ID, an explicit exclusive cutoff and limit 1..200. Replies require the known root before the cutoff.' \
      'Keep channel, root, before, after and limit unchanged when resuming a cursor. Inventory accepts only --cursor and --limit.'
    return 1
  fi

  local method args body
  case "$kind" in
    inventory)
      method=conversations.list
      args=(--data-urlencode 'types=public_channel,private_channel,mpim,im' \
            --data-urlencode 'exclude_archived=false') ;;
    history|replies)
      method=conversations.history
      args=(--data-urlencode "channel=$channel" --data-urlencode "latest=$before" \
            --data-urlencode 'inclusive=false')
      if [ "$kind" = replies ]; then
        method=conversations.replies
        args+=(--data-urlencode "ts=$root")
      fi
      [ -z "$after" ] || args+=(--data-urlencode "oldest=$after") ;;
  esac
  args+=(--data-urlencode "limit=$limit")
  [ -z "$cursor" ] || args+=(--data-urlencode "cursor=$cursor")
  body=$(mktemp "${TMPDIR:-/tmp}/slacker_export.XXXXXX")
  # The final --retry overrides http.sh defaults. Each invocation has exactly
  # one API attempt; failures reach fd 3 before any success payload is emitted.
  slacker_api "$method" --retry 0 --connect-timeout 10 --max-time 55 "${args[@]}" > "$body" || return 1
  if ! jq -es -L "$SLACKER_ROOT/lib" 'include "render";
    length == 1 and (.[0] | export_page_valid($kind; $root; $before; $after; $cursor; ($limit|tonumber)))
  ' --arg kind "$kind" --arg root "$root" --arg before "$before" --arg after "$after" \
    --arg cursor "$cursor" --arg limit "$limit" "$body" >/dev/null 2>&1; then
    slacker_error invalid_export_page escalate \
      'The API page is malformed, out of bounds, or cannot advance. No export checkpoint was emitted.' \
      'Keep the previous durable checkpoint and report this failure; do not skip the page.'
    return 1
  fi

  # Read existing maps only. A missing/stale/invalid cache leaves stable IDs
  # unresolved instead of performing optional network requests after the page.
  local users channels name
  users=$(mktemp "${TMPDIR:-/tmp}/slacker_export_users.XXXXXX")
  channels=$(mktemp "${TMPDIR:-/tmp}/slacker_export_channels.XXXXXX")
  jq -ce 'select(type=="object")' "${SLACKER_CACHE_DIR:-}/users.json" > "$users" 2>/dev/null || printf '{}' > "$users"
  jq -ce 'select(type=="object")' "${SLACKER_CACHE_DIR:-}/channels.json" > "$channels" 2>/dev/null || printf '{}' > "$channels"
  name=$(jq -r --arg id "$channel" '.[$id] // $id' "$channels")
  local output
  output=$(mktemp "${TMPDIR:-/tmp}/slacker_export_xml.XXXXXX")
  if ! jq -rs -L "$SLACKER_ROOT/lib" 'include "render";
    .[0] | render_export_page({kind:$kind,channel:$channel,name:$name,root:$root,
      before:$before,after:$after,cursor:$cursor,limit:$limit}; $users[0]; $channels[0])
  ' --arg kind "$kind" --arg channel "$channel" --arg name "$name" --arg root "$root" \
    --arg before "$before" --arg after "$after" --arg cursor "$cursor" --arg limit "$limit" \
    --slurpfile users "$users" --slurpfile channels "$channels" "$body" > "$output" 2>/dev/null; then
    slacker_error invalid_export_page escalate \
      'The API page could not be rendered. No export checkpoint was emitted.' \
      'Keep the previous durable checkpoint and report this failure; do not skip the page.'
    return 1
  fi
  cat "$output"
}
