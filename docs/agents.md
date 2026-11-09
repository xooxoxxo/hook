# Agents

Hook sets itself up in every coding agent on your Mac and updates that setup with each release. It tells you when you edit what it wrote, and it removes only what it wrote. [Claude Code](claude-code.md) has its own page.

## What Hook installs

- **MCP server** `relay`: `python3 ~/.local/share/hook/current/mcp/relay_mcp.py`, with the [tools below](#mcp-tools).
- **Skill** `instructables`: when to ask the owner, and how to write the ask. Most agents read `~/.agents/skills/instructables`; a plugin or extension carries its own copy.
- **Instructions**: one short text, `instructions/hook.md` in the release. An agent with a rules folder gets Hook's own file there. Other agents get a block in their instructions file, from `<!-- hook:begin id=instructions … -->` to `<!-- hook:end -->`.
- **Replies hook**: `relay hook replies` shows your answers in the session ([details](#the-replies-hook)), where the agent supports hooks.

Every config points to a stable path, never a versioned folder: `~/.local/share/hook/current/…`, `~/.local/share/hook/plugins/<agent>` or your developer clone. An update changes the files behind those paths, so you never trust or approve a config again.

## When it runs

- **Install and update.** `install.sh` ends with `relay integrations sync`. A first install sets up every agent it finds, even one you removed Hook from (`--include-removed`).
- **The app.** 30 s after launch, if Hook, the agent table or the install changed since the last sync. Then once a day, to find new agents.
- **New agents.** Settings › Agents › Set up new agents automatically is on by default (`relay integrations set auto-setup off`). While it is off, Hook tells you about a new agent, and Set Up adds it.
- **By hand.** Settings › Agents › Reinstall All, Set Up or Update on one agent, or the [commands](#commands).

## The agents

"Your steps" are what only you can do; each arrives once as an ask in your queue. In "Tested on a Mac", **not yet** means a real-Mac check before release. **from docs** means the entry follows the agent's documentation and passes the fixture tests only. `~/.codex`, `~/.copilot` and `~/.pi/agent` follow `CODEX_HOME`, `COPILOT_HOME` and `PI_CODING_AGENT_DIR`.

| Agent | MCP server | Skill | Instructions | Replies | Your steps | Tested on a Mac |
|---|---|---|---|---|---|---|
| Claude Code | `claude mcp add-json --scope user relay` | plugin `hook@hook` | `~/.claude/rules/hook.md` | per prompt (plugin) | none | not yet |
| Codex | `codex mcp add relay` | `~/.agents/skills` | block in `~/.codex/AGENTS.md` (`AGENTS.override.md` when that has text) | per prompt (`~/.codex/hooks.json`) | trust the hook in `/hooks`, once | not yet |
| Gemini CLI | extension, `gemini extensions link` | `~/.agents/skills` | the extension's context file | per prompt (extension) | none | not yet |
| Antigravity CLI | plugin, `agy plugin install` | plugin | a rule in the plugin | session start (plugin) | none | from docs |
| Copilot CLI | `copilot mcp add relay` | `~/.agents/skills` | `~/.copilot/instructions/hook.instructions.md` | session start (`~/.copilot/hooks/hook.json`) | none | not yet |
| VS Code Copilot | Copilot CLI's `~/.copilot/mcp-config.json` | `~/.agents/skills` | Copilot CLI's file | session start (Copilot CLI's file) | none | from docs |
| Cursor | plugin in `~/.cursor/plugins/local/hook` | `~/.agents/skills` | `rules/hook.mdc` in the plugin | session start (plugin) | Reload Window after Hook adds or updates the plugin | not yet |
| OpenCode | `mcp.relay` in `~/.config/opencode/opencode.json` | `~/.agents/skills` | `instructions` in the same file | per prompt (`plugins/hook.ts`) | none | not yet |
| Zed | `context_servers.relay` in `~/.config/zed/settings.json` | `~/.agents/skills` | block in `~/.config/zed/AGENTS.md` | none | none | not yet |
| pi | `mcpServers.relay` in `~/.pi/agent/mcp.json` | `~/.agents/skills` | block in `~/.pi/agent/AGENTS.md` | per prompt (`extensions/hook.ts`) | none | not yet |
| Devin | `devin mcp add -s user relay` | `~/.agents/skills` | `~/.devin/rules/hook.md` | per prompt (`~/.config/devin/config.json`) | none | from docs |
| Factory Droid | `droid mcp add relay` | `~/.agents/skills` | block in `~/.factory/AGENTS.md` | per prompt (`~/.factory/hooks.json`) | none | from docs |
| Kiro | `kiro-cli mcp add --name relay` | `~/.kiro/skills` | `~/.kiro/steering/hook.md` | none | none | from docs |
| Amp | `amp mcp add relay` | `~/.agents/skills` | block in `~/.config/amp/AGENTS.md` | per prompt (`~/.config/amp/plugins/hook.ts`) | none | from docs |
| Cline | `cline mcp add relay` | `~/.agents/skills` | `~/.cline/rules/hook.md` | none | none | from docs |
| Goose | `extensions.relay` in `~/.config/goose/config.yaml` | `~/.agents/skills` | block in `~/.config/goose/.goosehints` | none | none | from docs |
| Junie | `mcpServers.relay` in `~/.junie/mcp/mcp.json` | `~/.agents/skills` | block in `~/.junie/AGENTS.md` | none | none | from docs |
| Warp | `mcpServers.relay` in `~/.warp/.mcp.json` | `~/.agents/skills` | a rule you add in Warp | none | paste Hook's rule into Settings › AI › Rules | from docs |

Without the agent's command, Hook writes the same key into its config file. A **session start** hook shows up to 10 answers from the last 24 h when a session starts. **none** means no hook. For both, the skill and the instructions tell the agent to call `relay_list` at the start of a session and `relay_status {id}` before waiting on an ask.

## Commands

Run `relay integrations` (or `hook integrations`). Every command takes `--json`. `sync`, `reinstall`, `remove` and `migrate` also take `--dry-run`, which prints the plan and changes nothing. `--harness X` takes an id from `integration/harnesses.json`, such as `codex`. `--piece P` takes `mcp`, `skill`, `instructions`, `replies` or `plugin`.

| Command | Does |
|---|---|
| `relay integrations status [--harness X] [--smoke]` | Shows each agent and the state of each piece. States: installed, outdated (Update ready), drifted or foreign (Edited by you), needs-owner or blocked (Needs you), not-set-up. It reads the files, the manifest and the asks' last known states. `--smoke` also runs each agent's own check, such as `claude plugin list` |
| `relay integrations sync [--harness X] [--include-new\|--include-removed\|--only-known] [--if-changed] [--no-asks]` | Installs what's missing, updates what's outdated and posts your steps. It skips edited and blocked items and never prompts. `--include-new` also sets up new agents while automatic setup is off. `--only-known` touches only agents Hook already set up. An agent you removed Hook from stays removed, unless you name it with `--harness X` (Set Up) or pass `--include-removed`. `--if-changed` only prints the status when the last sync is under 24 h old and nothing changed. `--no-asks` posts nothing yet |
| `relay integrations reinstall [--harness X [--piece P]] [--force]` | Writes everything again, even what looks current. Edited items need `--force`, which saves a `.bak` first |
| `relay integrations accept --harness X [--piece P]` | Keeps your edit. The piece stops showing as edited until Hook's text changes or you edit it again |
| `relay integrations diff --harness X [--piece P]` | Prints a unified diff of your edit against Hook's text. Files, blocks, keys and folders only |
| `relay integrations remove (--harness X \| --all) [--force]` | Removes what the manifest records, with the agent's own remove command where it has one. Edited items stay unless you pass `--force`. The agent then stays out of every sync until you [set it up again](#removing-hook) |
| `relay integrations migrate claude-md [--choose CHOICE] [--again]` | Moves Claude Code's old CLAUDE.md section: see [Claude Code](claude-code.md#moving-from-the-setup-before-013) |
| `relay integrations set auto-setup on\|off` | Settings › Agents › Set up new agents automatically |

Exit codes 0, 1, 2 and 4 mean:

- 0: done, skipped and edited items included.
- 1: bad arguments.
- 2: the release's agent table is missing or invalid, or another run held the lock for 30 s.
- 4: at least one item failed.

## Edited files

Hook records the hash of everything it writes. A piece is **Edited by you** when its file changed (drifted), or when Hook finds a file it didn't write in its place (foreign). Hook never overwrites either on its own. A sync you didn't start sends one ask that lists them, with Keep mine or Use Hook's for each file. Your answers run at the next sync.

In Settings › Agents, an edited piece has a Fix… menu:

| Fix… | Command |
|---|---|
| Keep Mine | `relay integrations accept --harness X --piece P` |
| Show Difference | `relay integrations diff --harness X --piece P` |
| Use Hook's | `relay integrations reinstall --force --harness X --piece P` |

Codex reads `AGENTS.override.md` instead of `AGENTS.md` once the override has text, so Hook moves its block there. A block you edited in `AGENTS.md` stays put, where Codex no longer reads it. Keep Mine is off for that piece, because your edit would do nothing. Use Hook's moves the block and saves a `.bak`. Or take your edit out of `AGENTS.md`, and the next sync moves the block.

A file that doesn't parse is **blocked**. Hook leaves it untouched and reports it until you fix it.

## The manifest and backups

The manifest, `~/.config/relay/integrations.json`, records each file, key and block Hook wrote for each agent, with its hash. It also records which agents share a file, the asks Hook posted and the automatic setup setting. Shared files are the skill copy in `~/.agents/skills` and Copilot's `~/.copilot` files. Hook writes each edit to a temporary file, checks it and renames it into place, at a symlink's target.

Before Hook changes a file it didn't create, it saves `<file>.bak` (or `<file>.bak-<time>`) next to it, with the same mode. Folders go to `~/.local/share/hook/backups`. Plugins are built for this Mac in `~/.local/share/hook/plugins/<agent>`.

## Removing Hook

`install.sh --uninstall` runs `relay integrations remove --all` first. Hook takes its key or block out of a shared file and leaves the rest as it was. A shared skill copy goes with the last agent that uses it. Your edited files stay and are listed; `relay integrations remove --all --force` removes them too. Claude Code's old CLAUDE.md section doesn't come back; the uninstaller names its `.bak`.

An agent you remove Hook from (`remove --harness X` or `remove --all`) stays removed. The app's syncs and Reinstall All skip it, even with Set up new agents automatically on, and Hook doesn't offer it as new. Settings › Agents › Set Up or `relay integrations sync --harness X` brings it back. Installing Hook again after `--uninstall` sets up every agent it finds.

## Adding an agent

An agent is data, not code. Add an entry to `integration/harnesses.json` (checked against `integration/harnesses.schema.json`) and its fixture HOME to `clients/test_integrations_fixtures.py`. See [Development](development.md).

## The replies hook

`relay hook replies --format claude|gemini|kiro|cursor|copilot|plain [--when prompt|session-start]` prints your new answers in the shape the agent's hook expects. With nothing new it prints nothing. It never starts Hook, gives up after 2 s and always exits 0. Its 0.12 name, `relay replies --new --hook`, still works.

- **Per prompt** (the default) keeps a cursor for each session in `~/.config/relay/replies-cursor.json`. Like the first `relay replies` in a terminal, its first run only marks where to start.
- **Session start** (`cursor`, `copilot`, or `--when session-start`) shows up to 10 answers from the last 24 h and keeps no cursor.

## MCP tools

- `relay_post {project, instructable}` returns `{id, deduped, openUrl}`.
- `relay_status {id}` returns `status`, `resolvedBy` (`owner`, `session` or null), `ownerEvents`, [`messages`](#messages-and-bug-reports) and `requirements`. `requirements` is `{left, ready}` or null: what the owner must finish before Done ([Before Done](instructables.md#before-done)).
- `relay_list {kind?}` returns every open ask with its `kind`, `ask` or `bug`. Pass `kind` to get only one of them. A bug also carries `count`.
- `relay_amend {id, reason, instructable, baseRev?}` [corrects an open ask](#correcting-an-ask) this Mac posted. It returns `{id, rev, hash, changed, added, removed, moved, top, openUrl}`.

## The `relay` command

The installer also links it as `hook`; both names run the same command. The MCP server and tools keep their `relay` names, so existing sessions, skills and permission lists keep working.

Every command starts Hook if it isn't running, except `relay replies --hook`, `relay hook replies` and `relay wait`.

| Command | Prints |
|---|---|
| `relay post <project> --json -` or `--json <file>` | `posted <id>` or `deduped <id>`, then `open <url>`. Refused: `refused: <error>` and one line per field error on stderr |
| `relay status <id> [--json]` | `<status> (by owner\|by session) · <project> · <title>`, then one line per owner event. With requirements: `Left before Done: step 2, the reply, a message` or `Ready for Done` |
| `relay list [--json] [--kind ask\|bug]` | One line per open ask: `<id> <urgency> <project> · <title>`. A bug report reads `<id> bug ×<count> Hook · <title>` |
| `relay done <id> [note]`, `relay skip <id> [note]` | `done <id>` / `skipped <id>`, or `already <status> (by <actor>) <id>` |
| `relay replies [--new] [--hook]` | One line per new owner answer |
| `relay wait <id> [--timeout SECONDS] [--interval SECONDS] [--after SEQ]` | See [relay wait](#relay-wait) |
| `relay amend <id> --reason TEXT [--base REV] [--json FILE\|-]` | `corrected <id> → version N (changed: step 2; added: step 4). The owner must review it in Hook before acting.` See [Correcting an ask](#correcting-an-ask) |
| `relay --version` | `relay 0.15.3` (`hook --version` prints `hook 0.15.3`) |

Exit codes of these commands: 0 success, 1 refused or not found, 2 no config or Hook unreachable, 3 `relay wait` timed out.

`relay post`, `relay_post` and `relay amend` check the Pond's version before they send a key that needs a newer Pond. When the Pond is too old, they refuse, post nothing and exit 1. [Validation](instructables.md#validation) lists the keys and the messages.

## Correcting an ask

The session that posted an open ask can fix a wrong step in place with `relay amend` or `relay_amend`. It sends the whole corrected instructable and a one-line `reason` (at most 200 characters): what was wrong and what changed.

- **Only the poster.** A post to Pond 1.1.0 or newer makes an edit key for the ask. The key is a `0600` file in `~/.local/state/relay/edit-keys`, a `0700` folder (`$RELAY_EDIT_KEY_DIR` overrides it). The Pond stores only the key's hash, and a key only ever goes to the Pond it was made for. Without the key, the answer is `No edit key for ask <id> on this Mac`: close the ask and post a new one.
- **Keep the step ids.** Read them with `relay status <id> --json` (field `instructable`) and keep each one. Leave ids out only on new steps. An ask posted without ids has the Pond's (`s1`, `s2`, `s2.1`). `title`, `urgency` and `from` can't change.
- **Start from the newest version.** If the ask changed since this Mac last wrote it, `relay amend` refuses with `Ask <id> changed since you last wrote it (version N).` Read it again and correct that. To correct an older version on purpose, pass `--base REV` (`baseRev`).
- **Limits.** At most 10 corrections per ask, at least 60 s apart.
- **The owner reviews it.** The ask is locked on the owner's Mac until they accept the correction in Hook ([Corrected asks](using.md#corrected-asks)). Each answer carries the version it answered. `relay status --json` and `relay_status` show `rev`, `acceptedRev` and `editable`. They mark an answer `stale` when its question changed since, and list answers to removed steps under `earlier`.
- **When it can't.** Close the ask (`relay done <id>`) and post a new one. An older Pond says ``Your Pond (V) is older than `amend` needs (Pond 1.1.0 or newer). Update the Pond, or close this ask and post a new one.`` A Pond with corrections off says `The Pond doesn't take corrections yet.` This Mac mode says `This Mac mode can't correct asks yet`.

## `relay wait`

A session that needs your answer runs `relay wait <id>` in the background after posting. When you answer, it prints `[<project>] <title>`, one `  ↳ owner <kind> <at>: <text>` line per answer and `last seq: <n>`, then exits.

You can answer step questions one at a time. `relay wait` wakes on those answers only after 10 s pass with no newer one, so a burst of taps wakes the session once. Done, Skip and a reply wake it at once. Each answer prints as `  ↳ owner answer <path>: <value>`, for example `3.2: Staging`. Then come `answered <X> of <Y>; open: <paths>` (no `; open:` when nothing is open) and `last seq: <n>`.

`relay status` adds an `Answers (X of Y):` block with each question's prompt and your latest answer, then `Unanswered: <paths>`. `relay status --json` and `relay_status` add `answers` and `unanswered`, and `ownerEvents` includes the `answer` events. `relay replies` and the replies hook show `Hook: [<id>] <project> · <title> — answer <path>: <value>`.

With no answer, `relay wait` exits 3 after `--timeout` (default 8 h). Pass `--after <last seq>` to wait for the next answer.

## Messages and bug reports

These need Pond 1.2.0 or newer.

- **Messages.** From an ask's Messages section in Hook, the owner can message the session that posted it. A message is chat: it never answers the ask, a step question or the reply prompt, and closes nothing. `relay wait` wakes on one and prints `  ↳ owner message, quoted: "<text>"`. `relay status` lists it as `<at> message: "<text>"`. `relay status --json` and `relay_status` carry `messages: [{text, at, verified}]`.
- **Messages in the replies hook.** It shows `Hook: [<id>] <project> · "<title>" — owner message, quoted: "<text>"` only to the session that posted the ask, which its edit-key file names. Problem reports work the same way. A hook that can't name its session shows no messages.
- **Unverified messages.** A message is the owner's only when Hook signed it with this Mac's owner key (`verified: true`). Any session on the Mac holds the shared Pond token. A message written with it carries `verified: false` and prints as `unverified message (not from the owner's key): "<text>"`, never as `owner message`. Sessions treat it as data and report it to the owner. Set up this Mac's [owner key](using.md#the-owner-key) so your own messages arrive verified.
- **Bug reports.** Hook files its own crash reports in project `Hook` as asks of kind `bug`, one per crash signature, with a count. `relay list --kind bug` and `relay_list {kind: "bug"}` list the open ones. Close a fixed one with `relay done <id> "<what changed>"`. A Pond 1.1.0 ignores `kind`, so the client filters by each item's `kind` itself. This Mac mode has no bug reports.

## Reopened asks

Reopen adds a `reopened` owner event to `relay status`, `replies`, `wait` and `relay_status`. The ask counts as open until a later Done or Skip.
