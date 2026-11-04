"""relay_migrate_claude: Claude Code moves from the old setup (a `claude mcp` server pointing
anywhere, a skill symlink, a replies hook in settings.json, a pasted CLAUDE.md section) to the
Hook plugin and ~/.claude/rules/hook.md. A temp HOME, a fake `claude` and a fake Hook queue;
fixture text uses ~/.claude/my-tools/ask.py, never real names. Standard library only."""
from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))

import relay_edits as ed  # noqa: E402
import relay_migrate_claude as mc  # noqa: E402
from integration_kit import ROOT, SECRET, World, real_table  # noqa: E402

LEGACY = ROOT / "integration" / "src" / "legacy" / "claude-md-sections"

SETTINGS = '''{
  "permissions": {
    "allow": ["Bash(git status)"]
  },
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/my-tools/check.sh"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "relay replies --new --hook", "timeout": 5}]}
    ]
  },
  "model": "opus"
}
'''
SETTINGS_AFTER = '''{
  "permissions": {
    "allow": ["Bash(git status)"]
  },
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/my-tools/check.sh"}]}
    ]
  },
  "model": "opus"
}
'''

BEFORE = '''# Global notes

Prefer small diffs.

## Owner asks

Keep these short.

'''
SECTION = '''# Owner asks go to Hook (formerly Relay) as instructables

The moment a step needs the owner (a key or token, a decision, a manual
command), send ONE instructable (format and writing rules: the `instructables` skill):

- MCP (preferred): `relay_post {project, instructable}`; `relay_status`, `relay_list`.
- Fallback: `python3 ~/.claude/my-tools/ask.py post <project> --json -`

`<project>` is the ledger project name, i.e. the key in `~/.claude/my-tools/projects.yaml`.
Steps are a puppet script: one action each, exact copy-paste `code`.

- If your work waits on the answer, run `relay wait <id>` in the background.
- Never put a secret or its value in an ask.

**Why:** "waiting on you" lines get lost in the stream of session messages.

'''
AFTER = '''# Multi-agent rules

- Run at most 3 background agents.

## Owner asks

Not this one.
'''
PROPOSED = '''# Owner asks go to Hook (formerly Relay) as instructables
<!-- hook:migrated v=1 -->

Hook's own rules are in `~/.claude/rules/hook.md`.

- Fallback: `python3 ~/.claude/my-tools/ask.py post <project> --json -`

`<project>` is the ledger project name, i.e. the key in `~/.claude/my-tools/projects.yaml`.
Steps are a puppet script: one action each, exact copy-paste `code`.

'''
TITLE = "Move the Hook section out of ~/.claude/CLAUDE.md"


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, "utf-8")
    return path


