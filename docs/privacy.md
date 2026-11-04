# Privacy

What Hook records about itself, what a crash report holds, and where it can go. Nothing leaves your Mac without an action from you, apart from **Send Automatically** to your own Pond. With crash reports **Off**, Hook sends nothing and shows nothing. Asks are covered in [Security model](security.md).

## The activity log

- **Where:** `~/Library/Logs/Hook/hook.log`. Settings › General › Privacy › Activity log shows its size, with a Finder button. Each line is also mirrored to the system log (subsystem `Hook`).
- **What it records:** one line per typed event, so free text can't slip in:
  - launch and quit, with the Hook and macOS versions and the CPU type, whether the quit was clean, and its cause: your Quit command, the updater, the installer, a second copy, logout, restart or shutdown, a SIGTERM or SIGHUP with the sending process's id and name, another app's quit request, or Hook's own code;
  - MetricKit's diagnostics for Hook, one line each: crashes, hangs, CPU and disk-write exceptions, with numbers and the version only;
  - screens you open: the queue, an ask (never which one), each Settings tab, Welcome, About and the crash sheet;
  - actions by name only: Done, Skip, Reply, Answer, Report, Message, Copy, Open, Tick, Accept, Undo, Update and Send crash report;
  - the queue source (This Mac or Pond) and the Pond's version;
  - away mode changes, with the reason ("screen locked");
  - a crash found at launch, by its signature;
  - errors: their type and a redacted message of at most 200 characters. A failed Pond request also has its HTTP status and its route as a template (`asks/{id}/reply`), and its message is a fixed phrase: the Pond's own error ("ask is closed"), a URLError code or one of Hook's. A Pond that keeps failing the same way is logged once, until a request works again.
- **What it never records:** ask ids, titles, step text, replies, answers, notes, messages, file paths inside asks, tokens, the owner key and the Pond's address.
- **Redaction.** An error's message is redacted before it is written: your home folder becomes `~`, your user name `<user>`, URLs, hosts and IP addresses `<host>`, ids `<id>`, and anything token-like (bearer tokens, `key=…`, GitHub, OpenAI and Slack tokens, email addresses, long hex or mixed runs) `<redacted>`.
- **Size:** at 512 KB it rolls to `hook.1.log`, so the two files stay under 1 MB. Each line is written at once, so the last lines survive a crash.
- **It stays on this Mac** unless you send a crash report. The updater keeps its own log next to it, `update.log`.

## Save Diagnostics

Settings › General › Privacy › **Save Diagnostics…** writes one text file wherever you choose, to attach to an issue: the Hook and macOS versions, the copies of Hook that LaunchServices and Spotlight know, the LaunchAgent's state, last exit code and run count, `run-state.json` and `launches.json`, the last 300 lines of the activity log and 100 of `update.log`, the names, dates and sizes of Hook's crash files, and the last 2 hours of system log lines from runningboardd, launchd and loginwindow that name Hook. It is redacted like a crash report, and this Mac's names show as `<host>`. Nothing is sent.

## Crash data

- **The run marker.** At launch Hook writes `run-state.json` (its process id, version and start time) in `~/Library/Application Support/Relay/`, and marks it clean, with the quit's cause and time, when it quits through macOS's normal path. A marker that isn't clean at the next launch means the last run ended badly. A clean one whose cause wasn't yours, a logout or shutdown, the updater or the installer means something else closed Hook: the next launch offers it like a crash, as **Hook was closed: <cause>**. The installer and updater leave `quit-request.json` there just before they quit Hook, so their quits never count.
- **The launch guards.** `launches.json` keeps the last few starts and whether each lived 15 seconds. When the last three each ended sooner, Hook starts without the crash offer, the update check and the agents sync, and says so. `crash-offer.json` records a crash as it is offered; if Hook ends within 20 seconds of offering it, that crash isn't offered again.
- **The crash file.** macOS writes a crash report (`Hook-….ips`) to `~/Library/Logs/DiagnosticReports/`. Hook reads only the newest one after the last run's start, and from it only the exception type, the signal, the termination reason and the crashed thread's top frames in Hook's own code. Without one (a hang, a force quit, a kill), the report carries only the log. The `.ips` itself is never attached or sent; **Show in Finder** in the sheet shows it to you.
- **The signature** is 12 hex characters: a SHA-256 over the exception and Hook's top three frames. It names the crash without describing it. Each crash is raised once: Not Now or a send remembers it. A run without a crash file (a kill, or something closed Hook) is remembered by itself, so the next one is raised too.

