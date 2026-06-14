# slacker.sh — design notes

Why slacker.sh is shaped the way it is. The README is the user-facing entry; the
SKILL.md is the agent-facing reference; this is the rationale behind both.

## Thesis

Raw Slack Web API methods are CRUD primitives full of opaque IDs (`<@U07ABC>`,
`<#C09XYZ>`), manual pagination, and fragmented context — an agent calling them
spends most of its turns chasing IDs and stitching responses together.

slacker.sh exposes *intentions* instead of methods. The rule for every action:

> resolve everything, denormalize, return one self-contained payload the caller
> never has to follow up on.

One command ("show me what's happening in #channel") fans out to several methods,
resolves every id to a name, decodes mentions/links, folds in reactions and
files, shows thread sizes, humanizes timestamps, and emits one XML document.

## Design decisions

- **Output: XML.** `jq` builds the structure; emit escapes `&<>"` exactly once.
  XML nests the resolved object graph cleanly and is unambiguous to parse.
- **Transport: curl + token, from scratch.** No CLI wrappers or SDKs.
- **Auth: one user token (`xoxp-`)** in `SLACKER_SH_TOKEN`. A user token reads
  every channel you're in with no invite, posts and reacts as you, and — unlike a
  bot token — can `search.messages`. Treat it like a password. The prefix is
  validated; a bot/malformed token warns clearly.
- **Cache is the engine.** `users.list` + `conversations.list` are dumped to disk
  (TTL + refresh-on-miss) so id→name resolution is one disk read, not N API
  calls. Namespaced per token so switching workspaces can't cross-resolve.
- **Message text is Markdown by default**, sent via Slack's `markdown_text` so
  Slack renders it server-side to rich_text (works even when markup hugs CJK).
  `--mrkdwn` opts into raw Slack mrkdwn. slacker never rewrites the user's text.
- **Naming:** everything is prefixed `slacker_sh` / `SLACKER_SH_`.
- **Bloat discipline:** each action fetches exactly what serves its one intention,
  and never truncates silently — it emits a `more` marker when a cap is hit.

## Architecture

The repo root *is* the skill. `lib/` does the real work; each action is thin glue.

```
SKILL.md            agent-facing reference (triggering, vocabulary, gotchas)
slacker.sh          dispatcher: resolve self (symlink-safe), load .env, route to action
lib/
  http.sh           curl + auth, ok:false surfacing, retries, error explainer,
                    pagination + reply fetch (JSONL temp files), update check
  cache.sh          users/channels dumps, TTL, external-user augment, update notice
  parse.sh          input resolution: channel, user (fuzzy), message, permalink, time
  render.jq         resolve + render: decode mentions/links/ts, escape, emit XML
actions/*.sh        one file per intention (thin glue over lib)
reference/          slack-manifest.json + setup.md (app creation guide)
install.sh          copy the skill payload into the agent's global skills path
.dev/               dev-only, not shipped: test.sh, spec/, this file
```

Resolve and render are a single jq module (`render.jq`), not separate shell
files: the logic is all jq (gsub-based mention/link decoding, strftime, escaping),
so shell wrappers would be empty bloat.

## Actions

All use the single user token. `search` is the only one impossible without it.

**Read (no side effects):**

- **read-channel** `<#ch|@user|id> [--since] [--limit] [--threads] [--reply-cap]`
  — `conversations.list` (cached) + `conversations.history` (paginated to
  limit/since) + `users.list` (cached) + embedded `files[]`/`attachments[]`.
  Threads are *not* inlined by default: each message carries `replies="N"`.
  `--threads` inlines them via `conversations.replies` (one call per thread, run
  in parallel). Output: `<channel>` with `<message>` children (author, time,
  resolved text, `<reactions>`, `<files>`, `<forward>`, optional `<thread>`).
- **read-message** `<permalink | --channel --ts> [--no-thread]` — one verb for
  message-or-thread. The linked message is always the outer `<message>`
  (foregrounded); the surrounding conversation nests as `<thread>` context with
  the linked one marked `target="true"`. A reply permalink carries the
  `thread_ts`; a bare `--ts` resolves top-level messages only.
- **search** `<query> [--in] [--from] [--since] [--limit] [--page]` — flags become
  Slack modifiers (`in:`/`from:`/`after:`); `search.messages` + per-hit enrichment
  (author, channel name, permalink, resolved snippet). Recency-ranked, loose
  match; output carries `page`/`pages`/`total` and a `more` marker.
- **whois** `<@user|name|id|email> [--channels]` — `users.info` +
  `users.getPresence` + `dnd.info`; `--channels` adds `users.conversations` (the
  public channels the user is in, plus shared private ones). Email resolves via
  `users.lookupByEmail`.
- **channel-info** `<#ch|id>` — `conversations.info` + members (resolved names) +
  `pins.list` + topic/purpose.
- **read-file** `<permalink|Fid>` — `files.info` + authed `url_private` download;
  text/html inlined (capped, HTML→text), binaries saved to cache with a path.
