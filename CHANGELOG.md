# Changelog

All notable changes to Hook (formerly Relay) are listed here. The format follows Keep a Changelog,
and versions follow Semantic Versioning.

## [Unreleased]

### Added
- Crash reports. Hook marks each run in `run-state.json` and, when the last one ended badly,
  docks a bar above the status bar: "Hook quit unexpectedly", with Not Now and Review…. Review…
  opens Send a Crash Report, a sheet with exactly what a send delivers: the Hook and macOS
  versions, the CPU type, the exception and Hook's own frames from the macOS crash file, the
  source and Pond version, and the last 40 lines of the activity log, redacted again, with each
  redacted value tinted. The crash file itself is never attached. Each crash is raised once, by a
  12-character signature, and one notification points to the bar when notifications are allowed.
- Send to GitHub (the default): one unauthenticated search for the signature, then a prefilled
  issue in your browser for you to submit (template `crash.md`, label `crash`), the open issue
  with a comment on the clipboard, or "Fixed in 0.x. Update Hook." when a newer release closed
  it. A long report is trimmed to fit the link and also copied in full. Only an issue filed by
  the repo's owner, a member or a collaborator, or one labeled `crash-confirmed` by a triager,
  counts as an existing issue, so an issue someone else opens with a copied signature can't
  capture the report; only links to the Hook repo's issue pages are opened.
- Send to My Pond, once your Pond and this Mac's owner key are set up: the report goes to your
  own Pond, owner-signed. On Pond 1.2.0 it is a Hook bug, with no Telegram message, and a repeat
  of the same crash adds an occurrence; an older Pond gets a plain ask.
- Settings › General › Privacy: Crash reports (Ask Each Time, Send Automatically, Off), Send to
  (GitHub, My Pond) and the activity log's size with a Finder button. `config.json` gains
  `crashReports` and `crashReportTarget`. Off shows and sends nothing.
- The activity log, `~/Library/Logs/Hook/hook.log`: one line per typed event, so ask contents,
  tokens, the owner key and Pond addresses can't reach it, with error messages redacted. It
  records the screens opened, actions by name, and failed Pond requests with their HTTP status
  and route template (a repeat of the same failure once, until a request works). It
  rolls to `hook.1.log` at 512 KB and is mirrored to the system log. The new
  [docs/privacy.md](docs/privacy.md) and a SECURITY.md section say what it and a report hold.
- Report on a step: an open step with code or a tick ends with a Report button, and the step's
  and the card's context menus have Report a Problem…. The note box docks above the bottom bar;
  Return sends, Esc cancels. A reported step shows only a filled icon, with a tooltip, until the
  session corrects it. Without an approved owner key, Send reads Set Up Owner Key… and the note
  waits for the key. Not on closed asks or This Mac.
- Messages (Pond 1.2.0): an open ask has a Messages section after the replies, for a side note
  to the session that posted it, like typing in its chat. It answers and closes nothing, and only
  that session sees it. ⌘↩ sends; ⌘L focuses it on an ask without a reply prompt; a card's
  Message Session… opens the ask with the field focused. Not on This Mac.
- Clients for Pond 1.2.0: `relay wait` wakes on an owner message and prints it quoted, the
  replies hook shows messages only to the posting session, and `relay status` and `relay_status`
  list them (`messages: [{text, at, verified}]`). Only a message signed with the owner key is
  `verified`; one written with the shared Pond token prints as `unverified message (not from the
  owner's key)`, never as an owner message. `relay list --kind ask|bug` and `relay_list {kind}`
  list one kind, a bug with its count; on a 1.1.0 Pond the client filters by kind itself. The
  skill says a message is the owner typing in chat, never an answer, and that sessions act only on
  verified ones and report the rest to the owner.
- Debug builds have a Crash Now menu item, for testing the crash path.
- `relay post` and `relay_post` refuse an ask that leaves a value to copy inside a step's `do`
  (a URL, an IP or host:port, a path, a `key=value`, a backticked or quoted command, a long id
  like `qwen2.5:14b-instruct`), with the same field-error output as the Pond's validation:
  `steps[3].do: "…" is a value to copy: put it in code (or a URL in url)`. Each value goes in its
  own sub-step's `code`, a page in `url`. The rules are `clients/relay_lint.py`; other clients
  test their copies against `clients/lint-vectors.json`.

### Changed
- The status bar starts with the profile, This Mac or your Pond by its context ("Personal"), and
  a menu to switch between them. Beside it is one quiet word: "Pond" in green when the Pond is
  fine, nothing on This Mac when all is fine, and otherwise the state (Offline, Not ready,
  Connecting…, Updating…) in its colour.
