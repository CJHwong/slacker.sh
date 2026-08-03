# CLAUDE.md

Guidance for agents working on this repo. Read [`.dev/PLAN.md`](.dev/PLAN.md) for
the full design rationale, and [`SKILL.md`](SKILL.md) for the action and output
contract, before changing anything.

## What this is

slacker.sh is an agent-friendly Slack CLI: each command composes several Slack
Web API calls into one fully-resolved XML payload (ids become names, mentions and
links decoded, threads sized, timestamps humanized). The repo root *is* the skill;
`.dev/` is dev-only and not shipped. `install.sh` defines the shipped payload.

## Invariants (do not break)

- **Stack is bash + jq + curl only.** No new dependencies and no test frameworks;
  the suite is a hand-rolled reporter. `xmllint` is optional and test-only.
- **Keep it green before done:**
  - `shellcheck -x slacker.sh lib/*.sh actions/*.sh install.sh .dev/tests/*.sh`
    plus `shellcheck -s sh .dev/tests/stub/curl` (the stub is POSIX sh, not bash)
  - `SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh` (offline; add a token for the live pass)
  - `SLACKER_SKIP_LIVE=1 /bin/bash ./.dev/tests/run.sh` — **also run it under bash
    3.2.** Nothing else catches the bash-3.2-only breakage class (see Gotchas).
  - `./.dev/tests/coverage.sh` — line coverage with a ratchet. CI enforces
    `SLACKER_COV_FLOOR=94`; raise the floor when coverage rises, never lower it.
  - tests live in `.dev/tests/`: `helpers.sh` (harness), `unit.sh` (pure functions
    + render.jq), `actions.sh` (offline end-to-end through the real binary),
    `live.sh` (integration), `run.sh` (entry), `coverage.sh` + `execlines.awk`
    (coverage), `stub/curl` + `fixtures/` (the offline network).
  - Add pure-function and render cases to `unit.sh`; anything that needs the
    dispatcher, argument parsing, caches, pagination, or an API call shape goes in
    `actions.sh`, which drives the real `slacker.sh` with `stub/curl` first on
    PATH. New API responses are fixtures, never live calls.
- **ARG_MAX-safe:** never pass unbounded data via `jq --argjson` on argv. Stream
  to JSONL temp files (`--slurpfile`) or use `--rawfile`. See `lib/http.sh`.
- **Never truncate silently:** emit a `<more …/>` marker when a cap is hit.
- **Resolve, do not leak ids:** all rendering goes through `lib/render.jq`; output
  is XML, escaped exactly once.
- **One XML document on stdout, always:** the payload on success, or an `<error
  command code action>` on failure (exit non-zero). Errors are a *result* the
  agent parses, not a stderr log line. Emit them with `slacker_error` (lib/http.sh),
  which writes to **fd 3** (a dup of stdout opened by the dispatcher) so the error
  escapes any `$(…)` capture — fatal call sites keep `|| return 1` unchanged. A
  site that *tolerates* a failure (`… || fallback`) MUST add `3>/dev/null`, or the
  error leaks onto an otherwise-successful payload. stderr is for advisories only
  (token warnings; cache chatter behind `SLACKER_SH_VERBOSE`). Usage/help/unknown-flag
  text stays on stderr — it's not a result.
- **Naming:** prefix everything `slacker_sh` / `SLACKER_SH_`.
- **Mutations** (send/edit/delete/react/pin/schedule) are exercised only against a
  self-DM in tests, never a shared channel.
- Each action is thin glue over `lib/`; one intention per action.

## Gotchas

- **Portable `stat`: GNU form first.** `slacker_mtime`/`slacker_fsize` try `stat -c`
  before BSD `stat -f`. BSD-first looks fine on macOS, but on Linux GNU `stat -f`
  is "filesystem mode" and leaks a block to stdout before failing, poisoning the
  result. Keep GNU-first.
