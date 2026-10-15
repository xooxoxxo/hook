---
name: instructables
description: Use whenever a session needs the owner, i.e. a manual step, an API key or token, a login, a click only they can do, a decision, an approval, an unlock or a confirmation. Sends ONE instructable (numbered steps with copy-paste code) to the owner's Relay queue with the relay_post MCP tool, or with `relay post` as a fallback. Triggers include "need the owner", "owner must", "ask the owner", "waiting on the owner", "manual step", "API key", "token", "secret", "credentials", "decision", "approve", "sign off", "click", "login", "sign in", "unlock", "only the owner can".
---

# Instructables

An instructable is one owner ask written as a puppet script: a title, a reason, and
numbered steps with exact copy-paste commands. It lands in the owner's Relay queue:
the menu-bar app on their Mac shows it in full, with a Copy button on every `code`
block, and sends a notification.

## When to send

Send one the moment the work needs the owner: an API key or token, a login, a click in
a web UI, a command on a machine you can't reach, a decision, an approval or an unlock.
Don't save asks for the end of the session. Send one ask per instructable. A "waiting
on you" line in chat alone gets lost.

## How to write it

- **title**: imperative, one line, at most 120 chars, unique, e.g. "Create a Slack channel for Acme".
  The queue dedupes on the title for 24 h, so a different ask needs a different title.
- **why**: one sentence (at most 300 chars) on what it unblocks.
- **urgency**: `now` (you're blocked this minute), `today` (the default) or `whenever`.
- **steps** (1–20): one action per step. `do` says exactly what to click or type, in
  order (site → page → menu → button). `where` names the place: "Slack desktop",
  "Mac terminal", "GitHub → Settings".
- **detail**: longer instructions for one step (at most 1500 chars, line breaks
  allowed), shown as wrapped text under `do`.
- **code**: the exact command or text to paste. Make it complete, with nothing for
  the owner to edit. Set `lang` (`bash`, `text`, `json`). Never put instructions or
  explanations in `code`: `code` is only text to copy exactly. They go in `detail`.
- **expect**: what the owner should see, on every step that can be checked.
- **url**: the exact page that step needs (http or https only).
- **verify**: a final Step that proves it worked. A command with `expect` is best.
- **reply**: for a decision, `{"prompt": "…", "choices": ["A", "B"]}`, with up to 6 choices of at most 60 chars each.
  Use `"choices": []` to ask for free text.
- **links**: up to 10 `{label, url}` pairs for specs or docs.
- Leave out `from`, because `relay_post` and `relay post` fill it in. Spell keys
  exactly: unknown keys are rejected. The whole thing must stay under 32 KB.

**Never put a secret or its value in an instructable.** Relay rejects anything that
looks like `sk-…`, `xoxb-…`, `ghp_…`, `github_pat_…`, `AKIA…` or a private key.
When the owner has to give you a secret, write a step that stores it in the Keychain,
then read it from there yourself:

```text
{"do": "Store the Acme API token in the Keychain: run this, then paste the token at the prompt (it is not shown)",
 "where": "Mac terminal", "code": "security add-generic-password -a \"$USER\" -s acme-api-token -U -w",
 "lang": "bash", "expect": "The prompt returns with no output"}
```

To read it back, run `security find-generic-password -a "$USER" -s acme-api-token -w`.

## The project name

`project` is a short project name: what the repo's CLAUDE.md names, else the repo
folder name.

## Post it with MCP

Call `relay_post` with two arguments:
- `project`: the project name above, e.g. `Acme`.
- `instructable`: the instructable itself, for example:

```json
{
  "v": 1,
  "title": "Create a Slack channel for Acme",
  "why": "The daily Acme brief needs a channel to post into.",
  "urgency": "today",
  "steps": [
    {"do": "Click + next to Channels in the left sidebar, then Create channel", "where": "Slack desktop"},
    {"do": "Paste this as the name, choose Private, click Create", "where": "Slack desktop",
     "code": "acme-brief", "lang": "text", "expect": "You land in #acme-brief"},
    {"do": "Click the channel name at the top, open About, scroll down and copy the Channel ID",
     "where": "Slack desktop", "expect": "An ID that starts with C, like C07ABC123"}
  ],
  "verify": {"do": "Reload Slack and look under Channels", "where": "Slack desktop",
             "expect": "#acme-brief is listed with a lock icon"},
  "reply": {"prompt": "Paste the Channel ID from step 3", "choices": []},
  "links": [{"label": "Slack help: create a channel",
             "url": "https://slack.com/help/articles/201402297-Create-a-channel"}]
}
```

It returns `{id, deduped, openUrl}`:
- `deduped: true` means an ask with this title is already open. Don't post it again.
- On `isError` with field paths (`steps[2].url: must be http(s)`), fix those fields and call again.
- "Relay isn't running", "mailbox unreachable" or another connection error: tell the
  owner in chat and carry on.

## Fallback without MCP

```bash
relay post Acme --json - <<'EOF'
{"v": 1, "title": "Choose the Acme launch date", "urgency": "whenever",
 "steps": [{"do": "Pick a date for the public launch", "where": "Relay"}],
 "reply": {"prompt": "Which date?", "choices": ["2026-11-02", "2026-11-09", "Later"]}}
EOF
```

It prints `posted <id>` (or `deduped <id>`), then `open <url>` when there is one.
Refused asks print `refused: <error>` and one line per field error on stderr, and exit 1.

## Reading the answer

- Keep working on something that doesn't depend on the answer.
- If your work waits on the answer, start `relay wait <id>` at once as a background
  command (in Claude Code: Bash with `run_in_background: true`). It exits as soon as
  the owner replies or presses Done or Skip, which wakes the session. Act on the reply
  it prints: `[<project>] <title>`, one `  ↳ owner <kind> <at>: <text>` line per answer,
  then `last seq: <n>`. For a second answer on the same ask, run
  `relay wait <id> --after <last seq>`. Exit 3 means no answer within 8 h
  (`--timeout` changes it).
- `relay_status {id}` or `relay status <id>`:
  - `status` is `open`, `done` or `dismissed`; `resolvedBy` (`owner` or `session`)
    says who closed it.
  - `ownerEvents` holds `resolved`, `declined` and `reply`. A picked choice arrives as
    `choice: <option>`.
  - Only **owner** events, or a `(by owner)` status, are the owner's answer.
    `done (by session)` means a session closed it, not the owner.
- The owner may reopen an ask they closed by mistake (owner event `reopened`). Treat
  it as open again, and wait for the next answer with `relay wait <id> --after <last seq>`.
- If the replies hook is set up, answers also show up in your next prompt as
  `Relay: [<id>] <project> · <title> — <done|skipped|reply>: <text>`. The hook shows
  answers to every session's asks: act only on ids you posted.
- `relay_list` (or `relay list`) shows every open ask. Check it before posting, so you
  don't ask twice.
- Don't post the same title again within 24 h. If the ask has changed, change the title.

## Resolving it yourself

If the need goes away or you solve it yourself: `relay done <id> "<what happened>"`,
or `relay skip <id> "<why>"` when it no longer applies.

Mention the ask and its id in chat too. Relay is the owner's queue; chat is the log.
