# Using Relay

Relay lives in the menu bar and shows asks in a sidebar.

## Menu bar

- Click the checklist icon to show or hide the sidebar. Right-click (or Control-click) it for your presence, Refresh, Settings… and Quit Relay.
- ⌃⌥⌘R toggles the sidebar from anywhere. Change or turn it off in Settings › General.
- A red badge counts waiting asks from 1 to 9. From 10 up, or with "Show the count on the badge" off, it is a dot.
- On first launch, Relay asks to show notifications.

## An ask

- Tick steps as you go.
- **Copy** copies exactly the code shown, with no trailing newline, so a paste never runs by itself.
- Answer with **Done**, **Skip** or **Reply** (text or one of the offered choices).
- **From** shows folder · Mac · short session id. **Back to the session** gives a command that resumes it in Claude Code.
- After Done or Skip, an Undo bar shows for 10 seconds; Undo or ⌘Z brings the ask back. Relay sends your answer only after that.
- **Closed today**, collapsed at the bottom, lists today's closed asks, each with **Reopen**.

## Keys

| Key | Action |
|---|---|
| ↑ ↓ | Move |
| ↩ | Open an ask |
| Esc | Back, or hide the sidebar |
| ⌘↩ | Done (Send, while typing a reply) |
| ⌘Z | Undo |
| ⌘R | Refresh |
| ⌘, | Settings |

## Away mode

Relay knows when you're away from the Mac: the screen is locked, the displays sleep, you switched users, or you haven't touched it for the time set in Settings › General (10 minutes by default). You can also pick Home or Away yourself from Presence in the status menu.

While you're away, "now" asks don't slide the sidebar in and no notifications show. Asks still reach anything your mailbox forwards them to, such as a phone. The icon fades, and the status menu shows why and since when. When you're back, one notification says how many asks arrived, counting only the urgencies switched on in Notifications; click it to open the list.

Relay also keeps a [flag file](configuration.md#the-away-flag) for other tools.

## Settings

- **General:** shortcut, Start Relay when I log in, badge count, presence and away time, sidebar edge, appearance.
- **Queue:** This Mac only or Mailbox, how long finished asks stay, mailbox address, token file and check interval, Send a test ask.
- **Notifications:** which urgencies notify, sound, whether "now" asks slide the sidebar in.
- **Connect:** the MCP server, the CLAUDE.md section with Copy, the skill and the replies hook.

Settings writes the [config file](configuration.md).
