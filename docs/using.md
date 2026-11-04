# Using Hook

Hook lives in the menu bar. Its panel docks to the edge of a display and shows your asks.

## First run

A new install opens **Set Up Hook**, seven short pages:

1. Welcome.
2. Where asks come from: This Mac or a Pond. Hook tests the Pond when you press Continue.
3. Your agents. **Set Up All** gives each coding agent on this Mac Hook's MCP server, the instructables skill and Hook's instructions. Agents that support it also get the replies hook. For Claude Code that is the Hook plugin and `~/.claude/rules/hook.md`, so you paste nothing into CLAUDE.md. A file you edited stays as it is. To do this later, use Settings › Agents or `relay integrations sync` ([Agents](agents.md)).
4. Notifications.
5. The shortcut and Start at login.
6. A test ask.
7. Done.

Close the window to skip the rest; it is all in Settings. Once a source is set, setup doesn't return by itself. To run it again, choose **About Hook** › **Run Setup Again…** in the menu. Updates never show setup. Installing Hook.app again after you deleted it does, filled in from your config.

## Menu bar

- Click the hook icon, or press ⌃⌥⌘R anywhere, to show the panel. The same click or key focuses an open panel, and hides a focused one. Change or turn off the shortcut in Settings › General.
- A fish shows on the hook while an ask that arrived with the panel hidden is still unseen.
- Hover the icon to see how many asks wait, how many are "now", and the shortcut.
- Right-click the icon for the menu. It has Show or Hide Hook, the queue status, your presence, Refresh and Panel (dock left or right, pick a display, Re-dock Now). Then come Settings…, About Hook, Check for Updates…, Update Pond… (on a Pond) and Quit Hook.
- Hook asks for notification permission before its first notification, or when you allow it in setup or Settings.

## The panel

Drag the panel by its top bar to the left or right edge of any display, where it snaps flush and full height. ⌃⌘← and ⌃⌘→ do the same on the current display, and a double-click on the top bar puts it back. After a display change, sleep or wake, the panel returns. If its display is gone, the panel uses the same edge of the main display until the display returns.

A "now" ask slides the hidden panel in on that ask, without taking focus from your app. Click ✕ to slide it out. This doesn't happen while you're away.

## The queue

- Each ask is a **card**: the project's badge and name, the urgency (Now or Today), the age ("3h") and the title. It also says what the ask wants ("Choose 1 of 3", "Reply"). Once you tick something, it shows your progress ("2 of 7").
- **Group by** Project (the default) or Urgency, from the filter button in the header. By project, each project is a section with its open count, and projects with a "now" ask come first.
- **Filter** to one project from the same button or a card's context menu (Show Only …). The project shows under the header with a ✕, plus "2 more in other projects" when others wait. This Mac remembers the grouping and filter.
- **Recently closed** lists asks closed in the last 24 hours, each with **Reopen**. It follows the filter.
- The count of waiting asks is in the menu-bar tooltip, and VoiceOver reads it with the **Queue** header.
- **The status bar** at the bottom starts with the profile: **This Mac**, or your Pond named by its `context` ("Personal"). Click it to switch queues, or for **Queue Settings…** and **Set Up a Pond…**. The Pond is listed once its URL and token file are saved. Switching saves `source` to the config, so it is off while `config.json` can't be saved.
- Next to the profile is one word for the connection. **Pond** in green means all is fine; on This Mac, no word means the same. Otherwise it names the state in its colour: **Offline**, **Not ready**, **Connecting…**, **Updating…** or a config problem. Click it for details.

## Work through an ask

- **Steps** are one list. Tick each step as you go. The current step is open, done steps fold to a ✓, and later steps show only their title. Click any step to open it. **Sub-steps** ("2a", "2b") have their own ticks; ticking the parent ticks them all.
- **Blocking steps** have a tinted warning box. Later steps stay locked ("Finish step 2 first") until it is done.
- **Optional steps** say **Optional**. You can tick one without doing it. A ticked optional question counts as done without an answer, and the unanswered count leaves it out.
- **Required steps** have a mark on the step number and a tinted row. An ask can also require your reply or a message. **Done** stays off until every marked item is finished, and each mark clears as you finish it. **Skip** always works. Telegram shows no Done button until then either. Required steps need a Pond 1.3.0 or newer, not This Mac.
- Step text can use **bold**, *italic*, `code` and web links, and keeps its line breaks.
- **Copy** copies exactly the code shown, with no newline at the end, so a paste never runs by itself.
- **From** shows the folder, Mac and short session id of the asking session, with a command that resumes it in Claude Code.
- Drafts, ticks and scroll position survive going back, switching asks and hiding the panel. Ticks also survive a relaunch.