- The queue header reads "Queue". The waiting count stays in the menu-bar tooltip and VoiceOver.
- Settings: a row's secondary action (Show config.json, Check for Updates…, Show in Finder, Open
  Login Items, Update Pond…, Check, Presence Settings…) is a small icon button on the value's
  line, with a tooltip, instead of a button under the value.
- The update check asks `api.github.com/repos/xooxoxxo/hook`, the repo's name since the rename.
- The updater's log moved to `~/Library/Logs/Hook/update.log`, next to the activity log; Hook
  moves the old `~/Library/Logs/Relay/update.log` once.
- Hook still needs Pond `^1.1.0`. Crash reports filed as bugs and Messages need Pond 1.2.0;
  below it, a report goes as a plain ask and Messages stay hidden.

### Correction to 0.11.0
- Report a Problem shipped without a way to reach it in the UI; 0.12 adds it.
<!-- hook:pond=^1.1.0 -->
<!-- hook:mailbox-protocol=5 -->

## [0.11.0] - 2026-11-03

### Added
- Hook reviews step corrections. Every revision of an ask is hashed; Hook checks the whole chain,
  pins every hash it has seen, and renders only from a revision whose hash checked out. A
  correction locks the whole ask until you accept it here: no copy (button, ⌘C or text
  selection), no links or files, no Done, answers, replies or ticks. Skip always works.
- The review is one cumulative diff from the version you last accepted on this Mac (the full
  content when this Mac never showed the ask), with every reason the session gave and "Look
  closer" flags for new hosts, `sudo`, pipes into a shell, decoding, `eval` and non-ASCII code.
  Accepting a changed command, link or file asks for Touch ID (or your password).
- Acceptances, seen marks and pins live in `reviews.json`, each record sealed with a key in the
  Keychain item "Hook review seal". A Keychain that refuses the key keeps corrected asks locked,
  and so does a seal item that is there while `reviews.json` is gone; Reset Review Records… in
  the Notice (Touch ID) starts the records and owner keys again. Hook uses a seal item only when
  `reviews.json` names it (an HMAC under the seal key), and an owner key only when its record
  carries an HMAC under that seal; a process running as you that can read the seal, or rewrite
  `reviews.json` too, can still plant both: see "Keychain items" in SECURITY.md.
- Steps keep their ticks and answers across a correction by their stable ids; changed steps lose
  their tick and show Changed or New until ticked.
- Report a Problem: a one-line note about one step goes to the posting session as a quoted
  report. It needs this Mac's owner key. (Correction: it shipped without a way to reach it in
  the UI; 0.12 adds it.)
- The owner key: Settings › Queue › Owner Key › Set Up This Mac… makes a key for this Mac in the
  Keychain ("Hook owner key") and shows a six-digit code; approve the Pond's Telegram request
  only when it shows the same code. The Pond stores only the key's hash. Hook sends it on owner
  acts, only over https (or plain http to this Mac itself) and only to the scheme it was set up
  on; Settings says "Not used on this address" when the Pond URL is on another. Accepting a
  correction always needs it; Require the owner key, offered once two Macs are approved, stops
  sessions and scripts from answering, pressing Done or reopening as you.
- SECURITY.md has a threat model and the residual risks, including the Keychain limits of
  ad-hoc signed builds until a Developer ID release.
- A history that changed on the Pond (a rollback, a missing revision, a revision that changes
  the title, urgency or origin, or a Pond older than 1.1.0 serving a corrected ask) shows a red
  Notice and stops every act but Skip, until you trust the Pond's history again (Touch ID).

### Changed
- Hook needs Pond `^1.1.0` (1.1.0 or newer, below 2.0.0) for step ids, corrections and the owner
  key. An older Pond keeps working for everything else, with a Notice that names the versions;
  This Mac mode counts as Pond 1.0.0 and has neither yet. Settings › Queue › Connection shows the
  Pond against the range ("Pond 1.1.0 ✓ (needs ^1.1.0)").
- `relay amend` and `relay_amend` now reach a review in Hook. A Pond that has corrections
  switched off still answers "The Pond doesn't take corrections yet."
- The update dialog reads the release's Pond range: it asks for a Pond update only when your
  Pond is below it, never for a minor or patch Pond release. The Pond Notices name both
  versions ("Your Pond (1.0.0) is older than this Hook needs (^1.1.0).").

