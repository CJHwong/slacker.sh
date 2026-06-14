---
name: slacker-sh
description: >-
  Use when the user wants to read, search, or act on Slack from the terminal,
  even when they don't say the word "Slack." Triggers include a pasted Slack
  permalink (slack.com/archives/…); a #channel, thread, DM, or person referred to
  by name; or asks like "catch me up on #incidents", "what did Alice say in #eng",
  "search Slack for the deploy postmortem", "reply in that thread", "post this to
  #team", "react to her message", "DM Bob", or "who is @carol, is she online?". It
  covers reading channels, threads, and DMs, cross-channel search, people and
  channel lookups, reading files and canvases, and posting, editing, reacting,
  pinning, and scheduling messages. Prefer it over raw Slack Web API calls or a
  Slack MCP: each command returns one fully-resolved result in a single call.
---

# slacker.sh

A CLI of agent-friendly Slack actions. Each action is one *intention* (e.g. "show
me what's happening in #channel") composed from several Slack Web API calls and
rendered as one resolved **XML** payload. You don't chase IDs: names, mentions,
links, reactions, files, and timestamps come back already decoded; thread sizes
are shown, and a full thread is one more call away.

## Running it

`slacker.sh` lives in this skill's directory, next to this SKILL.md (with its
`lib/` and `actions/`). Invoke it by that path, or via `$SLACKER_SH` / PATH if
you've set those up:

```sh
SLACKER="${SLACKER_SH:-<this-skill-dir>/slacker.sh}"
"$SLACKER" whois @yourname     # smoke test (your own Slack handle) -> a <user> record
```

Don't fall back to raw `curl`/the Slack API or a Slack MCP — the one-shot
resolved XML is the whole point. If a command fails, see **Troubleshooting**.

## Actions

Quick reference — the common path from intent to command (prefix each with the
resolved `$SLACKER`):

| Task | Command |
|---|---|
| Catch up on a channel | `read-channel '#chan' --since 7d` |
| Read a thread from a link | `read-message <permalink>` |
| Search | `search "deploy postmortem" --in #chan --from @user` |
| Look up a person | `whois @name --channels` |
| Read an attachment / canvas | `read-file <permalink>` · `read-canvas '#chan'` |
| Post, or DM a person | `send <#chan\|@user> "text"` |
| Reply in a thread | `send '#chan' "text" --thread <permalink>` |
| React / pin / edit / delete | `react\|pin\|edit\|delete <permalink> …` |
| Schedule for later | `schedule '#chan' "text" --at +2h` |

Full flags below (or run any action bare to print its usage).

**Read (safe — no side effects, use freely):**

| Command | What it does |
|---|---|
| `read-channel <#ch\|@user\|id> [--since <date|7d>] [--limit N] [--threads] [--reply-cap N]` | channel/DM history; threads shown as `replies="N"`, `--threads` to inline them |
| `read-message <permalink\|--channel <ch> --ts <ts>> [--no-thread]` | one message in full thread context (the linked one marked `target="true"`) |
| `search <query> [--in #ch] [--from @user] [--since <date|7d>] [--limit N] [--page N]` | enriched cross-channel search |
| `whois <@user\|name\|id\|email> [--channels]` | person dossier: name, presence, dnd, tz, and (with `--channels`) the channels the user belongs to |
| `channel-info <#ch\|id>` | topic, purpose, members, pins |
| `read-file <permalink\|Fid>` | Slack-hosted attachment: text inlined, binary saved to cache |
| `read-canvas <Fid\|permalink\|--channel <ch>>` | canvas content as readable text |
| `usergroup [<@handle\|name\|S-id>]` | list user groups, or expand one to members |

**Mutate (observable to other people — confirm first, see below):**

| Command | What it does |
|---|---|
| `send <#ch\|@user> <text> [--thread <link>] [--broadcast] [--no-unfurl] [--mrkdwn] [--file <path>]…` | post a message |
| `edit <permalink\|--channel/--ts> <text> [--mrkdwn]` | edit your own message |
| `delete <permalink\|--channel/--ts>` | delete your own message |
| `react <permalink\|--channel/--ts> <emoji> [--remove]` | add/remove a reaction |
| `pin <permalink\|--channel/--ts> [--remove]` | pin/unpin a message |
| `schedule <#ch\|@user> <text> --at <when> \| --list \| --cancel <id> --channel <ch>` | scheduled messages (`when`: epoch, `YYYY-MM-DD HH:MM`, or `+30m`) |

Message text is standard **Markdown** by default (`**bold**`, `[label](url)`,
`- lists`) — Slack renders it. `--mrkdwn` sends raw Slack mrkdwn instead; see
Gotchas for why Markdown is the better default.

## Reading the output

