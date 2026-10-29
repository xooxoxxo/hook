# Using Hook

Hook lives in the menu bar and shows asks in a panel docked to the edge of a display.

## First run

A new install opens **Set Up Hook**, seven short pages: Welcome; where asks come from (This Mac or a Pond, tested when you press Continue); connecting your agents (register the MCP server, install the skill, add the replies hook to `~/.claude/settings.json`, which is rewritten as JSON with your keys in their order, keeping the old file as `settings.json.bak` (or `settings.json.bak-<date>-<time>` when that exists), and copy the CLAUDE.md section; every item can be copied instead, or skipped); notifications; the shortcut and Start at login; a test ask; and Done. Anything you skip is in Settings. Close the window to skip the rest; once a source is set, it doesn't come back on its own. Run it again from **About Hook** in the menu: **Run Setup Again…**. Updating an existing install never shows it; installing Hook.app again after deleting it does, filled in from your config.

## Menu bar

- Click the checklist icon, or press ⌃⌥⌘R anywhere, to show the panel. If it is open but another app has focus, the same click or key focuses it; if it is focused, it hides. Change or turn off the shortcut in Settings › General.
- Right-click (or Control-click) the icon for the menu: Show or Hide Hook, the queue status, your presence, Refresh, Panel (dock left or right, pick a display, Re-dock Now), Settings…, About Hook (version, the project link and Run Setup Again…), Check for Updates… and Quit Hook.
- A red badge counts waiting asks from 1 to 9. From 10 up, or with "Show the count on the badge" off, it is a dot. The badge always counts every open ask, whatever the panel's project filter.
- Hover the icon for a summary: how many asks wait, how many are "now", and the shortcut.
- Hook asks for notification permission before its first notification, or when you allow it during setup or in Settings › Notifications.

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

- Steps are one grouped list. Tick steps as you go. The current step is open; done steps fold to a ✓ and their title, and upcoming ones show only their title. Click a done or upcoming step to open it. A step can have **sub-steps** ("2a", "2b"), each with its own tick; ticking the parent ticks them all.
- **Blocking steps** carry a tinted warning box. The steps after one stay locked ("Finish step 2 first") until it is done: they can't be opened, ticked or answered.
- **Optional steps** say **Optional** at the end of the row. You can tick one done without doing it; an optional question keeps its tick, so ticking it marks it done unanswered, and ⌘T ticks it too. Optional questions aren't in the bar's unanswered count.
- A step's text can use **bold**, *italic*, `code` and web links, and keeps its line breaks.
- **Opening files.** A step (or a link under **Links**) can point to a document on your Mac. It shows as a row with the file's icon, its name and its folder, an **Open** button and a ⋯ menu with **Open With** (the apps that open that kind of file, default first, and **Other…**; never a terminal, Script Editor, Automator, Python Launcher or an app saved from Script Editor or Automator), **Reveal in Finder** and **Copy Path**. Open shows Markdown (`.md`, `.markdown`) rendered and text (`.txt`) as it is in Hook's own viewer: a small window titled with the file name, with ⌘F to find, ⌘G for the next match and ⌘W to close. The viewer never goes online: scripts in the document don't run, web links open in your browser, and images load only from the document's own folder. Other files open in their default app; Settings › General › **Open documents in** can send every file to its default app or to an app you choose. Hook opens only these document types, judged by the file's type: Markdown, plain text (`.txt`), CSV, JSON, logs (`.log`), YAML, PDF, PNG, JPEG, HEIC, GIF, TIFF, MP3, M4A, MP4, QuickTime movies, Word, Excel and PowerPoint documents and shows (`.doc`, `.docx`, `.xls`, `.xlsx`, `.ppt`, `.pptx`, `.pps`, `.ppsx`), and Pages, Numbers and Keynote. Anything else, such as an app, a script, an installer, a folder, a web page, SVG, RTF, a calendar or contact file, a template or a file marked executable, says **Hook doesn't open this kind of file** and offers only Reveal in Finder and Copy Path. A file from an ask sent on another Mac says **On <Mac>** and offers only Copy Path, and so does a Pond ask that doesn't say which machine it came from (**From another machine**). Network paths (`/net`, `/Network`, `/home`, in any spelling, and anything on a file system other than a local disk, such as SMB, NFS, WebDAV or FUSE) hidden roots such as `/.vol`, and paths whose first folder name isn't plain ASCII are never opened. Showing a row never touches the file: Hook checks it only when you press a button, and a file that isn't there (or can't be read for the viewer) then says **File not found**. What opens is the file Hook checked, in an app named for its checked type: if the file is replaced (by a link or another file) between the check and the open, or a folder on its path is a link when Hook reads it, Hook beeps and opens nothing.
- **Copy** copies exactly the code shown, with no trailing newline, so a paste never runs by itself.
- Answer with **Done**, **Skip** or a reply (text, or one of the offered choices), which has its own **Send**. Done never sends or drops anything silently: with a reply typed or a choice picked but not sent, the bar warns **You have an unsent reply** and offers **Send & Done** (⌘↩) or **Discard & Done**; Esc goes back to editing. Once a reply is sent it folds to **You replied: … · time** with **Change**, which brings the question back with your last reply filled in; sending again posts a new reply (the agent may already have acted on the first). Earlier replies sit under **History**.
- **After Done or Skip** the panel opens the next ask in the list (Settings › Panel can make it go back to the queue instead). An Undo bar shows for 10 seconds; Undo or ⌘Z brings the ask back. Hook sends your answer only after that.
- **Answering questions.** A step can ask a question under its text: pick one option or several, or type an answer. A question step has no tick; it counts as done once its answer is sent. Each question has its own **Send** (Return sends a typed answer); ⌘S sends every unsent answer at once and leaves the ask open, so you can answer some now and the rest later. Changes you haven't sent say **Not sent**; the bar counts the questions still unanswered. With an answer unsent, Done warns **You have an unsent answer** instead of closing: **Send & Done** (⌘↩) sends the answers, then any reply, and closes only if every send worked; **Discard & Done** drops them and closes; Esc goes back to editing. A sent answer folds to **You chose: …** (or **You answered: …**) with its time and **Change**; Change brings the options or the field back, with **Cancel** beside Send. You can change an answer until the ask closes; a closed ask shows its answers read-only until you **Reopen** it.
- **From** shows the folder, Mac and short session id of the session that asked, with a command that resumes it in Claude Code.
- **Resume Session**, in a card's context menu or the ⋯ menu at the top of an ask, opens a new terminal window in the session's folder and runs `claude --resume` with its session. Pick the terminal in Settings › General (Automatic picks the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal; the picker shows which, as in "Automatic (Ghostty)"). It works only for a session on this Mac; for one on another Mac the item is dimmed and says which Mac. If the terminal doesn't open, Hook copies the resume command and says why.
- Drafts, ticks and where you scrolled survive going back, switching asks and hiding the panel. Ticks also survive a relaunch.