### Fixed
- Notices that only report something ("This ask is no longer open.", "Settings changed, so the
  queue reloaded.", "Your Pond is up to date") now clear on their own after 8 seconds, or as soon as you open an ask.
  Notices that need you still wait for ✕ or their action.
<!-- hook:pond=^1.1.0 -->
<!-- hook:mailbox-protocol=5 -->

## [0.10.0] - 2026-10-29

### Added
- Prebuilt releases: a `v*` tag builds a universal Hook.app and publishes `Hook-<version>.zip`
  (the app plus the CLI, clients, MCP server, skill and installer) and `SHA256SUMS` on the
  GitHub release. Signed with the repository's identity when it has one, else ad-hoc;
  notarized when an Apple API key is set. `scripts/make-signing-cert.sh` makes a self-signed
  identity and prints the two secrets to store; it uploads nothing.
- `scripts/install.sh --prebuilt` installs the release download it came with.
- Settings › General › Updates shows whether Hook is a release download or a developer
  checkout, and what Check for Updates does with it.

- Session clients: `relay amend` and the MCP tool `relay_amend` correct an open ask you posted, with
  a reason. Each post keeps a per-ask edit key in a private folder; the Pond stores only its hash,
  and a key is only ever sent to the Pond it was made for. Correcting needs a Pond that supports
  it (1.1.0 or newer), and Hook's review of a corrected ask comes in the next release, so for
  now amend refuses with a clear message on every Pond.
- Pond versions follow semver, and the clients check features against npm-style ranges (`^1.1.0`)
  instead of protocol levels; an older Pond that reports only a level still works.

### Changed
- `scripts/get.sh` downloads the newest release zip with curl and checks it against
  `SHA256SUMS`, instead of cloning and compiling: no git and no Command Line Tools needed. It
  installs to `~/.local/share/hook/<version>`, links `~/.local/share/hook/current` to it and
  keeps the version before. Old versions are removed only once the new one installs; a failed
  install links `current` back to the version before.
- Check for Updates on a release download downloads the new release, refuses a zip that
  doesn't match `SHA256SUMS`, and installs it in the background. A developer checkout still
  moves to the release tag and rebuilds.
- An install from a clone moves to the release download: the `relay` and `hook` links, the MCP
  server and the skill go to `~/.local/share/hook/current`, and the clone is left in place
  with a note that it can be deleted. A developer's clone (changes, a local branch other than
  `main`, or `HOOK_DEV=1`) is left alone and builds from source as before. A build with
  `HOOK_DEV=1` is recorded in the config (`"updateMode": "developer"`), so the clone's later
  updates rebuild there too; `HOOK_DEV=0` switches it to the release download.
<!-- hook:pond=^1.0.0 -->
<!-- hook:mailbox-protocol=4 -->

## [0.9.4] - 2026-10-29

### Fixed
- Installing or updating stopped with "build.sh: no viewer resources at …/.build/out/Products/Release/…"
  on Macs whose Swift uses the newer build system, which puts resource bundles elsewhere. The
  build now takes the viewer's files from the source tree, where they are kept unchanged.

## [0.9.3] - 2026-10-29

### Added
- A one-line install: `scripts/get.sh` (piped from GitHub into `bash`, as the README shows)
  clones Hook to `~/.local/share/hook`, or updates the clone you already installed from,
  checks out the newest release and runs `scripts/install.sh`. Installer options go after
  `bash -s --`. It refuses a folder that isn't a clone of Hook or has local changes.

### Changed
- **Run Setup Again…** moved from the menu-bar menu to the About window. About Hook now opens
  Hook's own About window: the icon, version, the GitHub link, Support Hook and Run Setup
  Again…. Before setup, the menu still has **Set Up Hook…**.

### Fixed
- Deleting Hook.app and installing again shows the setup window again, filled in from the
  config you kept, so you only confirm it. Before, setup showed only for a new config.
- An update could leave the old Hook running: when it didn't quit within 5 s, the installer
  replaced the app anyway and `open` only brought the old copy forward, so `relay --version`
  said the new version while the old app ran. The installer (and so Check for Updates) now
  force-quits a copy that doesn't quit, and after starting Hook checks that no copy older
  than the install is running: it force-quits one and starts Hook again, once, then fails
  with a message. Another app called Hook is never touched.

## [0.9.2] - 2026-10-27

### Changed
- The mailbox is now called the Pond: the server you run that holds asks while you're away.
  Settings › Queue, Set Up Hook, the menu-bar menu (**Update Pond…**), the panel's notices and
  status bar, the update dialog, the `relay` CLI and MCP server messages, the skill and the docs
  all say Pond. What stays: the config keys (`source: "mailbox"`, `mailboxURL`, `tokenFile`,
  `mailboxUpdateCommand`), the `/health` `"source": "mailbox"` and `/version`
  `"service": "mailbox"` values, `install.sh --mailbox` and its `mailbox-url` / `mailbox-token`
  files, the `hook:mailbox-protocol=N` release-notes marker, and `docs/mailbox-protocol.md`
  (now titled "Pond protocol"; its `#updating-the-mailbox` link still works), so existing
  configs, servers and links keep working unchanged.

