# Privacy

What Hook records about itself, what a crash report holds, and where it can go. Nothing leaves your Mac unless you act, except **Send Automatically** to your own Pond. With crash reports **Off**, Hook sends and shows nothing. Asks are covered in the [Security model](security.md).

## The activity log

- **Where:** `~/Library/Logs/Hook/hook.log`. Settings › General › Privacy › Activity log shows its size, with a Finder button. Each line also goes to the system log (subsystem `Hook`).
- **What it records:** one line per typed event, so free text can't slip in:
  - launch and quit, with the Hook and macOS versions and the CPU type. A quit line says if the quit was clean, and its cause. The cause is your Quit command, the updater, the installer, a second copy, logout, restart, shutdown, another app's quit request or Hook's own code. A SIGTERM or SIGHUP adds the sender's process id and name;
  - MetricKit's diagnostics for Hook, one line each: crashes, hangs, CPU and disk-write exceptions, with numbers and the version only;
  - screens you open: the queue, an ask (never which one), each Settings tab, Welcome, About, the crash report window;
  - actions, by name only: Done, Skip, Reply, Answer, Report, Message, Copy, Open, Tick, Accept, Undo, Update and Send crash report;
  - the queue source (This Mac or Pond) and the Pond's version;
  - away mode changes, with the reason ("screen locked");
  - a crash found at launch, by its signature;
  - errors: their type and a redacted message of at most 200 characters. A failed Pond request adds its HTTP status and route template (`asks/{id}/reply`). Its message is a fixed phrase: the Pond's own error ("ask is closed"), a URLError code or one of Hook's. A Pond that keeps failing the same way is logged once, until a request works.
- **What it never records:** ask ids, titles, step text, replies, answers, notes or messages. Nor file paths inside asks, tokens, the owner key or the Pond's address.
- **Redaction.** Before Hook writes an error's message, your home folder becomes `~` and your user name `<user>`. URLs, hosts and IP addresses become `<host>`, and ids `<id>`. Anything token-like becomes `<redacted>`: bearer tokens, `key=…`, GitHub, OpenAI and Slack tokens, email addresses, and long hex or mixed runs.
- **Size:** at 512 KB the log rolls to `hook.1.log`, so the two files stay under 1 MB. Hook writes each line at once, so the last lines survive a crash.
- **It stays on this Mac** unless you send a crash report. The updater keeps its own `update.log` beside it.

## Save Diagnostics

Settings › General › Privacy › **Save Diagnostics…** writes one text file, wherever you choose, to attach to an issue. It holds:

- the Hook and macOS versions, and the copies of Hook that LaunchServices and Spotlight know;
- the LaunchAgent's state, last exit code and run count;
- `run-state.json` and `launches.json`;
- the last 300 lines of the activity log and 100 of `update.log`;
- the names, dates and sizes of Hook's crash files;
- the last 2 hours of system log lines from runningboardd, launchd and loginwindow that name Hook.

It is redacted like a crash report, and this Mac's names show as `<host>`. Nothing is sent.

## Crash data

- **The run marker.** At launch Hook writes `run-state.json` (its process id, version and start time) in `~/Library/Application Support/Relay/`. A normal macOS quit marks it clean, with the quit's cause and time. A marker that isn't clean at the next launch means the last run ended badly. A clean quit with a cause other than you, logout, shutdown, the updater or the installer means something else closed Hook. The next launch offers that like a crash, as **Hook was closed: <cause>**. The installer and updater write `quit-request.json` there just before they quit Hook, so their quits never count.
- **The launch guards.** `launches.json` keeps the last few starts, and whether each one lived 15 seconds. If the last three each ended sooner, Hook starts without the crash offer, the update check and the agents sync, and says so. `crash-offer.json` records a crash as Hook offers it. If Hook ends within 20 seconds of the offer, that crash isn't offered again.
- **The crash file.** macOS writes a crash report (`Hook-….ips`) to `~/Library/Logs/DiagnosticReports/`. Hook reads only the newest one after the last run's start. It takes only the exception type, the signal, the termination reason and the crashed thread's top frames in Hook's own code. Without a crash file (a hang, a force quit, a kill), the report carries only the log. Hook never attaches or sends the `.ips`. **Show in Finder** in the crash report window shows it to you.
- **The signature** is 12 hex characters: a SHA-256 over the exception and Hook's top three frames. It names the crash without describing it. Hook raises each crash once: Not Now or a send remembers it. A run without a crash file (a kill, or something else closed Hook) is remembered on its own, so the next one is raised too.

