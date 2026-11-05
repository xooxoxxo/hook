# Instructable format

An ask is a `project` plus an instructable: a JSON object with a title and numbered steps. `project` is required: one line, at most 60 characters.

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
  "verify": {"do": "Reload Slack and look under Channels", "where": "Slack", "expect": "#acme-brief is listed"},
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
| `warning` | ≤ 300, line breaks allowed. An orange caution above all steps. Does not lock steps. Needs Pond 1.6.0 or a This Mac queue advertising `ask-warning`. |
| `urgency` | `now`, `today` (default) or `whenever` |
| `steps` | Required, 1–20 Steps |
| `verify` | Optional. One Step without `substeps` or `question`: a real check in the world, best a command with `expect`. Leave it out for a pure decision or a review ([Hook's own controls](#hooks-own-controls)) |
| `reply` | `prompt` ≤ 300, `choices` 0–6 strings of ≤ 60, or [choices with words](#choices-with-words) |
| `done` | 1–3 of `"steps"`, `"reply"` (needs `reply`) and `"message"`: what must happen before the owner's Done turns on ([Before Done](#before-done)). Needs Pond 1.3.0 |
| `links` | 0–10 `{label ≤ 60, url}` or `{label ≤ 60, path}`. Exactly one of `url` (http(s)) and `path` (a local document, like a Step's `file`) |
| `from` | `{session, host, cwd}`, filled in by the poster |

A **Step** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `do` | Required, ≤ 300, one line: the owner's one action in a few words ([One action](#one-action)), never a value to copy ([Values to copy](#values-to-copy)) |
| `where` | ≤ 60, one line: the app or place |
| `detail` | ≤ 1500, line breaks allowed: longer instructions, wrapped under `do` |
| `code` | ≤ 4000: only the exact text to copy; it wraps |
| `lang` | ≤ 20, such as `bash`, `json` or `text` |
| `expect` | ≤ 300: what the owner should see |
| `url` | An http(s) page for this step |
| `substeps` | 1–10 Steps without `substeps`; not on `verify`. At most 60 steps and sub-steps per instructable |
| `question` | A Question for the owner (below). At most 20 per instructable |
| `blocking` | `true`: the owner can't open later steps until this one is done. Use it only when later steps fail without it, and give the reason in `warning` |
| `warning` | ≤ 300, line breaks allowed: a caution in a box on the step. With `blocking`, the reason the next steps wait |
| `optional` | `true`: a nice-to-have, such as a feedback question. The owner can tick it done without doing or answering it. On a step with `substeps`, every sub-step is optional, and ticking the step finishes it. Never with `blocking` |
| `required` | `true` keeps the owner's Done off until this step is [finished](#before-done). Never with `optional` or inside an optional step. It goes fine with `blocking`: `blocking` is about order, `required` about finishing. Needs Pond 1.3.0 |
| `id` | A stable name for the step ([rules](#validation)). A [correction](agents.md#correcting-an-ask) keeps ids, so ticks and answers follow a step that moves. Needs Pond 1.1.0 |
| `file` | An absolute path on the owner's Mac (`/…` or `~/…`), ≤ 500, one line, no hidden characters. Hook opens the document rendered, usually Markdown. Put long text in a file, never in the ask |

`question`, `blocking`, `warning`, `optional`, `required`, `id` and `file` go on steps and sub-steps, never on `verify`.

A **Question** is a JSON object with these keys:

| Key | Rule |
|---|---|
| `prompt` | Required, ≤ 300, line breaks allowed |
| `choices` | 0–6 distinct strings of ≤ 60, one line each, or [choices with words](#choices-with-words); none or `[]` asks for free text |
| `multi` | `true` allows several picks and needs at least 2 choices |

The owner can answer questions one at a time; each answer is an `answer` event ([Pond protocol](mailbox-protocol.md)). The ask stays open until Done or Skip. Done works with questions unanswered, unless they are [required](#before-done).

## Choices with words

A choice that needs the owner's words is an object (Pond 1.4.0):

```json
{"do": "Pick the rota change", "where": "Hook",
 "question": {"prompt": "How should the night rota change?",
              "choices": ["Keep it", {"label": "Mix", "text": "What should change?"}]}}
```

- `label`: 1–60 characters, one line, distinct in the list. `text`: the placeholder of the field Hook opens under the picked choice, 1–100 characters, one line. Both are required, and no other key is allowed.
- Not in a `multi` question: `steps[0].question.choices[1]: a choice with text can't be in a multi question`.
- The words are optional when the owner sends. A reply arrives as `choice: Mix · <words>` (U+00B7 with a space on each side), or `choice: Mix` without words. A step answer keeps its `picked` and adds `text`: `{"step":"2","id":"s2","picked":["Mix"],"text":"<words>"}`. Sessions read it as `answer 2 (version 1): "Mix · <words>"`. Words are capped at 1000 characters.
- Never ask for words in a label, such as "Mix (reply what)" or "Changes (reply)": the owner would have to type them in Messages. `relay post` and `relay_post` refuse such a label: `reply.choices[1]: "Mix (reply what)" asks for words: make it {"label": "Mix", "text": "…"} (Pond 1.4.0), or say what to write in the prompt`. Rules: `lint_choice_labels` in [`clients/relay_lint.py`](../clients/relay_lint.py).
- On an older Pond or in This Mac mode, `relay post` refuses the object: ``Your Pond (1.3.0) is older than `choices[].text` needs (Pond 1.4.0 or newer). Update the Pond, or use plain string choices and say what to write in the prompt.``

## Long text

On Pond 1.4.0, the owner's messages and problem reports take up to 8000 characters (before: 1000 and 300). A problem report keeps its line breaks. Sessions see each owner text cut at 8000 characters, followed by ` (N more characters: relay status <id> --json)`. `relay status <id> --json` and `relay_status` always carry the whole text.

## Before Done

`required: true` on a step and the ask-level `done` list name what must be finished first. Until then, Hook keeps Done off and marks what's left. The Pond refuses an owner Done (`409 requirements_unmet`), and Telegram shows no Done button.

- **Finished** means: a step without a question is ticked, and a question is answered (a tick isn't enough). A step with sub-steps also needs every sub-step that isn't optional finished. `done: ["steps"]` covers every top-level step that isn't optional. `"reply"` is any owner reply, from Hook or a Telegram text reply. `"message"` is any message the owner sent the session.
- **Skip is never gated**, from Hook or Telegram, and neither is the session's own `relay done`.
- **This Mac mode doesn't take them** in this release. Its queue stays Pond 1.0.0, so `relay post` refuses both keys ("Hook's This Mac queue (Pond 1.0.0) can't take `required` yet.").
- `relay status <id>` prints `Left before Done: step 2, the reply, a message` or `Ready for Done`. `relay status --json` and `relay_status` carry `requirements` (`{left, ready}`, or `null`).

## Values to copy

Every value the owner types or pastes is its own sub-step with `code`, one per form field, never inside `do`. A page to open goes in `url`.

```json
{"do": "Add a reader: Settings › Readers › Add reader", "url": "https://app.example.com/app/", "substeps": [
  {"do": "Kind", "code": "Ollama", "lang": "text"},
  {"do": "Name", "code": "studio", "lang": "text"},
  {"do": "URL", "code": "http://192.0.2.7:11434", "lang": "text"},
  {"do": "Model", "code": "qwen2.5:14b-instruct", "lang": "text"},
  {"do": "Tap Add, then Check now", "expect": "The studio card shows Ready"}
]}
```

Not `{"do": "Tap Add reader. Kind Ollama, Name studio, URL http://192.0.2.7:11434, Model qwen2.5:14b-instruct"}`: the owner can't copy anything out of `do`.

`relay post` and `relay_post` refuse a `do` (step, sub-step or `verify`) that holds a value to copy:

- an http(s) URL, an IPv4 address or host:port
- an absolute or `~/` path
- an `@`-free `key=value`
- a backticked span, or a quoted identifier, path or command
- a token of 12+ characters with letters and digits (and `:` `/` `.` `_` `-`)

A value already in the `code` or `url` of that step or its sub-steps passes. So do versions (`0.11.0`), times, shortcuts (`⌘C`) and UI paths with › or →. The refusal quotes the values: `steps[3].do: "http://192.0.2.7:11434", "qwen2.5:14b-instruct" are values to copy: put each in a sub-step's code (or a URL in url)`. Rules: [`clients/relay_lint.py`](../clients/relay_lint.py); shared test vectors: [`clients/lint-vectors.json`](../clients/lint-vectors.json).

## Hook's own controls

Every step is work in the world. Hook already shows the reply box, the questions and the Done and Skip buttons, so never add a step or a `verify` that only points at them: "Pick an answer below", "Reply with anything that still looks wrong", "Answer the question", "Press Done after answering", "Look at the reply you sent". A decision goes in a step's `question` or in `reply`. `verify` is optional: use it for a real check, best a command with `expect`, and leave it out when nothing in the world changes.

`relay post` and `relay_post` refuse a step or sub-step whose `do` only points at Hook's controls, unless it has `code`, `url`, `file`, a `question` or sub-steps, or its `where` names another app ("Reply to the Slack thread with the link" is real work): `steps[5].do: "Pick an answer below" only points at Hook's own controls: drop the step; the reply box and questions already show`. They refuse a `verify` that only restates the reply or Done the same way: `verify.do: "Look at the reply you sent" only restates the reply or Done: drop verify; keep it only for a real check, like a command with expect`. Rules: `lint_hook_controls` in [`clients/relay_lint.py`](../clients/relay_lint.py), in the same shared vectors.

## One action

A `do` is the owner's one action in a few words: aim for 8 words or fewer, never more than about 60 characters. What a command or a page does goes in `detail`, and what the owner should see goes in `expect`. When the owner really does several things, make separate steps or sub-steps. A short click path is still one action ("Open Settings and click Save", "Click + next to Channels, then Create channel").

Not `{"do": "Install the Leasekey client on the Mac, create the Claude agent's token and add its rules on the server", "code": "cd ~/leasekey-deploy && ./agent.sh"}`: the step runs one script, but the title lists all it does. Write `{"do": "Run the Leasekey agent setup", "code": "cd ~/leasekey-deploy && ./agent.sh", "detail": "It installs the Leasekey client on the Mac, creates the Claude agent's token and adds its rules on the server.", "expect": "It ends with: Next: ./install-host.sh web-1"}`.

`relay post` and `relay_post` refuse a step or sub-step whose `do` names three or more actions, or two in more than 60 characters, and any `do` over 60 characters. An action is a clause (split at a comma, a semicolon, "and" or "then") that starts with a verb such as Install, Create, Add, Open or Click, so "Click Create New App, then From scratch" is one action. `verify` gets only the length check, and a `do` that already holds a value to copy gets that message alone: `steps[0].do: "Install the Leasekey client…" names more than one action: keep do to the owner's one action and move the rest to detail, or split into steps`, `steps[2].do: do is 72 characters: keep it under 60 and move the rest to detail`. Rules: `lint_do_title` in [`clients/relay_lint.py`](../clients/relay_lint.py), in the same shared vectors.

## Validation

- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- `verify` doesn't count toward the 60 steps and sub-steps.
- `optional` must be `true` or `false` (`null` counts as absent). A step can't be both optional and blocking: `steps[0].optional: can't be optional and blocking`. A sub-step of an optional step can't be blocking either: `steps[0].substeps[1].blocking: can't be blocking inside an optional step`.
- `required` must be `true` or `false`. It is refused on `verify`, beside `optional` (`steps[2].required: can't be required and optional`) and inside an optional step (`steps[2].substeps[0].required: can't be required inside an optional step`). It is also refused on a step with nothing to finish (`steps[2].required: has nothing to finish (every sub-step is optional)`).
- `done` must be a list of 1 to 3 distinct known values (`done: must be a list of 1 to 3 of steps, reply, message`, `done[1]: duplicate`). `"reply"` needs a `reply` (`done[0]: reply needs a reply prompt`), and `"steps"` needs a step that isn't optional.
- `relay post`, `relay_post` and `relay amend` catch the last four before sending, and say what to do: `steps[2].required: can't go with optional: drop one of them`, `done: "reply" needs a reply prompt: add reply, or drop it from done`. Rules: `lint_requirements` in [`clients/relay_lint.py`](../clients/relay_lint.py), in the same shared vectors.
- `file` and a link's `path` must be absolute: `steps[0].file: must be an absolute path`. A link needs exactly one of them: `links[0]: needs url or path, not both`.
- `id` must match `[a-z0-9][a-z0-9.-]{0,23}`, be unique in the ask and not look like a step number (`2`, `3.1`): `steps[1].id: duplicate`, `steps[0].id: must not look like a step number`. Give ids on every step and sub-step, or on none, and the Pond names them `s1`, `s2`, `s2.1`.
- A step's errors come in this order: its text keys (`do`, `where`, `code`, `lang`, `expect`, `detail`), `url`, `file`, `blocking`, `optional`, `required`, `warning`, `question`, `substeps`.
- The Pond's errors name field paths only (`steps[2].url: must be http(s)`), never values.
- The JSON Schema is [`schema/instructable.v1.json`](../schema/instructable.v1.json).

### Pond versions

| Key | Needs Pond |
|---|---|
| `question`, `blocking`, `warning`, `optional`, `file`, a link's `path` | 1.0.0 |
| `id` | 1.1.0 |
| `required`, `done` | 1.3.0 |
| a choice object (`choices[].text`) | 1.4.0 |

`relay post`, `relay_post` and `relay amend` ask `GET /version` first, cached for 5 minutes per process. A newer minor or patch Pond never stops a key working ([Pond versions](mailbox-protocol.md#pond-versions)). When the Pond is too old, they refuse, post nothing and exit 1: ``Your Pond (1.0.0) is older than `id` needs (Pond 1.1.0 or newer). Update the Pond, or leave the key out.`` In This Mac mode the app is the server, so the refusal is "Hook's This Mac queue (Pond 1.0.0) can't take `id` yet."

A Pond without `/version` counts as protocol 1, too old for any of these keys. An answer with neither a semver `version` nor an integer `protocol` is unknown: Hook posts the instructable and the Pond validates it. An instructable without these keys posts with no extra call.

## Secrets are refused

Strings that look like secrets are rejected: `sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`, `github_pat_`, `AKIA…` and private-key blocks. So are hidden characters that could disguise them. Ask the owner to store secrets in the Keychain instead.
