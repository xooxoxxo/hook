# Conformance suite

One set of JSON test vectors that every Hook implementation runs: the Swift core in this repo, other client cores, and the Pond server. If two implementations pass the same vectors, they agree on the wire format, the instructable rules and the revision hashes.

Every vector is synthetic. The asks, names, keys, hashes and paths in them are made up for the tests. None comes from a real queue. Examples use `https://pond.example.test`.

## Layout

- `data/`: pure data rules. An input and the expected result: validation errors, cleaned output, hashes, version ranges.
- `wire/`: transcripts recorded from the Pond over loopback. A request and the exact response.
- `manifest.json`: lists every file, who runs it, and where copies of it live.

The files in this folder are the canonical ones. Some are also copied elsewhere in the repo (for example `Tests/RelayCoreTests/Fixtures/`, which SwiftPM bundles as test resources). Change the file here, copy it over each path in its `copies`, and run:

```bash
python3 scripts/check-conformance.py
```

It exits 1 and names the file when a copy differs, when a file here is not in the manifest, or when a manifest path is missing. CI runs it.

## Roles

A role says what an implementation does with a file's cases.

- `reader`: reads what the Pond serves (items, revisions, versions) and must reach the expected result.
- `actor`: acts as the owner (answers, ticks, enrolment) and must send exactly the expected request.
- `writer`: builds or checks an instructable before it is posted, as the CLI and MCP server do.
- `server`: the Pond. It must give the expected response.

An implementation runs every file, and every case, whose roles include one it plays.

## Manifest

```json
{"suite": 1, "files": [
  {"path": "data/revision-vectors.json", "pond": "1.1.0", "feature": "corrections",
   "roles": ["reader", "actor", "writer", "server"],
   "kinds": {"hash": ["reader"], "enrollCode": ["actor"], "assign": ["server"]},
   "copies": ["Tests/RelayCoreTests/Fixtures/revision-vectors.json"]}
]}
```

- `suite`: the manifest's format version.
- `path`: the file, relative to this folder.
- `pond`: the first Pond version whose behaviour the file covers. A client that talks to an older Pond skips it. A file's own `pond` header names the Pond it was recorded on, which can be newer than this value; a client uses the manifest's `pond` to decide whether to run the file.
- `feature`: a short name for what the file covers. Where a file covers a named Pond feature, `feature` is that feature's name exactly as the Pond and the clients spell it (`corrections`, `messages`, `requirements`, `longText`, `sharedProgress`, `bugs`, `answers`, `blocking`, `optional`). Other files use one plain lowercase word.
- `roles`: the roles that run the file.
- `kinds`: only on a file whose cases carry a `kind` field with different roles. It maps each `kind` to its roles. Every `kind` in the file must be listed.
- `copies`: other paths in this repo that must hold the same bytes. Empty when there are none.

A case may carry `"clients": ["android"]`. Then only the named clients run it, and the others skip it.

## Transcript format

Each case in a `wire/` file is:

```
{name, note, request: {method, path, ownerKey, protocol, body}, response: {status, body}, binds?}
```

- `ownerKey` true sends an approved `X-Hook-Owner-Key`.
- `protocol` is the `X-Hook-Protocol` sent, or null for none (an older client).
- `binds` names a string the response carries, such as `{"ask1": "item.id", "hash1": "revision.hash"}`. Later paths and bodies use it as `{ask1}` or `{hash1}`.
- In responses every bound string is its `{name}` and every ISO-8601 timestamp is `{time}`. Everything else is exactly what the Pond answers.

Each wire file repeats this in its own `format` key.

## Phone transcripts

`wire/phone-setup-vectors.json`, `wire/phone-acts-vectors.json` and `wire/phone-errors-vectors.json` record what a phone client does as the owner. The cases in each file run in order against one fresh Pond. Each case is:

```
{name, note, act: {kind, args}, request: {method, path, ownerKey, token?, protocol, body}, response: {status, body}, outcome, binds?}
```

`act` is what the phone was asked to do. `request` is exactly what it must send for that act. `args` holds exactly the keys below, no others. Ids are the transcript's own placeholders (`{ask1}`, `{enroll1}`), as in request paths.

