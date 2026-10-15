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
    {"do": "Check Node", "where": "Terminal", "code": "node --version", "lang": "bash", "expect": "v22.13 or higher"}
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
| `verify` | One Step |
| `reply` | `prompt` ≤ 300, `choices` 0–6 strings of ≤ 60 |
| `links` | 0–10 `{label ≤ 60, url}` |
| `from` | `{session, host, cwd}`, filled in by the poster |

A **Step** is `{do (required, ≤ 300), where ≤ 60, code ≤ 4000, lang ≤ 20, expect ≤ 300, url}`.

`project` is required: one line, at most 60 characters.

## Validation

- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- Errors name field paths only (`steps[2].url: must be http(s)`), never values.
- The JSON Schema is [`schema/instructable.v1.json`](../schema/instructable.v1.json).

## Secrets are refused

Strings that look like secrets (`sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`, `github_pat_`, `AKIA…`, private-key blocks) are rejected, as are hidden characters that could disguise them. Ask the owner to store secrets in the Keychain instead.