### Fixed
- A two-button notice no longer gets clipped: a Notice always takes the height of its whole
  text and buttons, also with larger text, and the list starts below it. Its text is no longer
  cut at three lines.

## [0.9.1] - 2026-10-27

### Added
- Optional steps: a step or sub-step with `optional: true` says "Optional" on its row, and you
  can tick it done without doing it. An optional question keeps its tick, so you can mark it done
  without answering (⌘T ticks it too); it isn't counted in "N questions unanswered" and never
  holds a blocking step back. Mailbox protocol level 4 adds the key; a step can't be both optional
  and blocking. An optional step makes its sub-steps optional too: ticking it finishes the whole
  step, and none of its sub-steps may be blocking.
- File links: a step or sub-step may carry `file`, and a link may carry `path` instead of `url`:
  an absolute local path (`/…` or `~/…`) to a document to read. Hook keeps them in the step and
  link model; mailbox protocol level 4 adds them with `optional`.
- File rows: a step's `file` and a link's `path` show as a row with the file's icon, name and
  folder, **Open**, and a ⋯ menu with Open With (default app first, then Other…), Reveal in
  Finder and Copy Path. A file from an ask sent on another Mac shows "On <Mac>" with Copy Path
  only; a missing one shows "File not found" once you press Open. Hook touches a file only when
  you press a button.
- A built-in document viewer: Open shows `.md` and `.markdown` rendered, and `.txt` in
  monospace, in a small window titled with the file name (⌘F find, ⌘G next, ⌘W close), with a
  stylesheet from Hook's own colours in light and dark. It renders with vendored marked 18.0.14
  and DOMPurify 3.4.16 (see THIRD_PARTY_NOTICES.md) and never goes online: page scripts are off,
  every load but the page and images from the document's folder is blocked, web links open in
  the browser, and a link to another Markdown or text file in the folder opens it in the viewer.
  Hook.app grows by about 0.5 MB.
- Settings › General › Documents › **Open documents in**: Hook's viewer (the default), the
  file's default app, or an app you choose (config.json `openDocumentsIn`).
- A step's `detail` renders inline Markdown (bold, italic, code, web links) and keeps its line
  breaks. Links other than http(s) stay plain text.
- Writers can set `optional`, `file` and a link's `path`: the instructable schema, the
  `relay post` and `relay_post` descriptions, the skill and the format docs describe them. The
  skill asks for a Markdown file instead of a whole document pasted into an ask.
- Hook checks your mailbox's protocol level (`GET /version`; a mailbox without it is level 1)
  when it connects, when you switch mailboxes and at most every 30 minutes. A mailbox older than
  Hook gets a Notice naming what won't work ("per-step answers", "blocking steps", "optional
  steps", "file links"), with Update Mailbox… and How to update; a newer one gets "Hook is older
  than your mailbox" with Check for Updates. Settings › Queue › Connection shows the mailbox's
  version and level, ✓ or "Needs an update", and Check.
- Update Mailbox…, in the menu-bar menu next to Check for Updates… and in the Notice: runs
  `mailboxUpdateCommand` (Settings › Queue › Mailbox › Update command) in a new window of your
  Resume terminal through your login shell, then reads the mailbox's version again when the
  command ends. Without a command it opens the update guide; a command that can't be run (a line
  break or a control character) gets its own Notice.
- Before Hook updates itself, it reads the release's `<!-- hook:mailbox-protocol=N -->` marker:
  when the connected mailbox is below level N, the dialog says so and offers Update Mailbox First,
  Update Hook Anyway and Cancel. When the mailbox can't be checked, the dialog says so and still
  lets you update. This Mac mode always passes.
- `relay post` and `relay_post` read the mailbox's level (cached for 5 minutes) before posting an
  instructable with `question` (level 2), `blocking` / `warning` (level 3) or `optional`, `file`
  or a link's `path` (level 4), and refuse with
  "This mailbox speaks protocol M; `<key>` needs N." when the mailbox reports a lower level
  ("Hook speaks protocol M…" in This Mac mode). A mailbox without `/version` gets the post as
  before and validates it.
- Writers can set `blocking` and `warning` on steps: the instructable schema, the `relay post`
  and `relay_post` descriptions, the skill and the format docs describe them. `warning` may span
  lines.
- This Mac mode's local API answers `GET /version` with the app's own level.