| kind | args | request it must produce |
|---|---|---|
| `version` | `{}` | `GET /version` |
| `enroll` | `{"keyHash": "<64 hex>", "label": "Android"}` | `POST /owner/enroll` body `{keyHash, label}`, no owner key header |
| `enrollment` | `{"id": "{enroll1}"}` | `GET /owner/enroll/{enroll1}`, no owner key header |
| `ownerStatus` | `{}` | `GET /owner`, owner key header when the client has an approved key |
| `list` | `{}` | `GET /asks?status=open&days=36500` |
| `detail` | `{"id": "{ask1}"}` | `GET /asks/{ask1}` |
| `progress` | `{"id", "tick": [..], "untick": [..], "rev": n or null, "hash": "…" or null}` | `POST /asks/{id}/progress` body `{tick, untick}` plus `rev`, `hash` when not null |
| `answers` | `{"id", "answers": [..], "rev", "hash"}` | `POST /asks/{id}/answers` body `{answers}` plus `rev`, `hash` when not null |
| `reply` | `{"id", "text"}` | `POST /asks/{id}/reply` body `{text}` |
| `message` | `{"id", "text"}` | `POST /asks/{id}/reply` body `{text, "kind": "message"}` |
| `done` | `{"id", "rev", "hash"}` | `POST /asks/{id}/resolve` body `{"verdict": "done", "actor": "owner"}` plus `rev`, `hash` when not null |
| `skip` | `{"id"}` | `POST /asks/{id}/resolve` body `{"verdict": "declined", "actor": "owner"}`, never `rev` or `hash` |

The request fields:

- `method`, and `path` with the query string when the route has one.
- `ownerKey`: `true` sends the approved `X-Hook-Owner-Key`, `false` sends none, `"unknown"` sends a key the Pond never approved.
- `token`: `"ok"` or `"wrong"`. `"wrong"` sends a wrong Pond token. Absent means ok.
- `protocol`: the `X-Hook-Protocol` sent. Always 6.
- `body`: the JSON body. `rev` and `hash` in a body and in `act.args` are the real values the Pond accepts.

`outcome` is what the client must make of the response:

| response | outcome |
|---|---|
| any 2xx | `ok` |
| 401 | `unauthorized` |
| 404 | `notFound` |
| 403 "owner key required" | `ownerKeyRequired` |
| 403 "unknown owner key" | `ownerKeyRefused` |
| 409 "ask was corrected" | `corrected` |
| 409 "requirements_unmet" | `requirementsUnmet` |
| 409 "ask is closed" | `askClosed` |
| 409 "too many messages" | `tooManyMessages` |
| any other 4xx | `invalid` |

`binds` works as in other transcripts, and a number in its path indexes a list (`{"ask1": "items.0.id"}`). In responses every bound id is its `{name}` and every timestamp is `{time}`, except a revision's `at`: it stays as recorded, because the revision hash covers it.

## History, progress and strict JSON

These three `data/` files hold cases a reader checks against what the Pond serves. Each file repeats its case shape in its own `format` key.

`data/history-vectors.json`: each case is `{name, note, detail: {item, events, revisions}, pins, expect: {ok, problem?, current?: {rev, hash}, acceptedOnPond?}}`. `detail` is `GET /asks/{id}` as the Pond serves it to protocol 6. `pins` maps a revision number to a hash the client saw before. The client checks the whole revision history: every revision from 1 to the newest, each hash, each link to the previous one, each body, the fixed fields (title, urgency, sender), and then the pins. A tampered case breaks exactly one of these, and `problem` names it: `badHash:<rev>`, `badChain:<rev>`, `unreadable:<rev>`, `missing`, `fixedFieldChanged:<rev>` or `rolledBack`. A passing case gives the current revision and `acceptedOnPond`.

`data/progress-vectors.json`: each case is `{name, note, detail, ticked}`. `ticked` is the sorted list of steps that count as ticked, folded from the item's progress and owner events against the accepted revision (or the posted instructable when there are no revisions). Some cases add or edit an event the Pond never serves, to test that a client filters it out; their note says so.

`data/strictjson-vectors.json`: each case is `{name, note, text | hex, parses, body, problem?, pond?}`. `text` is the exact UTF-8 text, or `hex` the raw bytes when they are not UTF-8. `parses` says whether a strict JSON parser accepts it: a key named twice in one object, with keys compared after unescaping (for example `"a"` and `"\u0061"`), and a lone surrogate escape, are refused. `body` says whether it is a valid revision body: strict JSON, a top-level object and a valid instructable. When `body` is false, `problem` is `duplicateKey` for otherwise valid JSON that names a key twice, else `invalid`. `pond`, where present, is the Pond's own answer where it differs from the protocol document.

## Vectors the Swift core is the reference for

Six `data/` files cover logic that lives only in the clients. Their inputs are written by hand. Their expectations are what the Swift core answers, recorded by `Tests/RelayCoreTests/ConformanceTests.swift`: `HOOK_CONFORMANCE_RECORD=1 swift test --filter ConformanceTests` writes them into the files, and without the variable the same test fails on any difference. A recorded value is read against the source before it is committed. Each file repeats its case shape in its own `format` key. Hidden characters in these files are written as JSON `\u` escapes.

