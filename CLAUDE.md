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
  - `SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh` (offline; add a token for the live pass)
  - tests live in `.dev/tests/`: `helpers.sh` (harness), `unit.sh` (offline),
    `live.sh` (integration), `run.sh` (entry). Add unit cases to `unit.sh`.
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

## Layout

- `slacker.sh` dispatcher, `lib/` the engine, `actions/` one file per command
- `reference/` app manifest + setup guide, `install.sh` ships the payload
- `.dev/` tests/, spec/, PLAN.md (not shipped)