### Security
- File rows open only documents, by the exact type identifier the click reads from the file:
  Markdown, plain text, CSV, JSON, log (`public.log` and `com.apple.log`), YAML, PDF, PNG, JPEG,
  HEIC, GIF, TIFF, MP3, MPEG-4 audio (`.m4a` too, as `com.apple.m4a-audio`) and video, QuickTime,
  and the Office and iWork types below. A type that only
  conforms to text, an image or a spreadsheet is refused: RTF, SVG, `.ics`, `.vcf`, `.odp`,
  `.xlw`, `.xltx` and `.potx` among them. Apps, scripts, installers, disk images, folders,
  packages, HTML and XML, and location files (`.webloc`, `.inetloc`, `.fileloc`) show "Hook
  doesn't open this kind of file" with only Reveal in Finder and Copy Path. The rule is the same
  for Hook's viewer, the default app, a chosen app and Open With, which lists apps only for
  documents.
- Showing a file row never touches the file: no stat, attributes or icon from the path (the
  icon comes from the extension). Pressing a button checks the file first, off the main thread.
  Paths are made canonical before they show, and network paths (`/net`, `/Network`, `/home`,
  also behind `/private`, `/var/automount` or `/System/Volumes/Data`, stacked or not) and hidden roots (`/.vol`, `/.nofollow`) are
  never opened, even from an ask posted before the validator refused them, and neither is a path
  whose first folder name isn't plain ASCII. A click walks the path by descriptors: it opens `/`,
  then each folder relative to the one before without following a link (a link is read and its
  target walked, one hop at a time), and opens the file the same way. Before it touches a step, the
  kernel mount table must show no network or non-local mount there (an SMB, NFS, autofs or macFUSE
  mount stops it, even one marked local), and every folder and the file must be on a local file
  system (APFS, HFS+, FAT, exFAT, or `/dev`). A pipe or device is never opened, and a file Hook
  can't read says "File not found".
- The validator refuses a `file` or link `path` with a `.` or `..` segment, one whose first
  folder starts with `.` (such as `/.vol` or `/.nofollow`), or one under `/net`, `/Network` or
  `/home` in any case, also behind `//`, `/private`, `/var/automount`, `/private/var/automount`
  or `/System/Volumes/Data`, however those prefixes are stacked (`/private/private/net/…` too),
  and one whose first folder name isn't plain ASCII (case folding turns `/ſystem` or a Kelvin
  sign into an ASCII name on disk).
- Office files open only from an explicit list: Word, Excel and PowerPoint documents and shows
  (`.doc`, `.docx`, `.xls`, `.xlsx`, `.ppt`, `.pptx`, `.pps`, `.ppsx`) and Pages, Numbers and
  Keynote. Macro-enabled files, add-ins (`.xla`, `.xll`, `.xlam`, `.ppam`), binary workbooks
  (`.xlsb`) and templates (`.dotm`, `.xlt`, `.pot`) are refused.
- A file with any execute bit set is refused at the click, whatever its name. Terminal, iTerm2,
  Ghostty, kitty, WezTerm, Warp, Alacritty, Hyper, Tabby, Rio, Wave, Contour, cool-retro-term,
  Script Editor, Automator and Python Launcher are left out of Open With and can't be chosen under
  Open documents in, and so is any app Script Editor or Automator saved (a bundle id under
  `com.apple.ScriptEditor.id.` or `com.apple.automator.`, or an `applet`, `droplet`,
  `Application Stub` or `Automator Application Stub` executable).
- Every route opens the file the click checked, never the path again: Open, the default app, a
  chosen app, Open With and Other… take the resolved file, and the viewer renders the bytes it
  read from the descriptor the check opened, as does a link to another document in the viewer.
  The file's type comes from its canonical name.
- Opening never falls back to something the check didn't choose. When the viewer's read fails
  for any reason but the size, Hook beeps and opens nothing. Every app route names its app: the
  default app comes from the type the check read from the file, is refused when it is a terminal
  or script runner, and gets the file directly (never a bare system open). Right before anything
  opens, Hook checks the path still names the checked file (same device and inode, no symlink
  anywhere in it); a file swapped after the click is refused. See SECURITY.md for the one gap
  left: another app is handed a path.
- The viewer's images go through the same check and read as a document (local disks, no
  execute bit, the exact list), and only PNG, JPEG, GIF and HEIC load: SVG and WebP don't. An
  image's first bytes must match its type (the PNG, JPEG or GIF signature, or an HEIC `ftyp`
  box with a `heic`, `heix`, `mif1` or `msf1` brand), so WebP or another format renamed `.png`
  doesn't load.
- The viewer's images and links to other documents are checked before anything is touched: the
  decoded path may not have an empty, `.` or `..` segment, and must stay inside the document's
  folder and off the network; only then is it resolved, one step at a time, with the same rules
  as a file row.
- From a mailbox, an ask that doesn't name its host counts as from another machine: its file
  rows offer only Copy Path. In This Mac mode it counts as here.