## Open files from an ask

A step, or a link under **Links**, can point to a document on your Mac. Its row shows the file's icon, name and folder, an **Open** button and a ⋯ menu with **Open With**, **Reveal in Finder** and **Copy Path**. Open With lists the apps for that kind of file, default first, and **Other…**. It never lists a terminal, Script Editor, Automator, Python Launcher, or an app saved from Script Editor or Automator.

**Open** shows Markdown (`.md`, `.markdown`) rendered, and `.txt` as plain text, in Hook's own viewer. The viewer window has ⌘F to find, ⌘G for the next match and ⌘W to close. It never goes online: scripts don't run, web links open in your browser, and images load only from the document's folder. Other files open in their default app, or in the app set in Settings › General › **Open documents in**.

Hook judges a file by its type, and opens only these:

- Text: Markdown, plain text (`.txt`), CSV, JSON, logs (`.log`) and YAML.
- PDF and images: PDF, PNG, JPEG, HEIC, GIF and TIFF.
- Audio and video: MP3, M4A, MP4 and QuickTime movies.
- Office: Word, Excel and PowerPoint documents and shows (`.doc`, `.docx`, `.xls`, `.xlsx`, `.ppt`, `.pptx`, `.pps`, `.ppsx`).
- Pages, Numbers and Keynote.

Some rows offer less:

- Any other file says **Hook doesn't open this kind of file** and offers only Reveal in Finder and Copy Path. That covers apps, scripts, installers, folders, web pages, SVG, RTF, calendar and contact files, templates and executable files.
- A file from another Mac says **On <Mac>** and offers only Copy Path. So does a Pond ask that doesn't name its machine (**From another machine**).
- Hook never opens network paths (`/net`, `/Network`, `/home` in any spelling, or any SMB, NFS, WebDAV or FUSE volume). The same goes for hidden roots such as `/.vol`, and paths whose first folder name isn't plain ASCII.

Hook touches the file only when you press a button, and says **File not found** if it is missing or unreadable. It opens the file it checked, in an app chosen for that type. If the file is replaced after the check, or a folder on its path is a link, Hook beeps and opens nothing.

## Answer an ask

- **Done, Skip or a reply.** A reply is text or one of the offered choices, with its own **Send**. Done never sends or drops anything silently. If a reply is typed but not sent, the bar warns **You have an unsent reply** and offers **Send & Done** or **Discard & Done**.
- **Change a reply.** A sent reply folds to **You replied: … · time** with **Change**. Change brings your last reply back to edit. Sending again posts a new reply, and the agent may already have acted on the first. Earlier replies are under **History**.
- **Answer questions.** A step can ask you to pick one or more options, or type an answer. A question step has no tick; it is done once its answer is sent. Each question has its own **Send**, and ⌘S sends all unsent answers but keeps the ask open. Unsent changes say **Not sent**, and the bar counts unanswered questions.
- **Unsent answers.** With an answer unsent, Done warns **You have an unsent answer**. **Send & Done** sends the answers, then any reply, and closes only if every send worked. **Discard & Done** drops them and closes.
- **Change an answer.** A sent answer folds to **You chose: …** (or **You answered: …**) with its time and **Change**. You can change answers until the ask closes. After that they are read-only until you **Reopen** the ask.
- **A choice with a field.** With a Pond 1.4.0 or newer, a choice can have its own field ("What should change?"). Picking the choice opens the field. Send delivers the choice and your words together, up to 1,000 characters.
- **After Done or Skip**, the panel opens the next ask, or the queue if Settings › Panel says so. An Undo bar shows for 10 seconds. Hook sends your answer only after that.
- **Resume Session**, in a card's context menu or an ask's ⋯ menu, opens a terminal in the session's folder and runs `claude --resume` for that session. It works only for sessions on this Mac; for another Mac, the item is dimmed and names it. If the terminal doesn't open, Hook copies the command and says why. Pick the terminal in Settings › General. Automatic uses the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal.

## Talking to the session

On a Pond, you can send the session that posted an ask a note without opening its terminal. This doesn't work on This Mac.

