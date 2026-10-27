# Changelog

All notable changes to Hook (formerly Relay) are listed here. The format follows Keep a Changelog,
and versions follow Semantic Versioning.

## [Unreleased]

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
  back to editing.

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
