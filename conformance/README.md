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
- `pond`: the first Pond version whose behaviour the file covers. A client that talks to an older Pond skips it.
- `feature`: a short name for what the file covers.
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

Phone transcripts are added in a later change.