Everything is well-formed XML on stdout, already resolved. A read looks like:

```xml
<channel name="general" id="C0743D6UF">
  <message author="Alice Lee" id="U03ABC" time="2026-06-14 10:02" ts="1718359320.001" replies="2">
    <text>shipping today, thanks @Bob and #release-mgmt</text>
    <reactions><reaction emoji="rocket" count="2" by="Bob, Carol"/></reactions>
  </message>
</channel>
```

Lean on these markers instead of guessing:

- `replies="N"` on a `<message>` — thread size. It is *not* inlined by default;
  drill in with `read-message <permalink>` or re-run `read-channel --threads`.
- `target="true"` — the specific message a permalink pointed at (vs surrounding
  thread context).
- `bot="true"` / `deactivated="true"` — author is an app or a deactivated user.
- `<more …/>` — pagination or truncation; widen with `--limit` / `--since` /
  `--reply-cap`.
- `<file … deleted="true"/>` — a tombstone for a removed attachment.

Errors go to **stderr** with an actionable hint (e.g. a missing OAuth scope is
named explicitly). If a read returns a scope error, surface that to the user —
it means the app needs reinstalling with that scope.

## Mutation discipline

The mutate actions are visible to other people, so treat them with care:

- **Confirm the target and text before sending** unless the user has clearly
  asked you to send right now. Echo back *what* you'll post and *where*.
- **Never post to a channel the user didn't name.** Resolve `#channel`/`@user`
  exactly; if a name is ambiguous, ask rather than guess.
- To test posting/reacting without bothering anyone, target your **own DM**
  (`send @your-handle …`, using your own Slack handle) — no audience but you.
- `edit`/`delete` only work on *your own* messages (it's a user token).

## Gotchas

Environment facts that defy reasonable assumptions — read these before you act:

- **A bare `read-channel` returns the channel's *entire* history** (huge on an old
  channel). For a "catch me up" / "what's recent" ask, scope it with `--since` —
  a date (`--since 2026-06-01`) or a relative span (`--since 7d`, `2w`, `24h`).
- **Threads are not inlined by default** — a `<message>` only carries
  `replies="N"`. See the replies with `read-message <permalink>` or re-run
  `read-channel --threads` (one API call per thread; it honors `--since`). Only
  ask for `--threads` when the replies actually matter.
- **`whois --channels` lists the public channels the target is *in*, not the ones
  you share** — Slack returns all their public channels even if you're not a
  member; private channels appear only where you both are. Don't call the list
  "channels in common."
- **`search` ranks by recency and matches loosely** — `total=` is a raw match
  count, not a relevance score, and tangential hits sneak in. Read the top
  results and judge relevance yourself; narrow with `--in` / `--from` / `--since`.
- **Markdown-by-default is deliberate** — Slack renders `**bold**`, `[label](url)`,
  `- lists`, and it works even when the markup hugs CJK (`這是**粗體**字`).
  `--mrkdwn` sends raw Slack mrkdwn (`*bold*`), which needs spaces around the
  markers and breaks against CJK — don't reach for it just for emphasis.
- **Name lookups are fuzzy** (`whois Alice`, `send @alice`): an exact name wins,
  else a unique substring; an ambiguous name errors so you can disambiguate.
  Email and `Uxxxx` ids resolve exactly.
- **`read-file` only works on Slack-hosted files.** A file that's actually an
  external link (Google Docs, Dropbox) can't be downloaded — it errors rather
  than returning content. Open its permalink instead.
- **You can read any channel you're a member of** (user token, no bot to invite),
  and a Slack permalink is the most reliable handle for `read-message`, `react`,
  `edit`, `delete`, `pin` — paste it straight in.

## Troubleshooting

On failure, slacker.sh prints an actionable hint to stderr — act on it (a missing
scope names the scope; a "not found" name suggests passing the id; an external
file says to open the permalink). Two messages need a word more:

- **`SLACKER_SH_TOKEN not set`** — no token configured yet (the CLI itself is
  fine). Create the Slack app and get an `xoxp-…` user token by following
  `reference/setup.md` (it uses `reference/slack-manifest.json`), then store it
  next to `slacker.sh` in this skill's directory:
  `echo 'SLACKER_SH_TOKEN=xoxp-…' > <this-skill-dir>/.env` (gitignored), or
  `export SLACKER_SH_TOKEN=xoxp-…`. Verify: `slacker.sh whois @yourname`.
- **`update available …`** — not an error; the code is behind upstream. To update,
  re-run the installer, which reinstalls the latest:
  `curl -fsSL https://raw.githubusercontent.com/CJHwong/slacker.sh/main/install.sh | bash`.
  Silence the notice with `SLACKER_SH_NO_UPDATE_CHECK=1`.
