# Claude Code

Hook sets up Claude Code like every other agent ([agents.md](agents.md)), plus a plugin of its own. The MCP tools, the `relay` command and the replies hook are the same everywhere ([MCP tools](agents.md#mcp-tools)).

## What Hook installs

- **MCP server:** `claude mcp add-json --scope user relay`, running `~/.local/share/hook/current/mcp/relay_mcp.py`. It is a user-scope server because a plugin's server would rename the tools (`mcp__plugin_hook_relay__*`) and break permission lists.
- **The Hook plugin** `hook@hook`, from a local marketplace in `~/.local/share/hook/plugins/claude` (`claude plugin marketplace add`, then `claude plugin install hook@hook --scope user`). It carries the `instructables` skill and the replies hook, which runs `relay hook replies --format claude` on every prompt. Updates run `claude plugin marketplace update hook`.
- **The rules file** `~/.claude/rules/hook.md`: Hook's instructions. Hook owns it. To change what sessions are told, add your own rules beside it.

Check with `claude mcp get relay` and `claude plugin list` (it lists `hook@hook`), or run both with `relay integrations status --harness claude-code --smoke`.

## Moving from the setup before 0.13

Before 0.13, the installer ran `claude mcp add` and linked the skill into `~/.claude/skills/instructables`. Settings › Connect added a replies hook to `~/.claude/settings.json`, and you pasted a section into `~/.claude/CLAUDE.md`. The first sync moves each one after the plugin and rules file are in place, so no session loses the hook or the text:

1. **MCP server:** kept when it is Hook's, replaced when it runs another copy of `mcp/relay_mcp.py`, else left alone.
2. **Skill link:** removed when it points into a Hook copy. A real folder, or a link elsewhere, stays.
3. **Settings hook:** each `relay replies --new` hook under `UserPromptSubmit` is removed, with a `.bak`, once the plugin's hook runs. Nothing else in the file changes.
4. **CLAUDE.md section,** found by its heading ("Owner asks go to Hook" or "…Relay"). Text a Hook release shipped is removed at once, with a `.bak`. An edited section gets a proposal, `~/.local/state/relay/integrations/claude-md-proposal.md`, and one ask: Apply, Remove the whole section, or Keep CLAUDE.md as is. Apply keeps your lines under the heading, marked `<!-- hook:migrated v=1 -->`, plus a line pointing to the rules file. The answer applies at the next sync, while the section still matches the proposal. Settings › Agents › Claude Code shows the step while it waits.

By hand: `relay integrations migrate claude-md` makes the proposal. `--choose "Apply"` (or `"Remove the whole section"`, `"Keep CLAUDE.md as is"`) answers it, and `--again` proposes again after Keep. Removing Hook never puts the section back; the uninstaller names the `.bak`.
