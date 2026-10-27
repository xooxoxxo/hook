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
    {"do": "Pick the deploy target", "where": "Hook", "question": {"prompt": "Which environment?", "choices": ["Staging", "Prod"]}},
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
| `links` | 0–10 `{label ≤ 60, url}` or `{label ≤ 60, path}`: exactly one of `url` (http(s)) and `path` (a local document, like a Step's `file`) |
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
| `blocking` | `true` marks a step the next steps can't start without: the owner can't open later steps until it is done. On steps and sub-steps, not on `verify`. Use it only when later steps fail without it, and give the reason in `warning` |
| `warning` | Up to 300 chars, line breaks allowed: a caution shown in a box on the step. With `blocking`, the reason the next steps wait. On steps and sub-steps, not on `verify` |
| `optional` | `true` marks a step the owner may finish without doing or answering it, e.g. a feedback question or a nice-to-have: they can tick it done, and an optional question counts as done once ticked or answered. On a step with `substeps` it makes every sub-step optional, so ticking the step finishes it. On steps and sub-steps, not on `verify`, and never together with `blocking` |
| `file` | An absolute path on the owner's Mac (`/…` or `~/…`), ≤ 500, one line, no hidden characters: a document to read, usually Markdown, which Hook opens rendered. On steps and sub-steps, not on `verify`. Write long text to a file and point to it here; never paste a whole document into an ask |

A **Question** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `prompt` | Required, ≤ 300, line breaks allowed |
| `choices` | 0–6 distinct strings of ≤ 60, one line each; none or `[]` asks for free text |
| `multi` | `true` allows several picks and needs at least 2 choices |

The owner answers questions one step at a time and can send some answers before the rest. The ask stays open until Done or Skip, and Done is allowed with questions unanswered. An `optional` question can also be ticked done without an answer. Each answer is an `answer` event (see [Pond protocol](mailbox-protocol.md)).

`project` is required: one line, at most 60 characters.

## Validation

- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- Steps plus sub-steps total at most 60 (`verify` not counted); `steps` stays 1–20.
- At most 20 steps and sub-steps carry a `question`.
- `blocking`, `warning` and `optional` are refused on `verify`, like `question`.
- `optional` must be `true` or `false` (`null` counts as absent), and a step can't be both optional and blocking: `steps[0].optional: can't be optional and blocking`. A sub-step of an optional step can't be blocking either: `steps[0].substeps[1].blocking: can't be blocking inside an optional step`.
- `file` and a link's `path` must be absolute: `steps[0].file: must be an absolute path`. A link needs exactly one of `url` and `path`: `links[0]: needs url or path, not both`. `file` is refused on `verify`.
- Protocol level: `question` needs a Pond or app speaking protocol 2, `blocking` and `warning` need 3, `optional`, `file` and a link's `path` need 4. `relay post` and `relay_post` ask `GET /version` first (cached for 5 minutes per process) and refuse before posting when the reported level is too low: "This Pond speaks protocol M; `blocking` needs 3. Ask the owner to update the Pond (Hook › Update Pond…)." In This Mac mode the app is the server, so the refusal is "Hook speaks protocol M; `blocking` needs 3. Update Hook (Check for Updates…)." A Pond without `/version`, or one whose answer has no integer `protocol`, is unknown: the instructable is posted and the Pond validates it. An instructable without these keys posts with no extra call.
- A step's errors come in this order: its text keys (`do`, `where`, `code`, `lang`, `expect`, `detail`), `url`, `file`, `blocking`, `optional`, `warning`, `question`, `substeps`.
- Errors name field paths only (`steps[2].url: must be http(s)`), never values.
- The JSON Schema is [`schema/instructable.v1.json`](../schema/instructable.v1.json).

## Secrets are refused

Strings that look like secrets (`sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`, `github_pat_`, `AKIA…`, private-key blocks) are rejected, as are hidden characters that could disguise them. Ask the owner to store secrets in the Keychain instead.