## What a report contains

The sheet shows exactly what a send delivers, with every redaction placeholder tinted:

- the title (`Hook crash: <exception> in <frame> (<signature>)`) and the line `Crash signature: hook-crash-<signature>`;
- the Hook and macOS versions and the CPU type;
- the source (This Mac or Pond) and the Pond's version;
- the exception, signal and termination reason, and Hook's own frames by symbol name;
- the last 40 log lines.

Nothing else is added. The redactor runs over the whole text a second time before Hook shows or sends it.

## Sending a report

After a crash, a bar docks at the bottom of the panel: **Hook quit unexpectedly**, with **Not Now** and **Review…**. If notifications are allowed, one points to the bar. A crash never asks for notification permission. **Review…** opens **Send a Crash Report**. Settings › General › Privacy › **Send to** picks where the report goes.

### GitHub (the default)

Nothing goes to GitHub until you submit the issue yourself, in your browser.

1. When the crash report window opens, Hook searches the Hook repo's issues once for `hook-crash-<signature>`, with no login, no cookies and a 5-second timeout. GitHub sees the signature, which is a hash, and your IP address. Nothing else leaves the Mac.
2. The result decides the button:
   - **No issue yet:** Open Issue on GitHub… opens a new issue, prefilled with the title and the report.
   - **An open issue:** Add to #N… opens it and copies a comment for you to paste (GitHub can't prefill one).
   - **Closed in a newer release:** "Fixed in 0.x. Update Hook." with Update Hook.
   - **Closed otherwise:** a new issue that starts "Possibly the same as #N".
   - **No answer** (rate-limited, offline): Check for an Existing Issue opens the search page, and Open New Issue opens a prefilled issue.

   Anyone can open an issue that quotes a signature, so only a trusted issue counts as open or "possibly the same". A trusted issue was filed by the repo's owner, a member or a collaborator, or a maintainer labeled it `crash-confirmed`. Hook ignores any other match and offers a new issue. It only opens links to an issue page in the Hook repo.
3. A prefilled link stays under 6,000 characters: Hook drops the oldest log lines to fit. If it dropped any, the sheet says so first, and the full report goes to the clipboard too.

### My Pond

Offered once your queue is a Pond and this Mac's owner key is approved. **Send to Pond** files the report on your Pond as an ask in project "Hook", signed with the owner key. On Pond 1.2.0 or later it is a Hook bug, which sends no Telegram message. A repeat of an open bug's signature adds an occurrence, not a new item. An older Pond gets a plain ask, which notifies like any other. Hook cuts the report to 4,000 characters, oldest log lines first. Sessions can find bugs with `relay list --kind bug`.

## Settings

Settings › General › Privacy, saved in [config.json](configuration.md):

| Setting | Key | Values |
|---|---|---|
| Crash reports | `crashReports` | Ask Each Time (`ask`, the default): the bar, then the crash report window. Send Automatically (`auto`): with My Pond as the target, the report goes there with no bar. The bar comes back if the send fails. With GitHub, it works like Ask Each Time. Off (`off`): no bar, no notification, no send, only the log line |
| Send to | `crashReportTarget` | GitHub (`github`, the default) or My Pond (`pond`). A saved `pond` without a Pond and an approved owner key reads as GitHub |

Hook links no crash-reporting service. A future one would start only with your consent, never while Crash reports is Off. The release notes and [SECURITY.md](../SECURITY.md#crash-reports-and-the-activity-log) would name it.

## Reports and messages to a session

Report a Problem and Messages go to your Pond, and from there only to the session that posted the ask. The Pond refuses a note or a message that looks like a secret. Hook never writes them to the activity log.