- **read-canvas** `<Fid|permalink|--channel>` — canvases are quip-mode files:
  resolve the canvas id → `files.info` → download HTML → `html_to_text`. Emits a
  `<note>` (not silent empty) when extraction yields nothing (native canvas).
- **usergroup** `[<@handle|name|S-id>]` — `usergroups.list`, or expand one to
  resolved members.

**Write (observable; mutations are validated only against a self-DM):**

- **send** `<#ch|@user> <text> [--thread] [--broadcast] [--no-unfurl] [--mrkdwn]
  [--file …]` — resolve target (opens a DM for `@user`/email); `chat.postMessage`
  with `markdown_text` + `chat.getPermalink`. `--file` uploads via
  `files.getUploadURLExternal` → PUT bytes → `files.completeUploadExternal`.
  Caption nuance: Slack's upload treats `initial_comment` as raw mrkdwn, so a
  Markdown caption (no explicit `--thread`, not `--mrkdwn`) is posted as a
  `markdown_text` parent and the file nested as a reply, so the caption renders.
- **edit** `<permalink | --channel --ts> <text> [--mrkdwn]` — `chat.update`.
- **delete** `<permalink | --channel --ts>` — `chat.delete` (own messages only).
- **react** `<permalink | --channel --ts> <emoji> [--remove]` — `reactions.add/remove`.
- **pin** `<permalink | --channel --ts> [--remove]` — `pins.add/remove`.
- **schedule** `<#ch|@user> <text> --at <when> | --list | --cancel <id> --channel`
  — `chat.scheduleMessage` / `scheduledMessages.list` / `deleteScheduledMessage`.
  Delivery is verified end-to-end. Note: API-scheduled messages do not appear in
  the Slack client's "Scheduled" panel (that only shows client-scheduled ones) —
  they are real and will post; `schedule --list` is the canonical view.

Forwarded/shared messages are not a separate action — every read action parses
`attachments[]` shares into `<forward from channel time>…</forward>`.

## Resolution & caching

- Users cache entry: `id → {n: display, r: real_name, h: handle, d: deleted}`.
- **Fuzzy lookup** (whois, `search --from`, DM targets): case-insensitive exact
  match on display/real/handle wins; else unique substring (preferring active
  accounts); an ambiguous substring errors with the candidate list + ids. Email
  and `Uxxxx` ids resolve exactly.
- **Deactivated users** still resolve to names and get `deactivated="true"`.
- **External / Slack Connect users** are absent from `users.list`; they're
  resolved on demand via `users.info` and persisted to `users_extra.json`, so
  each unknown id costs one API call ever.

Denormalization correctness (each a real failure mode, guarded):

- `users.list` on a large workspace must stream pages to a JSONL temp file —
  accumulating the growing array via `jq --argjson` on argv blows ARG_MAX and
  silently yields a 0-byte cache (everything renders as raw ids).
- Bot/system messages have a null `.user`; jq throws on `$map[null]` *before* `//`
  can catch, so every map-by-field lookup guards the key with `// ""`.
- Slack pre-encodes `& < >` in message text; `resolve_text` decodes Slack entities
  before the single `xml_escape`, so output isn't double-encoded (`&amp;gt;`).
- `xml_escape` strips XML-1.0-illegal control bytes.
- Block Kit / attachment-only messages have empty `.text`; `blocks_to_text`
  derives a readable fallback from rich_text and attachment fields.

## Pagination

Everything is bounded and announces when more remains:

- **history**: cursor-paginated to `--limit`; `<more>` when Slack `has_more` and
  the cap is hit.
- **thread replies**: cursor-paginated to `--reply-cap` (default 200); a `<more>`
  sentinel inside `<thread>` when truncated.
- **search**: page-based via `--page` (Slack max 100/page); `<more>` when pages
  remain.

## Error handling

`slacker_explain_error` maps Slack error codes to an actionable mitigation hint
so the agent can self-correct or tell the user. Covered: `missing_scope` (names
the scope), `not_allowed_token_type`, the auth-failure family,
`channel_not_found` (ext-shared → use id), `not_in_channel`/`is_archived`,
`user_not_found`, `cant_delete/update_message`, the not-found family,
`msg_too_long`, `already_reacted`, `rate_limited`, and network failure.
`resolve_channel`/`resolve_user` add their own hints (use id; rebuild cache).

Scope-gated actions degrade with a clear `missing_scope` message rather than a
hard failure: `pin` (`pins:write`), `whois` dnd (`dnd:read`). With the app
installed from `slack-manifest.json`, all scopes are granted.

## Performance

- **read-channel `--threads` was O(threads) serial calls.** A busy channel (~200
  messages, ~94 threaded parents) took ~69s because each thread's
  `conversations.replies` ran serially. The per-thread fetches now run in parallel
  via `xargs -P "${SLACKER_CONCURRENCY:-8}"` (workers reuse exported lib functions;
  `SLACKER_API_BASE` is exported so child shells reach the API): ~69s → ~10s,
  identical output.
