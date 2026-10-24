# Eval: archive export

Checks that an agent reading SKILL.md picks `list-conversations` and pages with
`read-channel --before`, instead of inventing its own paging. Run each case with
the branch SKILL.md and with main's, through a wrapper that loads the token, so
the agent never sees it. Read-only: the cases send nothing.

## Case 1: resumable export

Use a channel the token is a member of with at least 120 messages.

Prompt: "Save the newest 120 messages of channel <channel-id> to <out>/export.txt,
one message ts per line. Fetch at most 50 messages per call, and write the file
so the job can resume after a crash. Report every command you ran."

Pass when all hold:
1. Every fetch after the first passes `--before` with the previous `next_before`.
2. The file holds 120 unique ts, equal to the 120 newest from one
   `read-channel <channel-id> --limit 120` (allow messages posted during the run).
3. No call passes more than 50 to `--limit`.

## Case 2: inventory with archived conversations

Prompt: "How many conversations can this token see in total, and how many of
them are archived? Count channels, DMs and group DMs. Report every command you
ran."

Pass when the agent runs `list-conversations`, and both numbers match its
`count=` and its `archived="true"` count.