- **Report a Problem.** An open step with code or a tick has **Report** at its bottom right. The step's context menu and the card's context menu have **Report a Problem…** too. Type what went wrong under **Problem with step 2**, or paste the error. ⌘↩ sends and never presses Done.
- **What the session gets.** The report arrives as a quoted note about that step, never as an instruction. The step shows a filled report icon until the session corrects it. Closed asks don't offer reports.
- **A report needs the owner key.** Without this Mac's [owner key](#the-owner-key), Send opens the key setup and holds the note. The field says **Sends once the owner key is approved.** If the ask closes first, the note is dropped.
- **Messages.** With a Pond 1.2.0 or newer, an open ask has a **Messages** section after the replies. A message is a side note, like typing in the session's chat. It doesn't answer, close or change the ask, and you can't edit it once sent. On an ask that wants a reply, the field is behind **Message the session**. **Message Session…** in a card's context menu opens the field. Only the session that posted the ask sees its messages.
- **Length.** With a Pond 1.4.0 or newer, a message or report takes up to 8,000 characters, and a report keeps its line breaks. An older Pond takes 1,000 characters for a message and 300 for a one-line report. A counter ("7 412 / 8 000") shows past 80 % of the limit. Hook never cuts text silently: a longer paste says **Trim 1 204 characters to send.** and Send stays off.
- The Pond refuses a report or message that looks like a secret. Neither goes into Hook's activity log.

## Crash reports

After Hook quits unexpectedly, the next launch shows a bar: **Hook quit unexpectedly** ("report ready, nothing sent"). If notifications are allowed, one notification points to it.

- **Not Now** drops the report, and Hook won't ask about that crash again.
- **Review…** opens **Send a Crash Report**. It shows when Hook quit, **Send to** (GitHub, or My Pond once the owner key is set up) and **What's sent**, with redacted values tinted. You can copy that text, or show the macOS crash file in Finder (Hook never sends it). Cancel keeps the bar.
- **GitHub** opens a prefilled issue in your browser for you to submit. For a known crash, it opens that issue and puts a comment on the clipboard. If a newer release fixed it, the sheet says "Fixed in 0.x. Update Hook." instead.
- **Send to Pond** files it on your Pond as a Hook bug, without a Telegram message. A Notice says "Sent to your Pond." or how often that crash was reported.

Settings › General › Privacy sets whether Hook asks each time, sends to your Pond automatically, or does nothing. [Privacy](privacy.md) lists what each report holds and sends.

## Corrected asks

A session can correct an open ask, such as a wrong port or a missing step, instead of posting a new one. This needs a Pond 1.1.0 or newer, not This Mac. Each correction is a new version. Every version is hashed and names the hash before it, and Hook remembers every hash it has seen on this Mac. So Hook checks the whole history before it shows anything.

- **The ask locks.** Until you review a correction, a bar replaces Done: **Corrected after you saw it** (or **Corrected before this Mac showed it**). Copy, links, files, answers, ticks and Done are off; **Skip always works.** The card says **Corrected**, and Telegram shows only "Corrected: review in Hook".
- **Review the changes.** **Show Changes** opens a diff from the version you last accepted on this Mac to the newest. If this Mac never showed the ask, you see all of it. **The session says:** lists the session's reasons. Changed, new and moved steps are marked, and unchanged ones are dimmed.
- **Look closer.** Hook flags lines worth a second look: a new host, `sudo`, `rm -rf`, a download piped into a shell, or decoded hidden content. It also flags `eval` and other generated code, characters that aren't plain ASCII, and paths outside the session's folder. These checks are incomplete. No flag never means safe.
- **Use Version N** accepts the version you reviewed. If it changes a command, link or file, Hook asks for Touch ID or your password. If a newer correction arrives during the review, **Show Version 4** brings it in, and the older version can't be accepted any more.
- **After you accept**, ticks and answers stay with their steps by step id, so a moved step keeps its tick. A changed step shows **Changed** and a new one **New**, both unticked.

**When the history changes.** Sometimes the Pond serves a history that doesn't match what this Mac saw: a version is missing, changed or older. A Pond older than 1.1.0 serving a corrected ask counts too. The ask then shows a red bar, **This ask's history changed on the Pond**, and only Skip works. This happens after a Pond restore, or when someone swapped the history. Skip the ask. Only after a restore you made, press **Trust the Pond's History Again…** (Touch ID).