- **Threads off by default.** `replies="N"` (from `reply_count`, zero extra API
  cost) lets the agent see thread sizes and drill in with `read-message` only
  where needed — the common path is fast and context-light.

## Distribution & updates

- **The repo is the skill.** `install.sh` copies the payload (`SKILL.md`,
  `slacker.sh`, `lib/`, `actions/`, `reference/`) into the agent's global skills
  path, leaving `.dev/` and local files behind, so the installed copy is
  self-contained.
- **Symlink-safe dispatcher.** `slacker.sh` resolves its own path through symlinks
  before computing `SLACKER_ROOT`, so a `ln -s …/slacker.sh /usr/local/bin/` PATH
  install still finds `lib/`/`actions/`.
- **Notify-only update check.** On startup (throttled to at most once a day via a
  marker file), and only when running from a git checkout with an upstream,
  slacker.sh fetches and prints one stderr line if the checkout is behind. It
  never mutates the repo or runs remote code; `SLACKER_SH_NO_UPDATE_CHECK=1`
  silences it. Copied installs aren't git checkouts, so they simply don't notify.

## Production hardening

- **ARG_MAX-safe everywhere**: no unbounded data via `jq --argjson` on argv.
  Pagination/threads stream to JSONL temp files (`--slurpfile`); large file/canvas
  text uses `--rawfile`.
- **No SIGPIPE aborts**: content is downloaded to a file then capped with
  `head -c`, never `curl | head` (which SIGPIPEs curl past the cap under pipefail).
- **shellcheck -x clean** across the dispatcher, lib, actions, install.sh, and the
  test suite (sourced files carry `# shellcheck shell=bash`).
- **Cross-platform**: portable stat (`slacker_mtime`/`slacker_fsize`) and date
  (`slacker_parse_when`) try BSD then GNU — macOS and Linux.
- **Dependency check** (jq/curl) at startup; **temp cleanup** via a run-scoped
  `TMPDIR` removed on EXIT/INT/TERM.
- **CI**: shellcheck + offline test suite on Linux.

## API coverage & scope

Covered (~30 methods): `conversations.{list,history,replies,info,members,open}`,
`chat.{postMessage,update,delete,getPermalink,scheduleMessage,
scheduledMessages.list,deleteScheduledMessage}`, `reactions.{add,remove}`,
`pins.{list,add,remove}`, `files.{info,getUploadURLExternal,
completeUploadExternal}`, `users.{info,list,getPresence,lookupByEmail,
conversations}`, `usergroups.{list,users.list}`, `dnd.info`, `search.messages`.

Deliberately out of scope: `admin.*` (enterprise); app development
(apps/views/dialog/workflows/oauth/bots/functions); realtime (rtm); `calls.*`;
`files.remote.*`; infra (auth.revoke, team logs, api.test); profile/presence
setters.

Retired by Slack — do not build: `reminders.*` and `stars.*`. `reminders.add`
returns ok but the reminder isn't listed/deletable and does not fire (verified:
no Slackbot delivery); the only replacement is Workflow Builder.

Candidates if ever needed: channel management
(`conversations.create/join/invite/setTopic/rename/archive`), `files.list/delete`,
`chat.postEphemeral`, usergroups write, `users.profile.*`, canvas *write*
(`canvases.create/edit/delete`), `bookmarks.*`.

## Known limitations

- **ext-shared (Slack Connect) channels** aren't returned by `conversations.list`,
  so the cache lacks them and resolve-by-name fails — address them by channel id
  (`conversations.info` works by id).
- **fuzzy substring** over a large directory can be ambiguous; the error lists
  candidates so the caller can pick the id.
- **`read-message` bare `--ts`** resolves top-level messages only; a reply needs
  its permalink (only the permalink carries the `thread_ts`).
- **`channel-info`** lists all members uncapped — fine for small channels, may want
  a cap/summary for very large ones.
- deleted files render as `<file id="…" deleted="true"/>` (Slack tombstone).

## Testing

The suite lives in `.dev/tests/` as a zero-dependency reporter
(`ok`/`eq`/`has`/`want`/`grace`/`errs`), split into focused, individually
runnable files: `helpers.sh` (the harness), `unit.sh` (offline), `live.sh`
(integration), and `run.sh` (the entry point).

- **Unit (offline, in CI):** drives `render.jq` directly (escaping, entity decode,
  Block Kit fallback, marker attributes) and covers the pure `parse.sh` logic
  (fuzzy user resolution, permalink parsing, and the BSD/GNU date branches
  compared at minute precision), the `http.sh` error-code mapping, and the
  update-check gating. Deterministic, no token.
- **Live (integration):** auto-discovers a channel from whatever workspace the
  token points at and exercises the read actions read-only, plus a self-DM
  round-trip for the write actions (send/react/edit/delete/schedule) that it
  cleans up. No hardcoded workspace ids.

`SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh` runs the unit layer only.