## What a report contains

The sheet shows exactly what a send delivers, with every redaction placeholder tinted:

- the title (`Hook crash: <exception> in <frame> (<signature>)`) and the line `Crash signature: hook-crash-<signature>`;
- the Hook and macOS versions and the CPU type;
- the source (This Mac or Pond) and the Pond's version;
- the exception, signal and termination reason, and Hook's own frames by symbol name;
- the last 40 log lines.

Nothing else is added. The whole text goes through the redactor a second time before it is shown or sent, on top of the log's own redaction.

## Sending a report

After a crash, a bar docks at the bottom of the panel: **Hook quit unexpectedly**, with **Not Now** and **Review…**. If notifications are allowed, one notification points to it; a crash never asks for notification permission. Review… opens **Send a Crash Report**. Settings › General › Privacy › **Send to** picks where it goes.

### GitHub (the default)

Nothing is sent to GitHub until you submit the issue yourself in your browser.

1. When the sheet opens, Hook makes one unauthenticated search of the Hook repo's issues for `hook-crash-<signature>`, with a 5-second timeout and no cookies. GitHub sees the signature, which is a hash, and your IP address. Nothing else leaves the Mac.
2. What it found decides the button:
   - **No issue yet:** Open Issue on GitHub… opens a new issue, prefilled with the title and the report.
   - **An open issue:** Add to #N… opens it and copies a comment for you to paste (GitHub can't prefill a comment).
   - **Closed in a newer release:** "Fixed in 0.x. Update Hook." with Update Hook.
   - **Closed otherwise:** a new issue that starts "Possibly the same as #N".
   - **No answer** (rate-limited, offline): Check for an Existing Issue opens the search page, and Open New Issue opens a prefilled issue.

   Anyone can open an issue that quotes a signature, so only a trusted issue counts as open or "possibly the same": one filed by the repo's owner, a member or a collaborator, or one a maintainer labeled `crash-confirmed`. Any other match is ignored and you get a new issue. Hook only opens links to an issue page in the Hook repo.
3. A prefilled link stays under 6,000 characters by dropping the oldest log lines. When anything was dropped, the sheet says so first, and the full report also goes to the clipboard.

### My Pond

Offered once your queue is a Pond and this Mac's owner key is approved. **Send to Pond** files the report on your own Pond as an ask in project "Hook", signed with the owner key. On Pond 1.2.0 or later it is a Hook bug: it sends no Telegram message, and a repeat of an open bug's signature adds an occurrence instead of a new item. An older Pond gets a plain ask, which notifies like any other. The report is cut to 4,000 characters, oldest log lines first. Sessions can pick bugs up with `relay list --kind bug`.

## Settings

Settings › General › Privacy, saved in [config.json](configuration.md):

| Setting | Key | Values |
|---|---|---|
| Crash reports | `crashReports` | Ask Each Time (`ask`, the default): the bar, then the sheet. Send Automatically (`auto`): with My Pond as the target, the report goes there with no bar (the bar comes back if the send fails); with GitHub, it works like Ask Each Time. Off (`off`): no bar, no notification, no send; only the log line |
| Send to | `crashReportTarget` | GitHub (`github`, the default) or My Pond (`pond`). A saved `pond` without a Pond and an approved owner key reads as GitHub |

No crash-reporting service is linked. If one is added later, it will start only with your consent, never while Crash reports is Off, and it will be named in the release notes and in [SECURITY.md](../SECURITY.md#crash-reports-and-the-activity-log).

## Reports and messages to a session

Report a Problem and Messages go to your Pond, and from there only to the session that posted the ask. The Pond refuses a note or a message that looks like a secret. They are never written to the activity log.