**Review records.** Your accepted versions and the seen hashes live in `reviews.json` in Hook's Application Support folder. A Keychain key ("Hook review seal") seals the file. If macOS asks for your password so Hook can read it, choose Allow. If the Keychain refuses, or `reviews.json` is gone but the key isn't, corrected asks stay locked and a Notice says so. Its **Reset Review Records…** (Touch ID) starts over: every corrected ask needs a new review, and you set up the owner key again. See [SECURITY.md](../SECURITY.md#keychain-items).

## The owner key

The owner key lets the Pond tell your answers apart from a session's. Accepting a correction needs it. Once it is set up, Done, Skip, replies, answers and Reopen send it too. Each Mac makes its own key and keeps it in your Keychain ("Hook owner key"). The Pond stores only its hash, after you approve the Mac on Telegram. The key needs a Pond 1.1.0 or newer at an `https` URL.

1. Open Settings › Queue › **Owner Key** and press **Set Up This Mac…**.
2. Hook shows a six-digit code, and the Pond sends a request to your Telegram.
3. Check that the Hook message in Telegram shows the same code, then tap **Approve**. If the code differs, or you didn't start this, tap **Refuse**: someone is trying to act as you. The request expires after 10 minutes.
4. The row says **Approved**. Other Macs you approved are under **Other Macs**.

The key goes only over https, or plain http to this Mac itself, and only to the scheme it was set up on. Switching the Pond URL to http stops it. If the Pond stops accepting the key (revoked, or the Pond was reset), a Notice says so and the row offers **Set Up Again…**.

**Require the owner key.** With two Macs approved, this one among them, **Require Owner Key…** makes the Pond refuse owner acts without a key. Then sessions and scripts can't answer, press Done or reopen as you. Turning it off waits for your tap on Telegram.

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
| Ask | ⌘L | Focus the reply field (Change on a sent reply); on an ask without a reply prompt, the Messages field |
| Ask | 1–6 | Pick a choice |
| Reply field | Return / ⌥Return | Send / new line |
| Report field | ⌘↩ / Return / Esc | Send / new line / cancel |
| Messages field | ⌘↩ / Return | Send / new line |
| Settings | ⌘1 … ⌘5 | General, Panel, Queue, Notifications, Agents |

## Away mode

Hook marks you away when the screen locks, the displays sleep, you switch users or you connect over Screen Sharing. It also does after you leave the Mac idle for the time in Settings › General (10 minutes by default). You can pick Home or Away yourself from Presence in the menu.

While you're away, "now" asks don't slide the panel in and no notifications show. Your Pond still forwards asks wherever it sends them. The icon fades, the status bar's word starts with "Away", and the menu shows why and since when. When you're back, one notification counts the asks that arrived, for the urgencies on in Notifications. Click it to open the first of them.

Hook also keeps a [flag file](configuration.md#the-away-flag) for other tools.

## Update Hook

Hook checks GitHub for a release a minute after launch, then once a day. **Check for Updates…** in the menu checks now. When a release is out, choose "Update Hook to X.Y.Z…" at the top of the menu. Hook installs it, updates your agents' setup and restarts ([Update](install.md#update)).

## Settings

Settings writes the [config file](configuration.md). Its tabs are General, Panel, Queue, Notifications, Agents (⌘1 … ⌘5):

- **General:** shortcut, presence and away time, Start Hook when I log in, where documents open, and the terminal for Resume Session. Also Privacy (crash reports, log size), appearance, version and updates.
- **Panel:** edge, display, Re-dock Now, whether "now" asks slide the panel in, and what follows Done or Skip.
- **Queue:** This Mac only or Pond, and how long closed asks stay. The Pond URL, token file, context and check interval, saved with the Connect button. The connection, whether the Pond's version suits this Hook, Send a Test Ask, and the [owner key](#the-owner-key).
- **Notifications:** which urgencies notify, sound, permission, and a test notification.
- **Agents:** the coding agents on this Mac and what Hook set up in each. That is the MCP server, the skill, the instructions and the replies hook. For Claude Code, the instructions are the Hook plugin and `~/.claude/rules/hook.md`. A piece you edited says **Edited by you** and stays until you choose. Here too: **Reinstall All**, and whether Hook sets up new agents by itself. `relay integrations` does the same in a terminal ([Agents](agents.md)).

Each "?" button explains its row. A row's second action, such as Show in Finder, is a small icon button after the value; hover it for its name.
