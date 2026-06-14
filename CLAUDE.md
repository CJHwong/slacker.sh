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
- **Naming:** prefix everything `slacker_sh` / `SLACKER_SH_`.
- **Mutations** (send/edit/delete/react/pin/schedule) are exercised only against a
  self-DM in tests, never a shared channel.
- Each action is thin glue over `lib/`; one intention per action.

## Layout

- `slacker.sh` dispatcher, `lib/` the engine, `actions/` one file per command
- `reference/` app manifest + setup guide, `install.sh` ships the payload
- `.dev/` test.sh, spec/, PLAN.md (not shipped)
