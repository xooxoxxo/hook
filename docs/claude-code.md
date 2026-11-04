# Claude Code

Hook sets up Claude Code like every other agent ([agents.md](agents.md)), with a plugin of its own. The MCP tools, the `relay` command and the replies hook are the same for every agent: see [agents.md](agents.md#mcp-tools).

## What Hook installs

- **MCP server:** `claude mcp add-json --scope user relay`, running `~/.local/share/hook/current/mcp/relay_mcp.py`. It is a user-scope server, not the plugin's, because a plugin's server would rename the tools (`mcp__plugin_hook_relay__*`) and break permission lists.
- **The Hook plugin,** `hook@hook`, from a local marketplace in `~/.local/share/hook/plugins/claude` (`claude plugin marketplace add`, then `claude plugin install hook@hook --scope user`). It carries the `instructables` skill and the replies hook, `relay hook replies --format claude` on every prompt. An update runs `claude plugin marketplace update hook`.
- **The rules file** `~/.claude/rules/hook.md`: Hook's instructions. Hook owns this file; to change what your sessions are told, add your own rules beside it.

`claude mcp get relay` and `claude plugin list` (it lists `hook@hook`) check it; `relay integrations status --harness claude-code --smoke` runs both.

## Moving from the setup before 0.13

Before 0.13, the installer ran `claude mcp add` and linked the skill into `~/.claude/skills/instructables`, Settings › Connect added a replies hook to `~/.claude/settings.json`, and you pasted a section into `~/.claude/CLAUDE.md`. The first sync moves each one, once the plugin and the rules file are in place, so no session goes without the hook or the text:

1. **MCP server:** kept when it is Hook's, replaced when it runs another copy of `mcp/relay_mcp.py`, and otherwise left alone.
2. **Skill link:** removed when it links into a Hook copy. A real folder, or a link elsewhere, stays.
3. **Settings hook:** each `relay replies --new` hook under `UserPromptSubmit` is removed, with a `.bak`, only after the plugin's own hook runs. Nothing else in the file changes.
4. **CLAUDE.md section** ("Owner asks go to Hook", or "…Relay", found by its heading): a text a Hook release shipped is removed at once, with a `.bak`. A section you edited gets a proposal, `~/.local/state/relay/integrations/claude-md-proposal.md`, and one ask: Apply, Remove the whole section, or Keep CLAUDE.md as is. Apply keeps your own lines under the heading, marked `<!-- hook:migrated v=1 -->`, with a line pointing at the rules file. Your answer applies at the next sync, and only while the section is still the one proposed. Settings › Agents › Claude Code shows the step while it waits.

By hand: `relay integrations migrate claude-md` makes the proposal, `--choose "Apply"` (or `"Remove the whole section"`, `"Keep CLAUDE.md as is"`) answers it, and `--again` proposes again after Keep. Removing Hook never puts the section back; the uninstaller names the `.bak`.
