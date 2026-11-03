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
| `do` | Required, ≤ 300, one line: the action, never a value to copy ([below](#values-to-copy)) |
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
| `id` | A stable name for the step: `a-z` and `0-9`, then also `.` and `-`, at most 24 characters, not a step number (`2`, `3.1`), unique in the ask. On steps and sub-steps, not on `verify`; give one on every step and sub-step or on none (the Pond then names them `s1`, `s2`, `s2.1`). A [correction](claude-code.md#correcting-an-ask) keeps them, so ticks and answers follow a step that moves. Needs Pond 1.1.0 |
| `file` | An absolute path on the owner's Mac (`/…` or `~/…`), ≤ 500, one line, no hidden characters: a document to read, usually Markdown, which Hook opens rendered. On steps and sub-steps, not on `verify`. Write long text to a file and point to it here; never paste a whole document into an ask |

A **Question** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `prompt` | Required, ≤ 300, line breaks allowed |
| `choices` | 0–6 distinct strings of ≤ 60, one line each; none or `[]` asks for free text |
| `multi` | `true` allows several picks and needs at least 2 choices |

The owner answers questions one step at a time and can send some answers before the rest. The ask stays open until Done or Skip, and Done is allowed with questions unanswered. An `optional` question can also be ticked done without an answer. Each answer is an `answer` event (see [Pond protocol](mailbox-protocol.md)).

`project` is required: one line, at most 60 characters.

## Values to copy

Every value the owner types or pastes is its own sub-step with `code`: one per form field, never inside `do`. A page to open goes in `url`.

```json
{"do": "Add a reader: Settings › Readers › Add reader", "url": "https://app.example.com/app/", "substeps": [
  {"do": "Kind", "code": "Ollama", "lang": "text"},
  {"do": "Name", "code": "studio", "lang": "text"},
  {"do": "URL", "code": "http://192.0.2.7:11434", "lang": "text"},
  {"do": "Model", "code": "qwen2.5:14b-instruct", "lang": "text"},
  {"do": "Tap Add, then Check now", "expect": "The studio card shows Ready"}
]}
```

Not `{"do": "Tap Add reader. Kind Ollama, Name studio, URL http://192.0.2.7:11434, Model qwen2.5:14b-instruct"}`: nothing in `do` can be copied.

`relay post` and `relay_post` refuse, before posting, a `do` (step, sub-step or `verify`) that holds an http(s) URL, an IPv4 address or host:port, an absolute or `~/` path, an `@`-free `key=value`, a backticked span, a quoted identifier, path or command, or a token of 12+ characters with letters and digits (and `:` `/` `.` `_` `-`). A value already in the `code` or `url` of that step or its sub-steps passes, as do versions (`0.11.0`), times, shortcuts (`⌘C`) and UI paths with › or →. The refusal quotes the values: `steps[3].do: "http://192.0.2.7:11434", "qwen2.5:14b-instruct" are values to copy: put each in a sub-step's code (or a URL in url)`. Rules: [`clients/relay_lint.py`](../clients/relay_lint.py); shared test vectors: [`clients/lint-vectors.json`](../clients/lint-vectors.json).

## Validation

- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- Steps plus sub-steps total at most 60 (`verify` not counted); `steps` stays 1–20.
- At most 20 steps and sub-steps carry a `question`.
- `blocking`, `warning` and `optional` are refused on `verify`, like `question`.
- `optional` must be `true` or `false` (`null` counts as absent), and a step can't be both optional and blocking: `steps[0].optional: can't be optional and blocking`. A sub-step of an optional step can't be blocking either: `steps[0].substeps[1].blocking: can't be blocking inside an optional step`.
- `file` and a link's `path` must be absolute: `steps[0].file: must be an absolute path`. A link needs exactly one of `url` and `path`: `links[0]: needs url or path, not both`. `file` is refused on `verify`.
- `id` must match `[a-z0-9][a-z0-9.-]{0,23}` and not read as a step number, once per ask, on every step and sub-step or none: `steps[1].id: duplicate`, `steps[0].id: must not look like a step number`.
- Pond version: `question`, `blocking`, `warning`, `optional`, `file` and a link's `path` need Pond 1.0.0 or newer, and `id` needs 1.1.0 ([Pond versions](mailbox-protocol.md#pond-versions)). `relay post` and `relay_post` ask `GET /version` first (cached for 5 minutes per process) and refuse before posting when the Pond is older: "Your Pond (1.0.0) is older than `id` needs (Pond 1.1.0 or newer). Update the Pond, or leave the key out." In This Mac mode the app is the server, so the refusal is "Hook's This Mac queue (Pond 1.0.0) can't take `id` yet." A Pond without `/version` counts as protocol 1, too old for any of them. One whose answer has neither a semver `version` nor an integer `protocol` is unknown: the instructable is posted and the Pond validates it. An instructable without these keys posts with no extra call.
- A step's errors come in this order: its text keys (`do`, `where`, `code`, `lang`, `expect`, `detail`), `url`, `file`, `blocking`, `optional`, `warning`, `question`, `substeps`.
- The Pond's errors name field paths only (`steps[2].url: must be http(s)`), never values.
- The JSON Schema is [`schema/instructable.v1.json`](../schema/instructable.v1.json).

## Secrets are refused

Strings that look like secrets (`sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`, `github_pat_`, `AKIA…`, private-key blocks) are rejected, as are hidden characters that could disguise them. Ask the owner to store secrets in the Keychain instead.
