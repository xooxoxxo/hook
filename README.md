# Relay

[![CI](https://github.com/xooxoxxo/relay/actions/workflows/ci.yml/badge.svg)](https://github.com/xooxoxxo/relay/actions/workflows/ci.yml)

A small native macOS menu-bar app for **instructables**: asks from coding agents
(Claude Code sessions, scripts) that need you, written as exact numbered steps with
copy-paste commands. An agent posts an ask. Relay shows it in a sidebar with Copy
buttons and a notification. You press Done, Skip or Reply, and the agent reads your
answer.

Relay has two modes, chosen in Settings › Queue or by `scripts/install.sh`:

| Mode | Where asks live | Use it when |
|---|---|---|
| **This Mac only** (`"source": "local"`) | In Relay itself: `~/Library/Application Support/Relay/queue.json`, served on `127.0.0.1` | Agents and you are on the same Mac. Nothing leaves the machine |
| **Mailbox** (`"source": "mailbox"`) | A mailbox service you run; Relay polls it. Relay does not include one: see the [mailbox protocol](docs/mailbox-protocol.md) | You run a service that speaks the protocol, and asks should reach you away from the Mac |

<!-- screenshot: docs/sidebar.png -->

## Requirements

- macOS 14.5 or later to build, because the Swift 6 toolchain (Xcode or Command Line
  Tools 16) requires it. The built app runs on macOS 14.
- The Xcode Command Line Tools, with Swift 6 or newer.
- Python 3.9 or newer.

No third-party dependencies.

## Install

```bash
xcode-select -p || xcode-select --install
git clone https://github.com/xooxoxxo/relay.git
cd relay
./scripts/install.sh            # a new install starts in "This Mac only" mode
```

Keep the clone where it is: the `relay` command, the MCP server and the skill run from
it, so moving or deleting it breaks them. If you move it, rerun `./scripts/install.sh`
from the new place.

| Invocation | Config effect |
|---|---|
| `./scripts/install.sh` | Keeps the existing config; a new install gets `{"source":"local"}` |
| `./scripts/install.sh --local` | Switches to This Mac only |
| `./scripts/install.sh --mailbox <dir>` | Switches to the mailbox in `<dir>/mailbox-url` (an http(s) URL); `<dir>/mailbox-token` must be non-empty. Only the token file's path is stored |
| `./scripts/install.sh --uninstall` | Removes the app, LaunchAgent, CLI link, MCP server and this repo's skill link. Keeps the config, token and queue, and prints their paths |

The installer:
1. checks macOS, Swift and Python, and stops with the exact fix if one is missing;
2. writes `~/.config/relay/config.json` (folder `0700`, file `0600`), keeping every key
   already there; a config that doesn't parse is moved to `config.json.bad-<time>`;
3. builds `./build/Relay.app` and, only if the build succeeds, replaces
   `~/Applications/Relay.app` (a failed build leaves the running app alone);
4. links the `relay` command to `~/.local/bin/relay`, unless another `relay` is there,
   and prints the line to add to `~/.zshrc` if `~/.local/bin` isn't on your `PATH`;
5. registers the MCP server with
   `claude mcp add --scope user relay -- python3 "<repo>/mcp/relay_mcp.py"`, or prints
   that command to run later when `claude` isn't installed or the registration fails;
6. links the skill to `~/.claude/skills/instructables`, unless something else is there;
7. writes the "Launch at login" LaunchAgent,
   `~/Library/LaunchAgents/io.github.xooxoxxo.relay.plist`, on a first install or when
   it already exists (turning it off in Settings sticks across updates), and removes
   the LaunchAgent of pre-release builds (`dev.instructables.relay`) if there is one;
8. starts Relay and checks `http://127.0.0.1:<port>/health` on the configured port
   (47823 unless `port` says otherwise).

**Update:** `git pull && ./scripts/install.sh`. The config is kept.

**Uninstall:** `./scripts/install.sh --uninstall`. To remove everything, also delete
the clone, `~/Library/Application Support/Relay` and `~/.config/relay`, and run
`defaults delete io.github.xooxoxxo.relay` to clear the app's UI state. The
uninstaller prints that last command when it finishes.

## Using Relay

- **Menu bar.** Click the checklist icon to show or hide the sidebar. Right-click it
  (or Control-click) for Refresh, Settings… and Quit Relay.
- **Shortcut.** ⌃⌥⌘R shows or hides the sidebar from anywhere. Change it, or turn it
  off, in Settings › General.
- **Badge.** A red badge on the icon means asks are waiting. It shows the count from 1
  to 9, and a plain dot from 10 up or when "Show the count on the badge" is off.
- **Sidebar keys.** ↑ and ↓ move, ↩ opens an ask, Esc goes back or hides the sidebar,
  ⌘↩ is Done, ⌘R refreshes and ⌘, opens Settings.
- **In an ask.** Tick steps as you go. Copy puts exactly the code shown on the
  clipboard, without a trailing newline, so a paste never runs on its own. Answer with
  Done, Skip or Reply.
- **Undo.** After Done or Skip, an Undo bar shows for 10 seconds. ⌘Z or Undo brings
  the ask back; Relay sends your answer only after that.
- **Closed today.** A collapsed group at the bottom of the sidebar lists the asks
  closed today, each with Reopen.
- **From.** An ask shows where it came from (folder · Mac · short session id) and,
  when the session is known, a command to resume it in Claude Code.
- **First launch** asks for permission to show notifications.

Settings has four tabs:
- **General:** the shortcut, start at login, the badge count, the sidebar edge and the
  appearance.
- **Queue:** where asks come from (This Mac only or Mailbox), how long finished asks
  are kept, the mailbox address, token file and check interval, and a test ask.
- **Notifications:** which urgencies notify, the sound, and whether "now" asks slide
  the sidebar in.
- **Connect:** what Claude Code needs: the MCP server, the CLAUDE.md section with a
  Copy button, the skill and the replies hook.

## Use it from Claude Code

- **MCP** (registered by the installer): `relay_post {project, instructable}` returns
  `{id, deduped, openUrl}`; `relay_status {id}` returns `status`, `resolvedBy`
  (`owner`, `session` or null) and `ownerEvents`; `relay_list {}` returns every open
  ask.
- **Skill:** `skill/instructables/SKILL.md` tells sessions when to ask and how to write
  a good instructable.
- **CLAUDE.md:** paste [`docs/claude-md-section.md`](docs/claude-md-section.md) into
  `~/.claude/CLAUDE.md` (Settings › Connect has a Copy button).
- **CLI** (`relay`, Python 3.9+, standard library only). Commands start Relay if it
  isn't running, except `relay replies --hook` and `relay wait`:

  | Command | Prints |
  |---|---|
  | `relay post <project> --json -` or `--json <file>` | `posted <id>` or `deduped <id>`, then `open <url>`. Refused: `refused: <error>` and one line per field error on stderr |
  | `relay status <id> [--json]` | `<status> (by owner\|by session) · <project> · <title>`, then one line per owner event |
  | `relay list [--json]` | One line per open ask: `<id> <urgency> <project> · <title>` |
  | `relay done <id> [note]`, `relay skip <id> [note]` | `done <id>` / `skipped <id>`, or `already <status> (by <actor>) <id>` |
  | `relay replies [--new] [--hook]` | One line per new owner answer |
  | `relay wait <id> [--timeout SECONDS] [--interval SECONDS] [--after SEQ]` | Waits for the owner's answer to one ask, then prints `[<project>] <title>`, one `  ↳ owner <kind> <at>: <text>` line per answer and `last seq: <n>` |
  | `relay --version` | `relay 0.3.0` |

  Exit codes: 0 success, 1 refused or not found, 2 no config or Relay unreachable,
  3 `relay wait` timed out.

- **Replies hook (optional).** Add this to `~/.claude/settings.json` and each new
  owner answer appears in the next prompt of every session:

  ```json
  {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "relay replies --new --hook", "timeout": 5}]}]}}
  ```

  It prints nothing when there's nothing new, never starts Relay, gives up after 2 s
  and always exits 0. The `timeout` makes Claude Code end it if it ever hangs. Each
  session keeps its own cursor in `~/.config/relay/replies-cursor.json`. A session's
  first run (and the first `relay replies` in a terminal) prints nothing: it only
  marks where to start.
- **`relay wait`.** When a session can't go on without the answer, it runs
  `relay wait <id>` in the background right after posting. The command exits when the
  owner answers. With no answer it exits 3 after `--timeout` (default 8 h). To wait
  for the next answer to the same ask, pass `--after <last seq>`.

## Configuration

`~/.config/relay/config.json`; `$RELAY_CONFIG` overrides the path, and `local-token`
and `replies-cursor.json` live next to whichever file is used. The Settings window
edits the same file, and Relay applies changes to it without a restart. It never
contains a token.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `source` | `"local"` \| `"mailbox"` | `"mailbox"` when `mailboxURL` is set | Where asks live |
| `mailboxURL` | http(s) string | — | Mailbox mode: the service's base URL |
| `tokenFile` | path | — | Mailbox mode: file holding the mailbox's bearer token |
| `context` | string | `"personal"` | Mailbox mode: sent with every post |
| `port` | 1–65535 | 47823 | The `127.0.0.1` listener |
| `pollSeconds` | int ≥ 1 | 15 | Mailbox mode: how often to check |
| `hotkey` | string | `"ctrl+opt+cmd+r"` | Shows or hides the sidebar; `""` turns it off |
| `keepDays` | 1–365 | 14 | This Mac only: how long finished asks are kept |
| `showCount` | bool | true | The badge shows the open count from 1 to 9; from 10 up, or when false, it is a plain dot |
| `sidebarEdge` | `"right"` \| `"left"` | `"right"` | Which screen edge the sidebar docks to |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | All windows |
| `notify` | object | `{"now":true,"today":true,"whenever":false,"sound":false,"slideIn":true}` | Which urgencies notify, sound, and whether "now" asks slide the sidebar in |
| `repoPath` | path | — | Written by the installer; Settings › Connect builds its commands from it |

A missing, wrong-typed or out-of-range key takes its default; only JSON that doesn't
parse, or a bad `port`, makes the file invalid. While Relay runs, a broken edit keeps
the last good config in use and shows a note.

## Instructable format

An ask is a `project` plus an instructable. This is version 1 of the format:

```json
{
  "v": 1,
  "title": "Create a Slack channel for Acme",
  "why": "The daily brief needs a destination",
  "urgency": "today",
  "steps": [
    {"do": "Open Slack → + next to Channels → Create channel", "where": "Slack"},
    {"do": "Check Node", "where": "Terminal", "code": "node --version", "lang": "bash", "expect": "v22.13 or higher"}
  ],
  "verify": {"do": "Confirm it worked", "expect": "The channel is listed"},
  "reply": {"prompt": "Which channel?", "choices": ["#acme-brief", "#acme-team"]},
  "links": [{"label": "Spec", "url": "https://example.com/spec"}]
}
```

| Key | Rule |
|---|---|
| `v` | `1` |
| `title` | required, ≤ 120 chars, imperative; the 24 h dedupe key |
| `why` | ≤ 300 |
| `urgency` | `now`, `today` (default) or `whenever` |
| `steps` | required, 1–20 Steps |
| `verify` | one Step |
| `reply` | `prompt` ≤ 300, `choices` 0–6 strings of ≤ 60 |
| `links` | 0–10 `{label ≤ 60, url}` |
| `from` | `{session, host, cwd}`, filled by the poster |

A **Step** is
`{do (required, ≤ 300), where ≤ 60, code ≤ 4000, lang ≤ 20, expect ≤ 300, url}`.

The **`project`** is required: one line, at most 60 characters.

Validation rules:
- URLs must be http(s).
- Unknown keys are rejected.
- The total size must be ≤ 32 KB.
- Strings that look like secrets (`sk-ant-`, `sk-…`, `xox[abp]-`, `ghp_`,
  `github_pat_`, `AKIA…`, private-key blocks) are rejected, and so are hidden
  characters that could disguise them. Ask the owner to store secrets in the Keychain
  instead.
- The JSON Schema is in [`schema/instructable.v1.json`](schema/instructable.v1.json).
- Errors name field paths only (`steps[2].url: must be http(s)`), never values.

## Troubleshooting

- **Relay isn't running, or `relay` exits 2.** Run `open -a Relay`, then `relay list`
  to check that it answers.
- **"Port 47823 is in use by another app".** Set `port` in
  `~/.config/relay/config.json` to a free port. Relay and the clients follow it.
- **`relay_post` is missing in Claude Code.** Run `claude mcp list` and look for
  `relay`. If it isn't there, rerun `./scripts/install.sh`, then restart your Claude
  Code sessions.
- **No notifications.** Turn them on in System Settings › Notifications › Relay.
- **The shortcut doesn't work.** Another app owns it. Pick a new one in
  Settings › General.
- **Mailbox unreachable.** The menu-bar icon dims and the sidebar footer shows
  `Mailbox · offline:` and the reason. Check the address and token file in
  Settings › Queue, and that the service answers. `relay list` prints the error too.

## Security

- In This Mac only mode, the queue never leaves the Mac and Relay makes no outbound
  connections.
- The API listens on `127.0.0.1` only and needs a 256-bit token, kept in a `0600`
  file.
- Agents can't record owner answers. Only the app can.
- Browser requests are refused, and the clients check a server proof before they
  send the token.
- Relay refuses config, token and queue files that another user owns or can write to.
- Ask text is shown with hidden characters made visible, and links show their real
  host.

The full model is in [docs/security.md](docs/security.md). To report a vulnerability,
see [SECURITY.md](SECURITY.md).

## Reference

- [Local API](docs/local-api.md): the `127.0.0.1` API that the CLI and MCP server use.
- [Mailbox protocol](docs/mailbox-protocol.md): what a mailbox service must answer.
- [Security model](docs/security.md).

## Development

```bash
swift build && swift test                                   # RelayCore tests (Swift Testing)
python3 -m unittest discover -s clients -p 'test_*.py' -v   # CLI and client
python3 -m unittest discover -s mcp -p 'test_*.py' -v       # MCP server
BUILD_ONLY=1 ./scripts/build.sh                             # assembles ./build/Relay.app, installs nothing
./scripts/test-install.sh                                   # installer, in a sandbox HOME
./scripts/smoke-local.sh                                    # This Mac only, end to end
```

`Tests/RelayCoreTests/Fixtures/instructable-vectors.json` is the validator's source of
truth: the validator tests run against it, and it is maintained by hand.

Test-only switches: `RELAY_DATA_DIR` moves the app's queue folder;
`RELAY_NO_AUTOLAUNCH=1` stops the `relay` CLI from ever starting Relay (the smoke run
sets it, so it can't touch an installed app); `scripts/install.sh` honours
`RELAY_SKIP_BUILD`, `RELAY_SKIP_LAUNCH` and `RELAY_SKIP_MCP` (see its header).

## Contributing

Issues and pull requests are welcome. Before you open a pull request, run the test
commands above. Keep the Python files under `bin/`, `clients/` and `mcp/` compatible
with Python 3.9 (`/usr/bin/python3`) and standard library only, and add no
third-party Swift packages.

## License

MIT. See [LICENSE](LICENSE).