## Keys

| Where | Key | Action |
|---|---|---|
| Anywhere | ⌃⌥⌘R | Show, focus or hide the panel |
| Panel | Esc | Close a popover, stop editing, go back to the list, then hide |
| Panel | ⌘W | Hide Hook |
| Panel | ⌘R | Refresh |
| Panel | ⌘, | Settings |
| Panel | ⌘Z | Undo the latest Done or Skip (in a text field: undo typing) |
| Panel | ⌃⌘← / ⌃⌘→ | Dock on the left / right edge |
| Panel | ⌃⌘G | Switch grouping |
| Panel | ⌃⌘A | Show all projects |
| List | ↑ ↓ | Move the selection |
| List | Return | Open the selected ask |
| List | ⌘↩ / ⌘⌫ | Done / Skip the selected ask; with something unsent, Done opens it with the warning |
| List | ⇧⌘R | Reopen the selected closed ask |
| List, ask | ⇧⌘L | Copy the link to the ask |
| List, ask | ⌃⌘P | Show only this ask's project |
| Ask | Esc, ⌘[ | Back to the list |
| Ask | ⌘↑ / ⌘↓ | Previous / next ask |
| Ask | ⌘↩ | Done; with something unsent, the warning's Send & Done |
| Ask | Esc (in the Done warning) | Back to editing |
| Ask | ⌘S | Send the step answers |
| Ask | ⌘⌫ | Skip |
| Ask | ⌘T / ⇧⌘T | Tick the current step or sub-step / untick the last |
| Ask | ⇧⌘C / ⇧⌘O | Copy the current step's code / open its link |
| Ask | ⌘L | Focus the reply field (Change on a sent reply) |
| Ask | 1–6 | Pick a choice |
| Reply field | Return / ⌥Return | Send / new line |
| Settings | ⌘1 … ⌘5 | General, Panel, Queue, Notifications, Connect |

## Away mode

Hook marks you away when the screen is locked, the displays sleep, you switched users, you're connected over Screen Sharing, or you haven't touched the Mac for the time set in Settings › General (10 minutes by default). Or pick Home or Away yourself from Presence in the menu.

While you're away, "now" asks don't slide the panel in and no notifications show. Asks still reach anything your Pond forwards them to. The icon fades, the status bar starts with "Away", and the menu shows why and since when. When you're back, one notification counts the asks that arrived for the urgencies switched on in Notifications; click it to open the list on the first of them.

Hook also keeps a [flag file](configuration.md#the-away-flag) for other tools.

## Updating

Hook checks GitHub for a new release a minute after launch and then daily. When one exists, the menu starts with "Update Hook to X.Y.Z…". Hook then updates your checkout to that release tag (it must be clean and on main) and runs `scripts/install.sh`, restarting in about 2 minutes. The log is `~/Library/Logs/Relay/update.log`.

## Settings

- **General:** shortcut, presence and away time, Start Hook when I log in, badge count, where documents open, the terminal for Resume Session, appearance, version.
- **Panel:** edge, display, Re-dock Now, whether "now" asks slide the panel in, what happens after Done or Skip.
- **Queue:** This Mac only or Pond, how long closed asks stay, the Pond URL, Pond token file, context and check interval (saved with Connect), connection status, Send a Test Ask.
- **Notifications:** which urgencies notify, sound, permission, a test notification.
- **Connect:** the MCP command, the relay command, the CLAUDE.md section, the skill and the replies hook.

Settings writes the [config file](configuration.md). Every "?" button explains its row.