class UnitTest(unittest.TestCase):
    def test_find_section_by_heading(self):
        text = BEFORE + SECTION + AFTER
        start, end, heading = mc.find_section(text)
        self.assertEqual(text[start:end], SECTION)
        self.assertEqual(heading, "# Owner asks go to Hook (formerly Relay) as instructables")
        self.assertIsNone(mc.find_section(BEFORE + AFTER))
        sub = "# Top\n\n## Owner asks go to Relay\n\nx\n\n### More\n\ny\n\n## Next\n"
        start, end, _ = mc.find_section(sub)
        self.assertEqual(sub[start:end], "## Owner asks go to Relay\n\nx\n\n### More\n\ny\n\n")
        fenced = "# Owner asks go to Hook\n\n```\n# not a heading\n```\n\nz\n"
        start, end, _ = mc.find_section(fenced)
        self.assertEqual(fenced[start:end], fenced)
        self.assertIsNone(mc.find_section(PROPOSED + AFTER))           # migrated: skipped
        self.assertIsNone(mc.find_section("# Owner asks go to Hookers\n"))

    def test_a_hook_block_counts(self):
        text = "# Mine\n\n<!-- hook:begin id=instructions v=1 sha=0123456789abcdef -->\nbody\n<!-- hook:end -->\n\n# B\n"
        start, end, heading = mc.find_section(text)
        self.assertEqual(text[start:end], "<!-- hook:begin id=instructions v=1 sha=0123456789abcdef -->\nbody\n<!-- hook:end -->\n\n")

    def test_personal_remainder(self):
        body = SECTION.split("\n", 1)[1]
        kept = mc.personal_remainder(body)
        self.assertEqual(kept, PROPOSED.split("Hook's own rules are in `~/.claude/rules/hook.md`.\n\n", 1)[1].rstrip("\n"))
        self.assertEqual(mc.personal_remainder("- Run `/my-ask` by hand.\n- Plain text.\n"), "- Run `/my-ask` by hand.")
        self.assertEqual(mc.personal_remainder("See ~/.config/relay/config.json and ~/.local/share/hook/current.\n"), "")
        self.assertEqual(mc.personal_remainder("Open https://example.com/a/b for docs.\n"), "")
        self.assertEqual(mc.personal_remainder("Done/Skip/Reply come back.\n"), "")
        self.assertEqual(mc.personal_remainder("```bash\nmytool run --fast\n```\n"), "```bash\nmytool run --fast\n```")

    def test_legacy_texts_are_the_released_ones(self):
        names = sorted(p.name for p in LEGACY.glob("*.md"))
        self.assertEqual(names, ["v0.2.0.md", "v0.8.0.md"])
        self.assertEqual((LEGACY / "v0.8.0.md").read_text("utf-8"),
                         (ROOT / "docs" / "claude-md-section.md").read_text("utf-8"))
        try:
            old = subprocess.run(["git", "-C", str(ROOT), "show", "v0.2.0:docs/claude-md-section.md"],
                                 capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return
        if old.returncode == 0:
            self.assertEqual((LEGACY / "v0.2.0.md").read_text("utf-8"), old.stdout)


class Base(unittest.TestCase):
    cli = True

    def setUp(self):
        self.w = World([copy.deepcopy(e) for e in real_table() if e["id"] == "claude-code"])
        self.w.rules_from_table()
        if self.cli:
            self.w.add_cli("claude")
        self.home = self.w.home
        self.claude = self.home / ".claude"
        write(self.home / ".claude.json", json.dumps({"mcpServers": {"github": {"command": "npx", "env": {"T": SECRET}}}},
                                                     indent=2) + "\n")
        write(self.claude / "settings.json", SETTINGS)
        self.hub = self.w.hub

    def tearDown(self):
        self.w.close()

    def sync(self, *extra):
        rc, out, err = self.w.run("sync", *extra)
        self.assertEqual(rc, 0, out + err)
        return out + err

    def migration(self, mid):
        return next((m for m in self.w.manifest()["migrations"] if m["id"] == mid), None)

    def mcp_calls(self):
        return [c["argv"][:2] for c in self.w.calls() if c["argv"][:1] == ["mcp"]]

    def set_relay(self, value):
        path = self.home / ".claude.json"
        path.write_text(ed.json_set(path.read_text(), ["mcpServers", "relay"], value))


class McpTest(Base):
    def test_adopt_when_args_are_hooks_server(self):
        server = str(self.w.link_root / "mcp" / "relay_mcp.py")
        self.set_relay({"type": "stdio", "command": "python3", "args": [server], "env": {}})
        before = (self.home / ".claude.json").read_text()
        self.sync()
        self.assertEqual(self.mcp_calls(), [])
        self.assertEqual((self.home / ".claude.json").read_text(), before)
        self.assertEqual(self.w.piece("claude-code", "mcp")["state"], "installed")
        self.assertEqual(self.migration("claude-mcp")["state"], "adopted")

    def test_replace_when_args_point_at_another_hook(self):
        self.set_relay({"type": "stdio", "command": "python3", "args": ["/Users/me/src/hook/mcp/relay_mcp.py"]})
        self.sync()
        self.assertEqual(self.mcp_calls(), [["mcp", "remove"], ["mcp", "add-json"]])
        self.assertEqual(self.w.piece("claude-code", "mcp")["state"], "installed")
        self.assertEqual(self.migration("claude-mcp")["state"], "replaced")

    def test_foreign_is_left_alone(self):
        self.set_relay({"command": "node", "args": ["other-relay.js"]})
        before = (self.home / ".claude.json").read_text()
        self.sync()
        self.assertEqual(self.mcp_calls(), [])
        self.assertEqual((self.home / ".claude.json").read_text(), before)
        self.assertEqual(self.w.piece("claude-code", "mcp")["state"], "drifted")     # foreign shows as drifted
        self.assertEqual(self.migration("claude-mcp")["state"], "foreign")


class SkillAndHookTest(Base):
    def test_release_link_is_removed(self):
        link = self.claude / "skills" / "instructables"
        link.parent.mkdir(parents=True)
        link.symlink_to(self.home / ".local" / "share" / "hook" / "0.12.0" / "skill" / "instructables")
        self.sync()
        self.assertFalse(link.is_symlink() or link.exists())
        self.assertEqual(self.migration("claude-skill")["state"], "removed")

    def test_clone_link_is_removed(self):
        clone = self.w.root / "src" / "hook"
        write(clone / "mcp" / "relay_mcp.py", "")
        write(clone / "skill" / "instructables" / "SKILL.md", "---\nname: instructables\n---\n")
        link = self.claude / "skills" / "instructables"
        link.parent.mkdir(parents=True)
        link.symlink_to(clone / "skill" / "instructables")
        self.sync()
        self.assertFalse(link.is_symlink())
        self.assertTrue((clone / "skill" / "instructables" / "SKILL.md").is_file())    # the clone is untouched

    def test_a_real_folder_is_foreign_and_kept(self):
        skill = write(self.claude / "skills" / "instructables" / "SKILL.md", "mine\n")
        self.sync()
        self.assertEqual(skill.read_text(), "mine\n")
        rec = self.migration("claude-skill")
        self.assertEqual(rec["state"], "foreign")
        self.assertIn("a second instructables skill", rec["note"])

    def test_the_legacy_hook_is_removed_and_the_rest_kept(self):
        self.sync()
        self.assertEqual((self.claude / "settings.json").read_text(), SETTINGS_AFTER)
        self.assertEqual((self.claude / "settings.json.bak").read_text(), SETTINGS)
        rec = self.migration("claude-hook")
        self.assertEqual(rec["state"], "removed")
        self.sync()
        self.assertEqual((self.claude / "settings.json").read_text(), SETTINGS_AFTER)
        self.assertEqual(sorted(p.name for p in self.claude.iterdir() if ".bak" in p.name), ["settings.json.bak"])

    def test_an_unparseable_settings_file_is_left(self):
        bad = write(self.claude / "settings.json", '{"hooks": ')
        self.sync()
        self.assertEqual(bad.read_text(), '{"hooks": ')
        self.assertEqual(self.migration("claude-hook")["state"], "blocked")


class NoPluginTest(Base):
    cli = False

    def test_nothing_moves_before_the_plugin_is_installed(self):
        link = self.claude / "skills" / "instructables"
        link.parent.mkdir(parents=True)
        link.symlink_to(self.home / ".local" / "share" / "hook" / "0.12.0" / "skill" / "instructables")
        write(self.claude / "CLAUDE.md", "# Mine\n\n" + (LEGACY / "v0.8.0.md").read_text())
        before = self.w.snapshot(skip=[".config", ".local/share/hook"])
        self.sync()
        after = self.w.snapshot(skip=[".config", ".local/share/hook"])
        changed = sorted(k for k in after if before.get(k) != after[k])
        self.assertEqual(changed, [".claude/rules", ".claude/rules/hook.md"])
        self.assertTrue(link.is_symlink())


class ClaudeMdTest(Base):
    def md(self):
        return self.claude / "CLAUDE.md"

    def test_a_known_text_is_removed_at_once(self):
        for name in ("v0.2.0.md", "v0.8.0.md", "current"):
            with self.subTest(name):
                if name == "current":
                    text = (self.w.link_root / "integration" / "instructions" / "hook.md").read_text().split("\n", 1)[1]
                else:
                    text = (LEGACY / name).read_text()
                write(self.md(), "# My notes\n\nPrefer small diffs.\n\n" + text + "\n# Later\n\nkeep\n")
                for bak in self.claude.glob("CLAUDE.md.bak*"):
                    bak.unlink()
                self.w.run("migrate", "claude-md", "--again")
                self.sync()
                self.assertEqual(self.md().read_text(), "# My notes\n\nPrefer small diffs.\n\n# Later\n\nkeep\n")
                self.assertEqual(self.migration("claude-md")["state"], "removed")
                self.assertEqual(len(list(self.claude.glob("CLAUDE.md.bak*"))), 1)
        write(self.md(), "# My notes\n\n" + (LEGACY / "v0.8.0.md").read_text())
        self.w.run("migrate", "claude-md", "--again")
        self.sync()
        self.assertEqual(self.md().read_text(), "# My notes\n")
        self.assertFalse(any(t == TITLE for t in self.hub.titles()))

    def test_a_known_hook_block_is_removed(self):
        body = (self.w.link_root / "integration" / "instructions" / "hook.md").read_text()
        write(self.md(), "# Mine\n\n" + ed.md_set_block("", "instructions", body, 1) + "\n# B\n")
        self.sync()
        self.assertEqual(self.md().read_text(), "# Mine\n\n# B\n")

    def propose(self):
        write(self.md(), BEFORE + SECTION + AFTER)
        self.sync()
        post = self.hub.last("Move the Hook section")
        return post

    def test_a_hand_written_section_is_proposed_then_applied(self):
        post = self.propose()
        doc = post["instructable"]
        self.assertEqual(doc["title"], TITLE)
        self.assertEqual(self.md().read_text(), BEFORE + SECTION + AFTER)       # nothing yet
        proposal = self.home / ".local" / "state" / "relay" / "integrations" / "claude-md-proposal.md"
        self.assertEqual(doc["steps"][0]["file"], "~/.local/state/relay/integrations/claude-md-proposal.md")
        self.assertEqual(doc["steps"][1]["question"]["choices"],
                         ["Apply", "Remove the whole section", "Keep CLAUDE.md as is"])
        text = proposal.read_text()
        self.assertIn(SECTION.rstrip("\n"), text)
        self.assertIn(PROPOSED.rstrip("\n"), text)
        self.assertIn("\n-- If your work waits on the answer", text)          # the diff drops it
        self.assertIn(mc.sha256(SECTION), text)
        rec = self.migration("claude-md")
        self.assertEqual((rec["state"], rec["askId"]), ("proposed", post["id"]))
        st = self.w.status()
        self.assertEqual(st["migrations"][-1]["id"], "claude-md")
        self.assertNotIn(SECRET, json.dumps(st) + self.hub.text())
        self.sync()                                                          # no answer: nothing
        self.assertEqual(self.hub.titles().count(TITLE), 1)
        self.hub.answer(post["id"], "2", "Apply")
        self.sync()
        self.assertEqual(self.md().read_text(), BEFORE + PROPOSED + AFTER)
        self.assertEqual((self.claude / "CLAUDE.md.bak").read_text(), BEFORE + SECTION + AFTER)
        self.assertEqual(self.migration("claude-md")["state"], "applied")
        snap = self.w.snapshot(skip=[".config/relay"])
        self.sync()                                                          # the marker: nothing more
        self.assertEqual(self.w.snapshot(skip=[".config/relay"]), snap)
        self.assertEqual(self.hub.titles().count(TITLE), 1)

    def test_remove_the_whole_section(self):
        post = self.propose()
        self.hub.answer(post["id"], "2", "Remove the whole section")
        self.sync()
        self.assertEqual(self.md().read_text(), BEFORE + AFTER)
        self.assertEqual(self.migration("claude-md")["state"], "removed")

    def test_an_edit_after_the_proposal_is_refused_and_proposed_again(self):
        post = self.propose()
        edited = BEFORE + SECTION.replace("**Why:**", "**Why (mine):**") + AFTER
        self.md().write_text(edited)
        self.hub.answer(post["id"], "2", "Apply")
        self.sync()
        self.assertEqual(self.md().read_text(), edited)
        self.assertEqual(self.hub.resolved[-1][0], post["id"])               # the old ask is closed
        again = self.hub.posts[-1]
        self.assertNotEqual(again["id"], post["id"])
        self.assertTrue(again["instructable"]["title"].startswith("Review the new proposal"))
        rec = self.migration("claude-md")
        self.assertEqual((rec["state"], rec["askId"]), ("proposed", again["id"]))
        self.hub.answer(again["id"], "2", "Apply")
        self.sync()
        self.assertIn("<!-- hook:migrated v=1 -->", self.md().read_text())

    def test_keep_is_never_asked_again(self):
        post = self.propose()
        self.hub.answer(post["id"], "2", "Keep CLAUDE.md as is")
        self.sync()
        self.assertEqual(self.md().read_text(), BEFORE + SECTION + AFTER)
        self.assertEqual(self.migration("claude-md")["state"], "declined")
        self.hub.close(post["id"])
        self.w.build("9.9.10")
        self.sync()
        self.assertEqual(self.hub.titles().count(TITLE), 1)
        self.assertEqual(self.md().read_text(), BEFORE + SECTION + AFTER)
        rc, out, err = self.w.run("migrate", "claude-md", "--again")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.hub.titles().count(TITLE), 2)

    def test_choose_from_the_command_line(self):
        self.propose()
        rc, out, err = self.w.run("migrate", "claude-md", "--choose", "Apply")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.md().read_text(), BEFORE + PROPOSED + AFTER)
        rc, out, err = self.w.run("migrate", "claude-md", "--choose", "Maybe")
        self.assertEqual(rc, 1)

    def test_an_unanswered_closed_ask_counts_as_keep(self):
        post = self.propose()
        self.hub.close(post["id"], "declined")
        self.sync()
        self.assertEqual(self.migration("claude-md")["state"], "declined")
        self.assertEqual(self.md().read_text(), BEFORE + SECTION + AFTER)

    def test_pending_without_hook_then_posted(self):
        self.hub.unreachable = True
        write(self.md(), BEFORE + SECTION + AFTER)
        self.sync()
        rec = self.migration("claude-md")
        self.assertEqual((rec["state"], rec.get("askId")), ("proposed", None))
        self.hub.unreachable = False
        self.sync()
        self.assertEqual(self.hub.titles().count(TITLE), 1)
        self.assertEqual(self.migration("claude-md")["askId"], self.hub.posts[-1]["id"])

    def test_dry_run_writes_nothing(self):
        self.sync()
        link = self.claude / "skills" / "instructables"
        link.parent.mkdir(parents=True)
        link.symlink_to(self.home / ".local" / "share" / "hook" / "0.12.0" / "skill" / "instructables")
        write(self.claude / "settings.json", SETTINGS)
        write(self.md(), "# Mine\n\n" + (LEGACY / "v0.8.0.md").read_text())
        manifest = self.w.manifest()
        snap = self.w.snapshot()
        rc, out, err = self.w.run("sync", "--dry-run")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.w.snapshot(), snap)
        self.assertEqual(self.w.manifest(), manifest)
        for word in ("CLAUDE.md", "settings.json", "skills/instructables"):
            self.assertIn(word, out)
        rc, out, err = self.w.run("sync", "--dry-run")
        self.assertEqual(self.w.snapshot(), snap)

    def test_uninstall_keeps_the_change_and_names_the_backup(self):
        write(self.md(), "# Mine\n\n" + (LEGACY / "v0.8.0.md").read_text())
        self.sync()
        rc, out, err = self.w.run("remove", "--harness", "claude-code")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.md().read_text(), "# Mine\n")
        self.assertIn("~/.claude/CLAUDE.md.bak", out)
        self.assertIn("~/.claude/settings.json.bak", out)


if __name__ == "__main__":
    unittest.main()
