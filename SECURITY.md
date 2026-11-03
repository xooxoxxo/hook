# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub private vulnerability
reporting: open the repo's **Security** tab and choose **Report a vulnerability**.
Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and the Hook version (`relay --version`).

## Scope

- The app's loopback API on `127.0.0.1`, including the Host, Origin and server-proof
  checks.
- Token handling: the local token, the Pond token file and file permissions.
- The clients: the `relay` CLI and the MCP server.
- The installer, `scripts/install.sh`.
- The review of corrected asks: revision hashes, pins, the lock and the sealed review records.
- The owner key: enrollment, where the key is sent, and the Keychain items.
- Crash reports: the activity log's redaction, what a report contains, and both send paths.

The design is described in [docs/security.md](docs/security.md).

## Threat model

Hook shows you instructions written by agents and relayed by a server, and some of them are commands you will paste into a terminal. It is built to keep three parties from making you run, open or approve something you didn't see:

- **A session or an agent.** Anything that can post an ask can write anything into it. The validator refuses secrets and hidden characters, text shows hidden characters as `⟨U+XXXX⟩`, links show their real host, and files open only as the documents listed below. A session can correct only an ask it posted (it holds the ask's edit key), and every correction waits for your review: until you accept it, the ask is locked, and a change to a command, link or file needs Touch ID or your password. "Look closer" flags new hosts, `sudo`, pipes into a shell, decoding, `eval` and non-ASCII code; those checks are incomplete, and no flag never means safe. A session can't answer as you once the owner key is required.
- **The Pond, or anyone between Hook and it.** Hook treats what the Pond serves as untrusted. Every revision is hashed and chained to the one before; Hook checks the whole chain, remembers every hash it has seen, and refuses a history that changed, lost a revision or went back to an older one: the ask locks until you trust the Pond's history again. Done and answers name the revision you saw, so the Pond can't apply them to another; Skip names none, so it works on any version. The owner key travels only over https and the Pond stores only its hash.
- **A web page or another user on this Mac.** The loopback API checks Host and Origin, sends no CORS headers, and clients check the server proof before sending the token. Files are private to your account.

**Not in scope: processes already running as you.** A process with your privileges can read Hook's token and queue, drive the UI, write Hook's data files and, with your permission, read or plant Keychain items. Hook makes such an attack harder where it can (see "Keychain items"), but it can't stop it. Neither can it protect against a Pond host you don't control: the Pond sees every ask it holds.

## Opening files from asks

An ask can name a file (a step's `file`, a link's `path`). Hook touches it only when you press
a button, and then:

- **It opens only these types**, by exact type identifier: Markdown, plain text, CSV, JSON, logs
  (`.log`), YAML, PDF, PNG, JPEG, HEIC, GIF, TIFF, MP3, MPEG-4 audio (`.m4a`) and video, QuickTime,
  Word, Excel and PowerPoint documents and shows (`.doc`, `.docx`, `.xls`, `.xlsx`, `.ppt`,
  `.pptx`, `.pps`, `.ppsx`), and Pages, Numbers and Keynote. Images in the viewer load only as
  PNG, JPEG, GIF or HEIC, from the document's folder.
- **It refuses everything else**: apps, scripts, installers, disk images, folders, HTML, XML,
  SVG, WebP, RTF, calendar, contact and location files, Office macros, add-ins and templates, and
  any file with an execute bit. It never opens a file in a terminal, Script Editor, Automator,
  Python Launcher, or an app Script Editor or Automator saved.
- **Local disks only.** Network paths (`/net`, `/Network`, `/home`, in any spelling), hidden
  roots (`/.vol`, `/.nofollow`) and a first folder name that isn't plain ASCII are never touched.
  Hook walks the path one folder at a time by descriptor, never following a link it hasn't
  checked, and stops before any step the mount table lists as a network or non-local mount, or
  that isn't on APFS, HFS+, FAT, exFAT or `/dev`.

**Known limit.** To open a file in another app, Hook hands that app a path. Right before, Hook
checks the path still names the file it checked, but a process already running as you could
swap the file in the instant after that last check. Hook's own viewer isn't affected: it shows
the bytes it read from the checked file's descriptor.

## Keychain items

Hook keeps two secrets in the login Keychain: the review seal ("Hook review seal"), which seals
the review records in `reviews.json`, and this Mac's owner key for each Pond ("Hook owner key").

- **A fresh item for each new secret.** When Hook makes a secret (the seal's first key, Reset
  Review Records…, each owner key setup) it deletes whatever item has that name and adds a fresh
  one with an access list that names only Hook's path; an item that appears in between fails the
  add. Later writes (an owner key's status) update the item Hook just found and checked, in place:
  its access list must name only Hook's path, and the owner key record must carry its mark. Each
  read and update works on that one item, never a second lookup by name.
- **What the markers check.** An access list names an app by its path, which another app can
  name too, so it doesn't prove who made an item. Hook adds two checks. `reviews.json` stores an
  HMAC of a fixed string under the seal key; a seal item whose key doesn't give that value is
  never used. Each owner key record carries an HMAC of the Pond and the key under the seal; a
  record without one that verifies is never sent. These prove that whoever wrote the item knew
  the seal key (or wrote `reviews.json` to match it), not that Hook made it. A seal item that is
  there while `reviews.json` or its marker is missing is not replaced: corrected asks stay locked
  ("review records unreadable") and nothing is written. Hook makes a seal on its own only when
  there is no item at all.
- **Losing `reviews.json` resets the records and the owner keys.** With the file gone, the only
  way out of the lock is Reset Review Records… in that Notice, which asks for Touch ID (or your
  password) and makes a new seal. Every acceptance and rollback pin sealed under the old one is
  gone, so each corrected ask needs a review again, and each owner key, marked under the old
  seal, reads as not set up until you set it up again in Settings › Queue.
- **The owner key travels only over https** (or plain http to this Mac itself), and only to the
  scheme it was set up on: a Pond URL switched to http gets no key.

**Known limit: ad-hoc signing.** Builds are ad-hoc signed today, so Hook can't use the data
protection Keychain, where only an app signed by the same team can make or read an item in Hook's
access group. Until releases are signed with a Developer ID:

- A process already running as you can read any Keychain item macOS lets it read (macOS asks you
  first). Allow Hook only when the prompt names Hook and you just started it. One that reads the
  seal can mark review records and owner key records of its own, and one that reads an owner key
  can act as you on the Pond.
- A process that rewrites `reviews.json` as well as the Keychain items can plant a seal with a
  matching marker, and with it accepted records and owner key records. The checks above stop an
  item planted on its own, not this.
- An update that changes Hook's signature may make macOS ask again for Hook's own items.

Developer ID releases will move both secrets to the data protection Keychain.

## Crash reports and the activity log

Hook's activity log is built from typed events (launch and quit, screens, actions by name,
the source and Pond version, errors), so ask ids, titles, steps, replies, notes, tokens, the
owner key and the Pond's address can't reach it. An error's message is redacted before it is
written, and a crash report runs the redactor a second time before it is shown or sent.

A report holds only allowed fields: the Hook and macOS versions, the CPU type, the exception,
signal and termination reason, Hook's own frames by symbol, the source and Pond version, and
the last 40 log lines. The macOS crash file (`.ips`) is never attached. The sheet shows exactly
what a send delivers, and nothing leaves the Mac without your action, apart from Send
Automatically to your own Pond:

- **GitHub.** Before you submit, GitHub sees only one unauthenticated search for the crash's
  signature, a 12-character hash, from your IP address. The issue itself is a prefilled page in
  your browser, and public once you submit it.
- **My Pond.** The report goes to your own Pond, signed with your owner key, and from there to no
  one else.

No crash-reporting SDK is linked, and Hook has no package dependencies: the slot for one does
nothing. An SDK added later comes under a 5-day release-age gate (no version published less than
5 days before it is added or updated), starts only with your consent and never while Crash
reports is Off, and gets its own note here, saying what it sends and where, before it ships. The details are in [docs/privacy.md](docs/privacy.md).

## Residual risks

- **Edit keys sit in files.** A session's edit key is in a `0600` file in
  `~/.local/state/relay/edit-keys`. Any process running as you on that Mac can use it to correct
  the ask. That is why every correction is reviewed in Hook, never applied silently.
- **Your review is the check.** Hook shows each change, every reason the session gave and the
  flags it found, but it can't tell a harmful command from a useful one. Read the diff before
  Use Version N, and don't accept a change you didn't expect.
- **Telegram approves the owner key.** Approve a setup request only when it shows the code Hook
  shows on this Mac. Someone who controls your Telegram account and the Pond's token could
  approve a key of their own.
- **Without "Require the owner key"** a client with the Pond token can still answer, press Done
  and reopen as you. Clients show who closed an ask (`by owner` or `by session`). Accepting a
  correction always needs the owner key.
- **A Pond older than 1.1.0** serves no revisions, so Hook has no history to check. An ask this
  Mac saw corrected stays locked when such a Pond serves it; any other ask shows as posted.
- **A plain-http Pond.** The Pond token and every ask travel with each request. Use https unless
  the Pond is only on a private, encrypted network; the owner key is never sent over plain http
  to another machine.
- **The file-open window** described under "Opening files from asks".
- **Redaction is pattern-based.** It catches your home folder, user name, hosts, addresses and
  common token shapes, not every secret. An error message from another library could still carry
  something it misses. Read the report in the sheet before you submit it to GitHub.

## Supported versions

Fixes go into the latest release.
