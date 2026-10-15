# Changelog

All notable changes to Relay are listed here. The format follows Keep a Changelog,
and versions follow Semantic Versioning.

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
