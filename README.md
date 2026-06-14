# slacker.sh

A portable, agent-friendly Slack CLI. It's plain `bash` and leans only on tools
you almost certainly already have (`jq` and `curl`), so there's no MCP server,
language runtime, or SDK to install; drop the scripts anywhere and run.

Each command is one *intention* that composes several Slack Web API calls into
one fully-resolved **XML** payload — IDs become names, mentions and links
decoded, reactions and files folded in, thread sizes shown, timestamps humanized
— so an agent gets the whole picture in one call, with no follow-up ID-chasing.

```sh
$ slacker.sh read-channel '#general' --limit 3
<channel name="general" id="C0743D6UF">
  <message author="Alice Lee" time="2026-06-14 10:02" replies="2">
    <text>shipping the release today, thanks @Bob and #release-mgmt</text>
    <reactions><reaction emoji="rocket" count="2" by="Bob, Carol"/></reactions>
  </message>
</channel>
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/CJHwong/slacker.sh/main/install.sh | bash
```

This installs the skill to `~/.claude/skills/slacker-sh` (it fetches the repo and
copies the payload). Or clone and run it yourself:
`git clone https://github.com/CJHwong/slacker.sh.git && ./slacker.sh/install.sh`.
Then add a Slack **user token** (`xoxp-…`) — follow the
[setup guide](https://github.com/CJHwong/slacker.sh/blob/main/reference/setup.md)
to create the app and get one:

```sh
echo 'SLACKER_SH_TOKEN=xoxp-…' > ~/.claude/skills/slacker-sh/.env
~/.claude/skills/slacker-sh/slacker.sh whois @yourname    # verify -> a <user> record
```

Requirements: `bash`, `jq`, `curl` (checked at startup). To call it as plain
`slacker.sh`, symlink it onto your PATH. The installed copy is self-contained, so
you can delete the clone afterward.

### Updating

Re-run the installer — it reinstalls the latest:

```sh
curl -fsSL https://raw.githubusercontent.com/CJHwong/slacker.sh/main/install.sh | bash
```

## Docs

- **Commands, output markers, gotchas** — [SKILL.md](SKILL.md). The authoritative
  reference; it's also what the agent reads.
- **Create the Slack app** — [reference/setup.md](reference/setup.md): manifest,
  scopes, token.
- **Design rationale & limitations** — [.dev/PLAN.md](.dev/PLAN.md).

## Configuration

| Env var | Effect |
|---|---|
| `SLACKER_SH_TOKEN` | the `xoxp-…` user token (required) |
| `SLACKER_SH` | path to `slacker.sh`, if not invoking it by full path |
| `SLACKER_CACHE_TTL` | users/channels cache TTL, seconds (default 3600) |
| `SLACKER_CONCURRENCY` | parallel thread fetches for `--threads` (default 8) |
| `SLACKER_SH_NO_UPDATE_CHECK` | set `1` to silence the update notice |

## Development

The repo root *is* the skill (what `install.sh` ships); `.dev/` is dev-only.

```sh
./.dev/tests/run.sh                      # offline unit + live round-trips (self-DM, cleaned up)
SLACKER_SKIP_LIVE=1 ./.dev/tests/run.sh  # unit only (no token)
./.dev/tests/unit.sh                     # just the offline unit tests
shellcheck -x slacker.sh lib/*.sh actions/*.sh install.sh .dev/tests/*.sh
```