- **Three userlands, two bash generations — a green Linux run proves nothing on
  its own.** Apple has never shipped past `bash 3.2.57` as `/bin/bash`, and these
  break there while passing on bash 5:
  - **Expanding a possibly-empty array under `set -u` is fatal before bash 4.4.**
    `"${arr[@]}"` on an empty array aborts the command *before* the API call, so a
    send silently posts nothing. Bash 4.4+ accepts it, which is why it hid. Always
    seed an argument array with a mandatory parameter (`--data-urlencode
    "channel=$id"`) so it can never be empty; branch rather than expand when there
    is no mandatory parameter. Don't reach for `${arr[@]+"${arr[@]}"}` and don't
    turn off `set -u`.
  - **Bash 3.2 mis-parses `\"` inside a `$(…)` that sits inside a double-quoted
    argument.** `f "$(g "…\"x\"…")"` gets word-split and the inner program
    shredded. Assign to a local first — that's what `wantfx` in `helpers.sh` is for.
  - **`PS4` is not inherited portably.** Bash 5.3 imports an exported `PS4`; 5.2
    ignores it. `coverage.sh` passes it to children via `BASH_ENV` instead.
  - **`BASH_XTRACEFD` must not leak to a child process** — it names a fd in the
    parent, and a child inheriting the name without a valid fd silently discards
    its entire trace.
  Run `SLACKER_SKIP_LIVE=1 /bin/bash ./.dev/tests/run.sh` locally, and keep the
  busybox leg: it has already caught busybox `date` rejecting `YYYY-MM-DDTHH:MM`
  and the absent `shasum` that killed the binary with no output at all.
- **Nothing outside `jq` and `curl` may be required at runtime.** `lib/cache.sh`
  hashes the token for the cache namespace and tries `shasum`, then `sha1sum`, then
  `cksum`, then gives up gracefully. `shasum` is a perl script and is missing on
  Alpine; as a bare pipeline under the dispatcher's `set -euo pipefail` it returned
  127 and killed slacker.sh with **empty stdout and empty stderr** — no `<error>`
  for the agent to parse. Any new top-level pipeline in a sourced lib carries the
  same risk: it runs under `set -e` before the dispatcher can report anything.
- **Pagination reads `response_metadata.next_cursor`, not `.cursor`.** `cursor` is
  the *request* parameter; the response field is `next_cursor`. Reading `.cursor`
  makes every paginated call silently return only the first page, and
  `slacker_fetch_replies` never sets `truncated` — so the "never truncate silently"
  invariant breaks with no `<more/>`. Under 1000 users/channels nothing looks wrong,
  which is how it survived. Fixtures in `.dev/tests/fixtures/` cover the multi-page
  path for `users.list`, `conversations.history`, and `conversations.replies`.
- **Lint against CI's shellcheck, not just yours.** CI uses Ubuntu's apt shellcheck
  (currently 0.9.x), which flags things a newer local build won't. Reproduce it:
  `docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:v0.9.0 -x slacker.sh lib/*.sh actions/*.sh install.sh .dev/tests/*.sh`.
- **Test on a clean Linux box too.** A present `.env` masks SC1091 on the `.env`
  source, and BSD/GNU differences hide on macOS. Run the suite in a container:
  `docker run --rm -v "$PWD:/m" -w /m ubuntu:24.04 bash -c 'apt-get update -qq >/dev/null && apt-get install -y -qq jq git libxml2-utils >/dev/null && SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh'`.
- **`# shellcheck source=...` must sit on its own line directly above the sourced
  command**, not bundled into `set -a; . file; set +a`, or it binds to the wrong
  command and SC1091 fires only in CI.
- **The token is enforced lazily in `slacker_api` (once-guarded), not the
  dispatcher.** That keeps `help` / `-h` / usage working without a token. Don't
  move the check back to the dispatcher.
- **Each action needs a `# help: <read|write> | <desc>` header line** or it won't
  appear in `slacker.sh help` (the dispatcher builds the list from those lines).
- **`.dev/spec/` is a vendored Slack OpenAPI snapshot with example tokens.** Keep
  them redacted to `X` placeholders; GitHub push protection blocks realistic ones.
- **`actions.sh` runs the binary from a throwaway root**, a copy of `slacker.sh`
  beside symlinks to `lib/` and `actions/`. The dispatcher sources
  `$SLACKER_ROOT/.env`, so running the repo copy would pull in a developer's real
  token and settings and make local results diverge from CI. Keep the copy.
- **Coverage measures bash only.** `lib/render.jq` is jq and is invisible to the
  tracer despite being the best-tested part of the engine, and one-line
  `stat -c … || stat -f …` fallbacks can only ever run one arm per OS. Treat the
  percentage as a conservative lower bound: the denominator is a static estimate
  unioned with what was actually traced, so it can understate coverage but never
  overstate it. `SLACKER_COV_DETAIL=all` lists what is missing,
  `SLACKER_COV_AUDIT=1` shows where the static estimate and reality disagree.

## Layout

- `slacker.sh` dispatcher, `lib/` the engine, `actions/` one file per command
- `reference/` app manifest + setup guide, `install.sh` ships the payload
- `.dev/` tests/, spec/, PLAN.md (not shipped)