- A link in a step's detail shows its full address as a tooltip; only http(s) links are
  clickable.

### Fixed

- The menu-bar icon no longer disappears behind the notch after an update or restart. macOS put
  an icon with no saved position at the far left of a crowded menu bar; Hook now starts it near
  the right, and a spot you ⌘-drag it to still wins.
- Opening the This Mac queue no longer reads "locked" for a lock that is only held for a moment:
  a process Hook (or anything in it) spawns shares the lock file until it starts, so the queue's
  open now tries the lock again for up to half a second before it says Hook is already running.

## [0.9.0] - 2026-10-27

### Added
- Blocking steps: a step or sub-step marked `blocking` carries a tinted warning box (its own
  `warning` text, or a default line), and the steps after it stay locked ("Finish step 2
  first") until it is done: they can't be opened, ticked or answered, and ⌘T and ⇧⌘T skip them.
- Resume Session, in a card's context menu and the ask's ⋯ menu: opens a new terminal window in
  the session's folder and runs `claude --resume` there, through your login shell. It is enabled
  only for sessions on this Mac; elsewhere it is dimmed with "Session is on <host>". Copy Resume
  Command stays, and is now also offered for closed asks.
- Settings › General › Sessions › Terminal (`terminal` in config.json): Automatic or any
  installed terminal among iTerm2, Ghostty, kitty, WezTerm, Warp and Alacritty. Automatic picks
  the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal,
  and the picker names it ("Automatic (Ghostty)"). Ghostty 1.3 and later is driven by
  AppleScript, so it asks once for Automation permission; without it, Hook opens a new Ghostty
  instance instead.
- Answered rows: a sent reply folds to "You replied: … · time" with Change, which brings the
  question back with the last reply filled in; earlier replies sit under History. A sent step
  answer folds the same way ("You chose: …"), with Cancel beside Send while you change it.
  Nothing about editing is stored.
- Set Up Hook, a seven-page first-run window with progress dots and a full-width Continue:
  Welcome, where asks come from (with a connection test), connecting your agents (register the
  MCP server, install the skill, add the replies hook to `~/.claude/settings.json`, keys kept in
  order, with a `.bak` copy that never overwrites an older one, copy the CLAUDE.md section),
  notifications, the shortcut and login item, a test ask, and Done, with Support Hook. Pages
  push in, and the welcome icon bounces, unless Reduce Motion is on. install.sh writes
  `onboarding: "pending"` only into a config it creates, so existing installs never see it;
  finishing or closing the window removes the key. The menu has Run Setup Again….

### Changed
- Steps are one grouped list that opens like an accordion: the current step is open, done steps
  fold to a ✓ and their title, and upcoming ones show only their title; click one to open it.
- Step questions and reply choices are option rows, one per option with a checkmark on the
  picked one (a checkbox on each in a multi pick), instead of radio buttons and segmented
  pickers.
- The bottom bar is Skip and Done only: "Send N answers" is gone, as every question and the
  reply has its own Send (⌘S still sends every unsent answer).
- Done never sends or drops an unsent reply, pick or answer silently: the bar warns "You have
  an unsent answer" (or "unsent reply") with Send & Done (⌘↩) and Discard & Done, and Esc goes
  back to editing. Done from the queue (⌘↩ or a card's menu) on such an ask opens it with the
  warning up instead of closing it.

## [0.8.0] - 2026-10-27

Relay is now Hook.

### Changed

- The app is called Hook everywhere you see it: the app bundle (`~/Applications/Hook.app`, process `Hook`), menus, windows, Welcome, Settings, notifications, the menu-bar label and tooltips, alerts, the "Handed to Hook" link page, log prefixes, CLI and MCP messages, the schema title, the installer and the docs.
- `scripts/install.sh` quits a running Hook or Relay, installs Hook.app, and only then unregisters and removes `~/Applications/Relay.app`. An existing Relay.app counts as installed, so an update keeps a login item you turned off. `--uninstall` removes both apps. The installer checks the bundle id, so it never quits, replaces or removes another app called Hook.
- The CLI opens the app by its bundle id when it isn't running, so it finds Hook.app, or Relay.app before the installer has run, and never opens another app called Hook.
- The update check accepts a checkout whose origin is `github.com/xooxoxxo/relay` or `github.com/xooxoxxo/hook`, so the GitHub repo can be renamed without breaking updates.

### Added

- A `hook` command: the installer links `~/.local/bin/hook` to the same CLI when that path is free, and leaves someone else's `hook` alone. The CLI prints the name it was run as, so `hook --version` prints `hook 0.8.0`.

### Kept

These names stay, because installs, permissions and sessions depend on them:

- The bundle id `io.github.xooxoxxo.relay`, so settings, notification permission and the single-instance check carry over. The LaunchAgent labels stay too.
- `~/.config/relay`, `~/Library/Application Support/Relay`, `~/Library/Logs/Relay` and `~/.local/state/relay/away`, so the config, token, queue and away flag carry over.
- The `relay://` URL scheme (another app already owns `hook://`).
- The `relay` command, the MCP server `relay` and its tools `relay_post`, `relay_status` and `relay_list`, which CLAUDE.md files, skills and permission lists name, and the `RELAY_*` environment variables.
- The local API: the `/health` reply's `"app": "relay"`, the server proof and the `X-Relay-*` headers.

### Fixed

- ⌘T scrolls the current step clear of the bottom bars when they are taller than usual: when the "N questions unanswered" caption wraps onto its own line, or when the Undo bar shows. The panel now measures the bars instead of assuming their designed height.

## [0.7.1] - 2026-10-27

### Added

- The instructable format documents `question` on steps and sub-steps in the JSON Schema, the format docs, `relay post --help`, the MCP `relay_post` description and the instructables skill. Sessions now bundle related questions into one ask and act on partial answers. `verify` has its own schema definition, which never asks.
- The MCP `relay_status` description covers `answers` and `unanswered`.

## [0.7.0] - 2026-10-27

### Added

- Steps and sub-steps can ask a question: one pick from up to 6 choices, several picks, or free text. Answer each in the ask and send them with Send answers (⌘S); the ask stays open. While answers are unsent, ⌘↩ becomes Send & Done.
- An answered step shows "You chose …" or "You answered …". An edited answer shows "Not sent" until you send it. A caption counts the questions still unanswered, and Done stays available.
- A closed ask shows its answers read-only until you reopen it.
- `relay wait` wakes on answers. It then waits until 10 seconds pass without a new one, so a burst of answers wakes a session once. It prints one line per answer, then "answered X of Y; open: …".
- `relay status`, `relay replies`, the prompt hook and the MCP server's `relay_status` (`answers`, `unanswered`) report answers.
- The mailbox protocol adds `POST /asks/{id}/answers` and the `answer` event.

### Changed

- Queue cards count answered questions in "N of M" once the ask's detail is loaded.

## [0.6.6] - 2026-10-26

### Changed

- Clicking the menu-bar icon hides the panel whenever it is on screen, focused or not. The keyboard shortcut still brings a visible but unfocused panel to the front.

## [0.6.5] - 2026-10-26

### Added

- Update from the menu: Relay checks GitHub for a newer release once a day (or on Check for Updates…), and "Update Relay to X.Y.Z…" rebuilds it from your checkout and restarts it. A checkout with local changes is left alone, with the reason shown. The log is in ~/Library/Logs/Relay/update.log.

## [0.6.4] - 2026-10-26

### Changed

- The menu-bar icon shows a dot only for new asks that arrived while the panel was closed; opening the panel clears it. The count badge and its setting are gone.

### Fixed

- The "session closed this ask" notice goes away when you leave that ask, instead of staying on the queue.

## [0.6.3] - 2026-10-20

### Changed

- New asks play a sound by default (Settings › Notifications › Play a sound).

### Fixed

- Settings: each help "?" sits right after its label instead of in a column at the far edge.

## [0.6.2] - 2026-10-20

### Fixed

- The queue scrolls more smoothly and Relay uses less memory and CPU: a check that finds nothing new no longer redraws the panel, and moving through the list redraws only the cards that changed.

## [0.6.1] - 2026-10-20

### Changed

- The queue shows one card per ask again, as in 0.5: the project badge, project and age on top, a bold title over up to two lines, and a short line such as "Choose 1 of 3" or "2 of 7". Grouping, the filter, keys and sub-steps stay as in 0.6.0.

### Fixed

- Relay no longer crashes a few seconds after launch when the queue is short and an ask was closed in the last 24 hours.
- Opening Relay while it is quitting, or opening two copies at once, no longer leaves no Relay running.
- Relay quits when stopped with `kill` or `launchctl` (as an update does) while a Done or Skip is held, instead of hanging.

## [0.6.0] - 2026-10-20

### Added

- Steps can have indented, tickable sub-steps (`substeps`).
- Group the queue by project or by urgency, and filter it to one project (⌃⌘G, ⌃⌘P, ⌃⌘A). Both are remembered on this Mac, and a filtered-out "now" ask still notifies and slides in.
- After Done or Skip, the panel opens the next ask; Settings › Panel › After Done or Skip (config `afterClose`) can go back to the queue instead.
- A Panel tab in Settings: edge, display, Re-dock Now, slide-in and After Done or Skip.
- Keys for ticking (⌘T, ⇧⌘T), the previous and next ask (⌘↑, ⌘↓), copying the current code (⇧⌘C), opening its link (⇧⌘O), copying an ask's link (⇧⌘L), the reply field (⌘L), choices (1–6) and docking (⌃⌘←, ⌃⌘→).
- The menu-bar menu has Show/Hide Relay with the shortcut, the queue status, a Panel submenu with the displays, and About Relay. The icon's tooltip always says what is waiting.
- Opening a second copy of Relay brings the running one forward (`relay://show`).

### Changed

- A new native look for the panel, Settings and Welcome: stock controls, more space, and a panel with square corners flush with the screen edge.
- "Closed today" is now "Recently closed": the last 24 hours, following the project filter.
- Ticks are kept per step and checked against the step's text, so an edited or re-posted ask never shows a tick on the wrong step. Existing ticks carry over.
- Mailbox settings are saved with Connect, which checks the connection once; Revert drops the edits.
- Welcome has two pages: where asks come from, then the shortcut, notifications, Claude Code and login.
- Relay asks for notification permission before its first notification instead of at launch, and removes a notification once its ask closes.
- A link or notification for an ask that is no longer open shows the list with a note instead of doing nothing.

### Fixed

- Editing unrelated settings no longer re-docks the panel; the shortcut or icon re-docks a panel that is out of place instead of hiding it.
- Changing the mailbox check interval no longer reloads the queue.
- Config edits are still picked up after the config folder was replaced.
- Error messages in the panel and Settings show as one line, with hidden characters revealed.

## [0.5.1] - 2026-10-16

### Fixed

- Away mode counts a Screen Sharing session as away: Touch ID can't be reached
  from a remote screen, and remote input used to look like you were at the Mac.

## [0.5.0] - 2026-10-16

### Added

- Away mode: Relay marks you away when the screen locks, the displays sleep, you
  switch users or the Mac sits idle (Automatic, 5 to 60 minutes), or when you set
  it by hand. While away, the panel doesn't slide in and no notifications show;
  on return, one notification says how many asks arrived. The status menu shows
  the state and has a Presence submenu, the icon fades, and
  `$HOME/.local/state/relay/away` exists so other tools can tell.
  New config keys `presence` and `awayAfterMinutes`.
- Docking: drag the panel to the left or right edge of any display; it stays pinned there
  through display changes, sleep and wake.

## [0.4.0] - 2026-10-16

### Added

- A step `detail` field (at most 1500 characters, line breaks allowed) for longer
  instructions, shown as wrapped text under the step's action.
- Code blocks with `lang` `text`, or no `lang`, wrap long lines; other languages keep
  their lines and scroll sideways. Copy still copies the exact text.

## [0.3.1] - 2026-10-15

### Changed

- The page an Open in Relay link opens is redesigned and closes its own tab where
  the browser allows it.

## [0.3.0] - 2026-10-15

### Added

- Undo: after Done or Skip, a 10-second Undo bar (or ⌘Z) brings the ask back before
  the answer is sent.
- A "Closed today" group in the sidebar, with Reopen.
- The Claude Code session id is recorded with each ask (`CLAUDE_CODE_SESSION_ID`,
  falling back to `CLAUDE_SESSION_ID`), and the project folder from
  `CLAUDE_PROJECT_DIR`.
- A From row in the ask view (folder · Mac · short session id) with a copyable
  command that resumes the session in Claude Code.
- The mailbox `POST /asks/{id}/reopen` route and the `reopened` owner event, shown by
  `relay status`, `relay replies`, `relay wait` and `relay_status`.

## [0.2.0] - 2026-10-15

First public release.

### Added

- Two queue modes: "This Mac only", where Relay keeps the queue itself and nothing
  leaves the Mac, and Mailbox, where Relay polls a mailbox service you run.
- The menu-bar app: a sidebar for open asks with Copy buttons, tickable steps, and
  Done, Skip and Reply; a red badge with the open count; a global shortcut; and
  Settings with General, Queue, Notifications and Connect tabs.
- Notifications by urgency, with an optional sound and a slide-in sidebar for "now"
  asks.
- The `relay` CLI: `post`, `status`, `list`, `done`, `skip`, `replies` and `wait`.
- An optional Claude Code hook that shows new owner answers in the next prompt.
- The MCP server (`relay_post`, `relay_status`, `relay_list`) and the
  `instructables` skill for Claude Code.
- An installer that builds the app, links the CLI and skill, registers the MCP
  server, and updates or uninstalls in place.
- Security hardening: a loopback-only API with a 256-bit token, refusal of browser
  requests, a server proof before any client sends the token, private file
  permissions, and secret-like strings rejected in asks.