`data/pairing-vectors.json`: each case is `{name, note, payload | pad, expect: {ok, failure?, url?, context?, sourceKey?}}`. `payload` is a setup code's JSON text as pasted or scanned. `pad: {bytes: N}` stands for the payload `{"v":1,"url":"https://pond.example.test","token":"synthetic-token-for-tests","context":""}` with `x` added inside the empty `context` string until the whole payload is exactly N UTF-8 bytes; its `expect` leaves out `context` and `sourceKey`, which hold the padding. A good code gives the canonical `url` (https, lowercase host, no port 443, no trailing slash), the `context` and the `sourceKey`. A refused one gives `failure`: `tooLarge`, `malformed`, `version`, `destination` or `credentials`. Every token is `synthetic-token-for-tests`, and no `expect` holds a token.

`data/reviewgate-vectors.json`: the header holds two instructables, `first` and `other`. Each case is `{name, note, record, history, pond, served, expect: {state, locked, shown?, problem?, action}}`. `record` is the device's review record (`accepted`, `seen`, `pins`, and `firstBody` naming the header body whose hash it keeps), or null. `history` is `{kind: "none"}`, `{kind: "ok", stamps, current, acceptedOnPond}` or `{kind: "problem", problem}`, with the problem names of `history-vectors.json`. `pond` is the Pond's version, `"protocol <n>"` for an old Pond, or null before the version check. `served` names the header body the Pond served without revisions. `state` is `legacy`, `current`, `pending` (with the rev `shown`, or null) or `historyChanged` (with its `problem`); `action` is `review`, `trustHistory` or null. Hashes are short synthetic strings: the gate compares them and never recomputes one.

`data/flow-vectors.json`: each case is `{name, note, instructable, events, ticks, expect: {current, done, total, tickable, locked, left, ready, delta?}}`. The instructable is an open ask's payload, `events` its events (`{seq, kind, actor, text?, rev?}`) and `ticks` the device's ticked paths. `expect` gives the current step, the "N of M" count, the paths a tick applies to, the paths a blocking step locks, and what Done still waits for (`left`, `ready`). Where a case gives `delta: {before, after}`, the expectation adds the shared-progress identities ticked and unticked between those paths: a step's id, `@verify`, or `@legacy:<path>` for a step without one.

`data/lookcloser-vectors.json`: each case is `{name, note, old?, new, cwd?, flags: [{kind, location, text}]}`: the review's Look closer flags for what `new` added or changed since `old`, or for all of `new` on a first view. `kind` is `pipeToShell`, `sudo`, `rmRf`, `decode`, `eval`, `nonASCII`, `newHost` or `absolutePathOutsideCwd`. An empty list is the no-match result, which the review shows as "No pattern matched. These checks are incomplete."

`data/stub-vectors.json`: each case is `{name, note, instructable, clients?, expect: {stub, reason?}}`. `stub` true means the client shows the ask only as an update stub, with Skip. `reason` is `pondStub` (the Pond's own stub, recognised by its exact `why` and single step), `unknownKey:<path>` (the first key in document order the client doesn't know, such as `steps[2].substeps[0].shell`) or `unknownDone:<value>`. The known keys are:

- ask: `v title why warning urgency steps verify reply done links from`
- step, sub-step and verify: `do where detail code lang expect url substeps question blocking warning optional required id file`
- question: `prompt choices multi`; choice object: `label text`
- reply: `prompt choices`; link: `label url path`; from: `session host cwd`
- `done` values: `steps reply message`

The first unknown key in document order decides. Its path names objects by key and list items by 0-based index, joined by dots: `shell`, `steps[2].shell`, `steps[0].question.choices[1].tone`, `from.pid`. Unknown keys are checked before unknown `done` values, wherever each appears.

The Swift core has no unknown-key check yet, so those cases, and the cases there only to contrast with them, carry `"clients": ["android"]` and a hand-written `expect`.

`data/display-vectors.json`: each case is `{name, kind, …}`, with the fields of its kind: `reveal`, `revealLine` and `copyText` (hidden characters shown as `⟨U+XXXX⟩`), `linkTitle` and `stepTitle` (how a link and a step URL are titled), `replyWire` and `replyParse` (a choice reply's text and how it is read back), `counter` (the length counter and its trim line), `deepLink` (the ask a `hook://` URL opens) and `sourceKey` (the namespace for a Pond's per-source state on a device). The file's `format` key gives each kind's fields.
