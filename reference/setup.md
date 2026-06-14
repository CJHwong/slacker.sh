# Create the Slack app for slacker.sh

slacker.sh talks to the Slack Web API with a **user token** (`xoxp-…`). A user
token reads every channel you're already in (no per-channel invite), can search
(bots can't), and posts/reacts as you. This guide creates an app from a manifest,
installs it to your workspace, and gets you that token.

## Setup (~5 min)

1. Go to [api.slack.com/apps](https://api.slack.com/apps) -> "Create New App".
2. Choose **"From a manifest"**.
3. Pick the workspace to install into, then "Next".
4. Paste the contents of [`slack-manifest.json`](slack-manifest.json)
   (switch the editor to JSON if it defaults to YAML), then "Next" -> "Create".
5. Review the requested scopes on the summary screen and confirm.

## Get your token

6. Left sidebar -> **"OAuth & Permissions"**.
7. Click **"Install to Workspace"** (top of that page) -> review -> **"Allow"**.
8. Back on "OAuth & Permissions", copy the **"User OAuth Token"** — it starts
   with `xoxp-…`. (Use the *User* token, not a Bot token.)
9. Put it in `.env` next to `slacker.sh` (gitignored, never committed):

   ```sh
   SLACKER_SH_TOKEN=xoxp-your-token-here
   ```

   Or export it in your shell: `export SLACKER_SH_TOKEN=xoxp-…`

10. Verify: `slacker.sh whois @yourname` should print a `<user>` record.

## Scopes (what each one enables)

| Scope | Used by |
|-------|---------|
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | read-channel, read-message (public / private / DM / group-DM) |
| `channels:read`, `groups:read`, `im:read`, `mpim:read` | channel-info, channel/DM resolution, whois --channels |
| `im:write` | send/read-channel to `@user` (opens the DM) |
| `chat:write` | send, edit, delete, schedule |
| `users:read` | name resolution everywhere, whois, channel-info |
| `users:read.email` | whois by email, email -> user lookup |
| `search:read` | search |
| `files:read` | read-file, read-canvas |
| `files:write` | send --file (upload) |
| `reactions:write` | react |
| `pins:read` / `pins:write` | channel-info (read) / pin (write) |
| `usergroups:read` | usergroup |
| `dnd:read` | whois (dnd status) |

Want a read-only install? Keep the `*:history`, `*:read`, `users:read*`,
`search:read`, `files:read`, `usergroups:read`, `dnd:read` scopes and drop the
write ones (`chat:write`, `files:write`, `reactions:write`, `pins:write`,
`im:write`). slacker.sh degrades gracefully — any action that hits a missing
scope prints exactly which scope to add.

## How it works

- The token acts as **you**: it sees what you can see, and messages/reactions
  appear under your name.
- slacker.sh caches `users.list` + `conversations.list` per token under
  `~/.cache/slacker_sh/<hash>/`, so switching tokens never crosses workspaces.
- It's read-everywhere-you-are by default; there's no bot to invite to channels.
- **Externally-shared (Slack Connect) channels** aren't returned by the API's
  channel list — address those by channel id (`Cxxxx`).

## Notes

- **Changing scopes later:** edit the app's scopes (or re-paste an updated
  manifest under "App Manifest"), then **reinstall** from "OAuth & Permissions"
  and update the token in `.env`. New scopes don't apply until you reinstall.
- **Security:** the user token can do anything you can — treat it like a
  password. It lives only in `.env`, which is gitignored.
