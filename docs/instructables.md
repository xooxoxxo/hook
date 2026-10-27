# Instructable format

An ask is a `project` plus an instructable: a JSON object with a title and numbered steps.

```json
{
  "v": 1,
  "title": "Create a Slack channel for Acme",
  "why": "The daily brief needs a destination",
  "urgency": "today",
  "steps": [
    {"do": "Open Slack → + next to Channels → Create channel", "where": "Slack"},
    {"do": "Check Node", "where": "Terminal", "code": "node --version", "lang": "bash", "expect": "v22.13 or higher"},
    {"do": "Pick the deploy target", "where": "Relay", "question": {"prompt": "Which environment?", "choices": ["Staging", "Prod"]}},
    {"do": "Create the Slack app", "where": "Browser", "substeps": [
      {"do": "Click Create New App, then From scratch", "url": "https://api.slack.com/apps"},
      {"do": "Name it Acme Brief and pick the Acme workspace"}
    ]}
  ],
  "verify": {"do": "Confirm it worked", "expect": "The channel is listed"},
  "reply": {"prompt": "Which channel?", "choices": ["#acme-brief", "#acme-team"]},
  "links": [{"label": "Spec", "url": "https://example.com/spec"}]
}
```

## Keys

| Key | Rule |
|---|---|
| `v` | `1` |
| `title` | Required, ≤ 120 chars, imperative; the 24 h dedupe key |
| `why` | ≤ 300 |
| `urgency` | `now`, `today` (default) or `whenever` |
| `steps` | Required, 1–20 Steps |
| `verify` | One Step without `substeps` or `question` |
| `reply` | `prompt` ≤ 300, `choices` 0–6 strings of ≤ 60 |
| `links` | 0–10 `{label ≤ 60, url}` |
| `from` | `{session, host, cwd}`, filled in by the poster |

A **Step** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `do` | Required, ≤ 300, one line: the action |
| `where` | ≤ 60, one line: the app or place |
| `detail` | ≤ 1500, line breaks allowed: longer instructions, shown as wrapped text under `do` |
| `code` | ≤ 4000: only the exact text to copy; it wraps |
| `lang` | ≤ 20, e.g. `bash`, `json`, `text` |
| `expect` | ≤ 300: what the owner should see |
| `url` | An http(s) page for this step |
| `substeps` | 1–10 Steps without `substeps`; not on `verify`; at most 60 steps and sub-steps per instructable |
| `question` | A Question for the owner (below); on steps and sub-steps, not on `verify`; at most 20 per instructable |

A **Question** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `prompt` | Required, ≤ 300, line breaks allowed |
| `choices` | 0–6 distinct strings of ≤ 60, one line each; none or `[]` asks for free text |
| `multi` | `true` allows several picks and needs at least 2 choices |

The owner answers questions one step at a time and can send some answers before the rest. The ask stays open until Done or Skip, and Done is allowed with questions unanswered. Each answer is an `answer` event (see [Mailbox protocol](mailbox-protocol.md)).

`project` is required: one line, at most 60 characters.

## Validation

- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- Steps plus sub-steps total at most 60 (`verify` not counted); `steps` stays 1–20.
- At most 20 steps and sub-steps carry a `question`.
- Errors name field paths only (`steps[2].url: must be http(s)`), never values.
- The JSON Schema is [`schema/instructable.v1.json`](../schema/instructable.v1.json).

## Secrets are refused

Strings that look like secrets (`sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`, `github_pat_`, `AKIA…`, private-key blocks) are rejected, as are hidden characters that could disguise them. Ask the owner to store secrets in the Keychain instead.
