# Using Relay

Relay lives in the menu bar and shows asks in a sidebar.

## Menu bar

- Click the checklist icon to show or hide the sidebar. Right-click (or Control-click) it for Refresh, Settings… and Quit Relay.
- ⌃⌥⌘R toggles the sidebar from anywhere. Change or turn it off in Settings › General.
- A red badge counts waiting asks from 1 to 9. From 10 up, or with "Show the count on the badge" off, it is a dot.
- On first launch, Relay asks to show notifications.

## Keys

| Key | Action |
|---|---|
| ↑ ↓ | Move |
| ↩ | Open an ask |
| Esc | Back, or hide the sidebar |
| ⌘↩ | Done |
| ⌘Z | Undo |
| ⌘R | Refresh |
| ⌘, | Settings |

## An ask

- Tick steps as you go.
- **Copy** copies exactly the code shown, with no trailing newline, so a paste never runs by itself.
- Answer with **Done**, **Skip** or **Reply** (text or one of the offered choices).
- **From** shows folder · Mac · short session id. **Back to the session** gives a command that resumes it in Claude Code.
- After Done or Skip, an Undo bar shows for 10 seconds; Undo or ⌘Z brings the ask back. Relay sends your answer only after that.
- **Closed today**, collapsed at the bottom, lists today's closed asks, each with **Reopen**.

## Settings

- **General:** shortcut, Start Relay when I log in, badge count, sidebar edge, appearance.
- **Queue:** This Mac only or Mailbox, how long finished asks stay, mailbox address, token file and check interval, Send a test ask.
- **Notifications:** which urgencies notify, sound, whether "now" asks slide the sidebar in.
- **Connect:** the MCP server, the CLAUDE.md section with Copy, the skill and the replies hook.

Settings writes the [config file](configuration.md).
