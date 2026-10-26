# Using Relay

Relay lives in the menu bar and shows asks in a panel docked to the edge of a display.

## Menu bar

- Click the checklist icon, or press ⌃⌥⌘R anywhere, to show the panel. If it is open but another app has focus, the same click or key focuses it; if it is focused, it hides. Change or turn off the shortcut in Settings › General.
- Right-click (or Control-click) the icon for the menu: Show or Hide Relay, the queue status, your presence, Refresh, Panel (dock left or right, pick a display, Re-dock Now), Settings…, About Relay, Check for Updates… and Quit Relay.
- A red badge counts waiting asks from 1 to 9. From 10 up, or with "Show the count on the badge" off, it is a dot. The badge always counts every open ask, whatever the panel's project filter.
- Hover the icon for a summary: how many asks wait, how many are "now", and the shortcut.
- Relay asks for notification permission before its first notification, or when you allow it on the second Welcome page or in Settings › Notifications.

## The panel

Drag the panel by its top bar to the left or right edge of any display. When you let go, it snaps flush and full height, and stays pinned there. ⌃⌘← and ⌃⌘→ do the same on the current display, and a double-click on the top bar puts it back. After a display change, sleep or wake, it returns to its spot. If the pinned display is disconnected, the panel uses the same edge of the main display and goes back when the display returns.

A "now" ask slides the hidden panel in on that ask without taking focus from the app you are typing in. Click ✕ to slide it back out. This doesn't happen while you're away.

## The queue

- Each ask is a **card**: the project's badge and name, the urgency for Now and Today asks, the age ("3h"), the title, and what the ask wants ("Choose 1 of 3", "4 steps · Terminal", "Reply") or, once you tick something, how far along it is ("2 of 7").
- **Group by** Project (the default) or Urgency, from the filter button in the header or with ⌃⌘G. In Project grouping, each project is a section with its open count; projects with a "now" ask come first.
- **Filter** to one project from the same button, from a card's context menu (Show Only …) or with ⌃⌘P. The project shows under the header with a ✕ to show all projects again (⌃⌘A), and "2 more in other projects" when others wait. Grouping and filter are remembered on this Mac.
- **Recently closed** lists asks closed in the last 24 hours, each with **Reopen**. It follows the filter.
- The status bar at the bottom says whether the queue is reachable; click it for details.

## An ask

- Tick steps as you go. A step can have indented **sub-steps** ("2a", "2b"), each with its own tick; ticking the parent ticks them all. The current step is boxed.
- **Copy** copies exactly the code shown, with no trailing newline, so a paste never runs by itself.
- Answer with **Done**, **Skip** or a reply (text, or one of the offered choices). With a reply typed or a choice picked, Done becomes **Send & Done**.
- **After Done or Skip** the panel opens the next ask in the list (Settings › Panel can make it go back to the queue instead). An Undo bar shows for 10 seconds; Undo or ⌘Z brings the ask back. Relay sends your answer only after that.
- **From** shows the folder, Mac and short session id of the session that asked, with a command that resumes it in Claude Code.
- Drafts, ticks and where you scrolled survive going back, switching asks and hiding the panel. Ticks also survive a relaunch.

## Keys

| Where | Key | Action |
|---|---|---|
| Anywhere | ⌃⌥⌘R | Show, focus or hide the panel |
| Panel | Esc | Close a popover, stop editing, go back to the list, then hide |
| Panel | ⌘W | Hide Relay |
| Panel | ⌘R | Refresh |
| Panel | ⌘, | Settings |
| Panel | ⌘Z | Undo the latest Done or Skip (in a text field: undo typing) |
| Panel | ⌃⌘← / ⌃⌘→ | Dock on the left / right edge |
| Panel | ⌃⌘G | Switch grouping |
| Panel | ⌃⌘A | Show all projects |
| List | ↑ ↓ | Move the selection |
| List | Return | Open the selected ask |
| List | ⌘↩ / ⌘⌫ | Done / Skip the selected ask |
| List | ⇧⌘R | Reopen the selected closed ask |
| List, ask | ⇧⌘L | Copy the link to the ask |
| List, ask | ⌃⌘P | Show only this ask's project |
| Ask | Esc, ⌘[ | Back to the list |
| Ask | ⌘↑ / ⌘↓ | Previous / next ask |
| Ask | ⌘↩ | Done, or Send & Done with a reply or choice |
| Ask | ⌘⌫ | Skip |
| Ask | ⌘T / ⇧⌘T | Tick the current step or sub-step / untick the last |
| Ask | ⇧⌘C / ⇧⌘O | Copy the current step's code / open its link |
| Ask | ⌘L | Focus the reply field |
| Ask | 1–6 | Pick a choice |
| Reply field | Return / ⌥Return | Send / new line |
| Settings | ⌘1 … ⌘5 | General, Panel, Queue, Notifications, Connect |

## Away mode

Relay marks you away when the screen is locked, the displays sleep, you switched users, you're connected over Screen Sharing, or you haven't touched the Mac for the time set in Settings › General (10 minutes by default). Or pick Home or Away yourself from Presence in the menu.

While you're away, "now" asks don't slide the panel in and no notifications show. Asks still reach anything your mailbox forwards them to. The icon fades, the status bar starts with "Away", and the menu shows why and since when. When you're back, one notification counts the asks that arrived for the urgencies switched on in Notifications; click it to open the list on the first of them.

Relay also keeps a [flag file](configuration.md#the-away-flag) for other tools.

## Updating

Relay checks GitHub for a new release a minute after launch and then daily. When one exists, the menu starts with "Update Relay to X.Y.Z…". Relay then updates your checkout to that release tag (it must be clean and on main) and runs `scripts/install.sh`, restarting in about 2 minutes. The log is `~/Library/Logs/Relay/update.log`.

## Settings

- **General:** shortcut, presence and away time, Start Relay when I log in, badge count, appearance, version.
- **Panel:** edge, display, Re-dock Now, whether "now" asks slide the panel in, what happens after Done or Skip.
- **Queue:** This Mac only or Mailbox, how long closed asks stay, the mailbox address, token file, context and check interval (saved with Connect), connection status, Send a Test Ask.
- **Notifications:** which urgencies notify, sound, permission, a test notification.
- **Connect:** the MCP command, the relay command, the CLAUDE.md section, the skill and the replies hook.

Settings writes the [config file](configuration.md). Every "?" button explains its row.
