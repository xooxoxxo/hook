# Agents

Hook sets itself up in every coding agent it finds on your Mac, keeps that setup in step with each Hook update, tells you when you've edited something it wrote, and removes exactly what it wrote. [Claude Code](claude-code.md) has a page of its own.

## What Hook installs

Four pieces, each the agent's own way of taking it:

- **MCP server** `relay`: `python3 ~/.local/share/hook/current/mcp/relay_mcp.py`, with the tools [below](#mcp-tools).
- **Skill** `instructables`: when to ask the owner and how to write the ask. Most agents read the copy in `~/.agents/skills/instructables`; a plugin or extension carries its own.
- **Instructions**: one short text for every agent, `instructions/hook.md` in the release. It goes in a file Hook owns where the agent reads a folder of rules, otherwise in a marked block, `<!-- hook:begin id=instructions … -->` to `<!-- hook:end -->`, in the agent's instructions file.
- **Replies hook**: `relay hook replies`, which shows your answers in the session ([below](#the-replies-hook)), where the agent has a hook for it.

Every config names a stable path: `~/.local/share/hook/current/…`, `~/.local/share/hook/plugins/<agent>` or your developer clone, never a versioned folder. An update changes what those paths hold, not the config, so nothing has to be trusted or approved again.

## When it runs

- **Install and update.** `install.sh` ends with `relay integrations sync`. A first install sets up every agent it finds, including one you removed Hook from before (`--include-removed`).
- **The app.** 30 s after launch when Hook, the agent table or the install changed since the last sync, and once a day, to find agents installed since.
- **New agents.** Set up automatically while Settings › Agents › Set up new agents automatically is on (the default; `relay integrations set auto-setup off`). Off, Hook tells you it found one and Set Up adds it.
- **By hand.** Settings › Agents › Reinstall All, Set Up or Update on one agent, or the commands [below](#commands).

## The agents

"Your steps" are what only you can do; each arrives once as an ask in your queue. "Tested on a Mac": **not yet** means the entry is checked on a real Mac before release, **from docs** that it follows the agent's documentation and the fixture tests only. `~/.codex`, `~/.copilot` and `~/.pi/agent` follow `CODEX_HOME`, `COPILOT_HOME` and `PI_CODING_AGENT_DIR`.

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

Where the agent's command isn't installed, Hook writes the same key into its config file instead. With **session start** the hook shows the last 24 h of answers, at most 10, when a session starts; with **none** there is no hook. The skill and the instructions tell those agents to call `relay_list` at the start of a session and `relay_status {id}` before waiting on an ask.

## Commands

`relay integrations` (or `hook integrations`). Every command takes `--json`; the writing ones take `--dry-run`, which prints what it would do and changes nothing. `--harness X` takes an id from `integration/harnesses.json`, such as `codex`, and `--piece P` one of `mcp`, `skill`, `instructions`, `replies` or `plugin`.

| Command | Does |
|---|---|
| `relay integrations status [--harness X] [--smoke]` | Each agent found and each piece: installed, outdated (Update ready), drifted or foreign (Edited by you), needs-owner or blocked (Needs you), not-set-up. It reads files, the manifest and the asks' last known states; `--smoke` also runs the agents' own checks, such as `claude plugin list` |
| `relay integrations sync [--harness X] [--include-new\|--include-removed\|--only-known] [--if-changed] [--no-asks]` | Installs what's missing and updates what's outdated, leaves edited and blocked items alone, and posts your steps. It never prompts. `--include-new` also sets up new agents while automatic setup is off, `--only-known` only the ones Hook already set up; an agent you removed Hook from stays removed unless you name it with `--harness X` (Set Up) or pass `--include-removed` (what a first install does); `--if-changed` only prints the status when nothing changed in the last 24 h; `--no-asks` posts nothing yet |
| `relay integrations reinstall [--harness X [--piece P]] [--force]` | Writes everything again, even what looks current. Edited items need `--force`, which saves a `.bak` first |
| `relay integrations accept --harness X [--piece P]` | Keeps your edit: the piece stops showing as edited until Hook's own text changes or you edit it again |
| `relay integrations diff --harness X [--piece P]` | Prints your edit against Hook's text, as a unified diff, to stdout. For files, blocks, keys and folders only |
| `relay integrations remove (--harness X \| --all) [--force]` | Removes what the manifest records, with the agent's own remove command where it has one. Edited items stay unless `--force`. The agent stays removed: no sync, the app's included, sets it up again until `sync --harness X` (Set Up) |
| `relay integrations migrate claude-md [--choose CHOICE] [--again]` | Claude Code's CLAUDE.md section: see [Claude Code](claude-code.md#moving-from-the-setup-before-013) |
| `relay integrations set auto-setup on\|off` | Settings › Agents › Set up new agents automatically |

Exit codes: 0 done, skipped and edited items included; 1 bad arguments; 2 the release's agent table is missing or invalid, or another run held the lock for 30 s; 4 at least one item failed.

## Edited files

Hook records the hash of everything it writes. When the file no longer matches, the piece is **Edited by you** (drifted), and when Hook finds a file it didn't write where its own would go, the same (foreign). Hook never overwrites either on its own. A sync you didn't start sends one ask listing them, with Keep mine or Use Hook's per file; your answers run at the next sync.

In Settings › Agents, an edited piece has a Fix… menu:

| Fix… | Command |
|---|---|
| Keep Mine | `relay integrations accept --harness X --piece P` |
| Show Difference | `relay integrations diff --harness X --piece P` |
| Use Hook's | `relay integrations reinstall --force --harness X --piece P` |

Codex reads `AGENTS.override.md` instead of `AGENTS.md` once the override has text, so Hook moves its block there. If you had edited Hook's block in `AGENTS.md`, it stays put and Codex no longer reads it: Keep Mine is off for that piece, because the edit would do nothing there. Use Hook's moves the block (with a `.bak`), or take your edit out of `AGENTS.md` and the next sync moves it.

A file that doesn't parse is **blocked**: Hook leaves its bytes untouched and reports it until you fix it.

## The manifest and backups

`~/.config/relay/integrations.json` records, per agent, every file, key and block Hook wrote, its hash, which agents share it (the skill copy in `~/.agents/skills`, Copilot's `~/.copilot` files), the asks it posted and the automatic setup setting. Edits are written to a temporary file, checked and renamed into place, at a symlink's target.

Before Hook changes a file it didn't create, it saves `<file>.bak` next to it (or `<file>.bak-<time>`), with the file's mode. Folders are saved to `~/.local/share/hook/backups`. Plugins are rendered for this Mac into `~/.local/share/hook/plugins/<agent>`.

## Removing Hook

`install.sh --uninstall` runs `relay integrations remove --all` first. A key or block is taken out of a shared file and the rest of the file is left as it was; a shared skill copy goes when the last agent using it does. What you edited stays and is listed; `relay integrations remove --all --force` removes that too. Claude Code's old CLAUDE.md section isn't put back; the uninstaller names its `.bak`.

An agent you remove Hook from, with `remove --harness X` or `remove --all`, stays removed: the manifest lists it, and neither the app's syncs nor Reinstall All set it up again, even with Set up new agents automatically on. It isn't offered as new either. Settings › Agents › Set Up, or `relay integrations sync --harness X`, brings it back. Installing Hook again after `--uninstall` sets up every agent it finds.

## Adding an agent

An agent is a data change: an entry in `integration/harnesses.json`, checked against `integration/harnesses.schema.json`, plus its fixture HOME in `clients/test_integrations_fixtures.py`. The installer has no agent-specific code. See [Development](development.md).

## The replies hook

`relay hook replies --format claude|gemini|kiro|cursor|copilot|plain [--when prompt|session-start]` prints your new answers in the shape the agent's hook expects. It prints nothing when nothing is new, never starts Hook, gives up after 2 s and always exits 0. `relay replies --new --hook` is its 0.12 name and still works.

- **Per prompt** (the default) keeps a cursor per session in `~/.config/relay/replies-cursor.json`. Its first run, like the first `relay replies` in a terminal, only marks where to start.
- **Session start** (`cursor`, `copilot`, or `--when session-start`) shows the last 24 h, at most 10, and keeps no cursor.

## MCP tools

- `relay_post {project, instructable}` returns `{id, deduped, openUrl}`.
- `relay_status {id}` returns `status`, `resolvedBy` (`owner`, `session` or null), `ownerEvents`, `messages` ([below](#messages-and-bug-reports)) and `requirements` (`{left, ready}` or null: what the owner must finish before Done, [Before Done](instructables.md#before-done)).
- `relay_list {kind?}` returns every open ask, each with its `kind` (`ask` or `bug`); `kind` lists only one of them, and a bug also carries `count`.
- `relay_amend {id, reason, instructable, baseRev?}` corrects an open ask this Mac posted and returns `{id, rev, hash, changed, added, removed, moved, top, openUrl}` ([below](#correcting-an-ask)).

## The `relay` command

The installer also links it as `hook`; both names run the same command. The MCP server and tools keep their `relay` names, so existing sessions, skills and permission lists keep working.

Commands start Hook if it isn't running, except `relay replies --hook`, `relay hook replies` and `relay wait`.

| Command | Prints |
|---|---|
| `relay post <project> --json -` or `--json <file>` | `posted <id>` or `deduped <id>`, then `open <url>`. Refused: `refused: <error>` and one line per field error on stderr |
| `relay status <id> [--json]` | `<status> (by owner\|by session) · <project> · <title>`, then one line per owner event; on an ask with requirements, `Left before Done: step 2, the reply, a message` or `Ready for Done` |
| `relay list [--json] [--kind ask\|bug]` | One line per open ask: `<id> <urgency> <project> · <title>`; a bug report reads `<id> bug ×<count> Hook · <title>` |
| `relay done <id> [note]`, `relay skip <id> [note]` | `done <id>` / `skipped <id>`, or `already <status> (by <actor>) <id>` |
| `relay replies [--new] [--hook]` | One line per new owner answer |
| `relay wait <id> [--timeout SECONDS] [--interval SECONDS] [--after SEQ]` | See [below](#relay-wait) |
| `relay amend <id> --reason TEXT [--base REV] [--json FILE\|-]` | `corrected <id> → version N (changed: step 2; added: step 4). The owner must review it in Hook before acting.` See [below](#correcting-an-ask) |
| `relay --version` | `relay 0.15.0` (`hook --version` prints `hook 0.15.0`) |

`relay post` and `relay_post` check the Pond's version (`GET /version`, cached for 5 minutes) before posting an instructable that uses `question`, `blocking`, `warning`, `optional`, `file` or a link's `path` (Pond 1.0.0 or newer) or step `id`s (1.1.0 or newer), or `required` or `done` (1.3.0 or newer). `relay amend` checks the corrected instructable the same way, after the lint. Pond versions follow semver, so a newer minor or patch Pond never stops a key working ([Pond versions](mailbox-protocol.md#pond-versions)). A Pond too old for a key makes them refuse with ``Your Pond (V) is older than `<key>` needs (Pond N or newer). Update the Pond, or leave the key out.`` and exit 1; nothing is posted. In This Mac mode the refusal is ``Hook's This Mac queue (Pond V) can't take `<key>` yet.`` A Pond without `/version` counts as protocol 1, too old for any of these keys; one whose answer can't be read is unknown, and the instructable is posted for the Pond to validate. See [Instructable format](instructables.md#validation).

Exit codes of these commands: 0 success, 1 refused or not found, 2 no config or Hook unreachable, 3 `relay wait` timed out.

## Correcting an ask

When a step of an open ask is wrong, the session that posted it can correct it in place with `relay amend` or `relay_amend`, instead of closing it and posting a new one. It sends the whole corrected instructable and a one-line `reason` (at most 200 characters) saying what was wrong and what changed.

- **Only the poster.** Posting to a Pond 1.1.0 or newer makes an edit key for the ask, kept in a `0600` file in `~/.local/state/relay/edit-keys` (a `0700` folder; `$RELAY_EDIT_KEY_DIR` overrides it). The Pond stores only the key's hash, and a key is only ever sent to the Pond it was made for. Without it the answer is `No edit key for ask <id> on this Mac`; close the ask and post a new one.
- **Keep the step ids.** Read them with `relay status <id> --json` (field `instructable`) and keep each one; leave ids out only on new steps. An ask posted without ids has the Pond's (`s1`, `s2`, `s2.1`). `title`, `urgency` and `from` can't change.
- **Based on the newest version.** The correction names the version it starts from. If the ask changed since this Mac last wrote it, `relay amend` refuses with `Ask <id> changed since you last wrote it (version N).`: read it again and correct from that, or pass `--base REV` (`baseRev`) to correct an older version on purpose.
- **Limits.** At most 10 corrections per ask, at least 60 s apart.
- **The owner reviews it.** Until the owner accepts the correction in Hook, the ask is locked on their Mac ([Corrected asks](using.md#corrected-asks)). Answers carry the version they answered: `relay status --json` and `relay_status` show `rev`, `acceptedRev` and `editable`, mark an answer to a question that changed since as `stale`, and list answers to removed steps under `earlier`.
- **Where it can't.** An older Pond refuses with ``Your Pond (V) is older than `amend` needs (Pond 1.1.0 or newer). Update the Pond, or close this ask and post a new one.``; a Pond with corrections switched off gives `The Pond doesn't take corrections yet.`; This Mac mode says `This Mac mode can't correct asks yet`. In each case, close the ask (`relay done <id>`) and post a new one.

## `relay wait`

A session that needs your answer runs `relay wait <id>` in the background after posting. When you answer, it prints `[<project>] <title>`, one `  ↳ owner <kind> <at>: <text>` line per answer and `last seq: <n>`, and exits.

An ask can carry per-step questions that you answer one by one without closing it. `relay wait` also wakes on those answers, but settles first: after an answer it keeps polling until 10 s pass with no newer one, so a burst of taps wakes the session once (Done, Skip and a reply still wake it at once). Each answer prints as `  ↳ owner answer <path>: <value>` (for example `3.2: Staging`), followed by `answered <X> of <Y>; open: <paths>` (the `; open:` part is left out when nothing is open) and `last seq: <n>`.

`relay status` adds an `Answers (X of Y):` block with each question's prompt and your latest answer under it, then `Unanswered: <paths>`; `relay status --json` and the MCP `relay_status` gain `answers` and `unanswered`, and `ownerEvents` includes the `answer` events. `relay replies` and the replies hook show them as `Hook: [<id>] <project> · <title> — answer <path>: <value>`.

With no answer it exits 3 after `--timeout` (default 8 h). Pass `--after <last seq>` to wait for the next answer.

## Messages and bug reports

With a Pond 1.2.0 or newer:

- **Messages.** The owner can message the session that posted an ask from the Messages section in Hook. A message is the owner typing as in chat: it never answers the ask, a step question or a reply prompt, and closes nothing. `relay wait` wakes on one and prints `  ↳ owner message, quoted: "<text>"` on one line. The replies hook shows `Hook: [<id>] <project> · "<title>" — owner message, quoted: "<text>"` only to the session that posted the ask (its edit-key file names it), like problem reports; a hook that can't name its session shows none. `relay status` lists it as `<at> message: "<text>"`, and `relay status --json` and `relay_status` carry `messages: [{text, at, verified}]`.
- **Unverified messages.** A message counts as the owner's only when Hook signed it with this Mac's owner key (`verified: true`). One written with the shared Pond token, which any session on the Mac holds, prints as `unverified message (not from the owner's key): "<text>"` in `relay wait`, the replies hook and `relay status`, never as `owner message`, and carries `verified: false`. Sessions treat it as data and report it to the owner. Set up this Mac's [owner key](using.md#the-owner-key) so your own messages arrive verified.
- **Bug reports.** Hook files its own crash reports in project `Hook` as asks of kind `bug`, one per crash signature, with how often it happened. `relay list --kind bug` and `relay_list {kind: "bug"}` list the open ones; close one with `relay done <id> "<what changed>"` once it is fixed. A Pond 1.1.0 ignores `kind`, so the client filters by each item's `kind` itself; This Mac has no bug reports.

## Reopened asks

Reopen adds a `reopened` owner event, shown by `relay status`, `replies`, `wait` and `relay_status`. The ask counts as open until a later Done or Skip.
