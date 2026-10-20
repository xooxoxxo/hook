# Changelog

All notable changes to Relay are listed here. The format follows Keep a Changelog,
and versions follow Semantic Versioning.

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
