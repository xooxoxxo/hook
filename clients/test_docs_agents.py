"""The agent docs say what the harness table and `relay integrations` do: one row per table entry
in docs/agents.md, with its replies support and whether it was tested on a Mac; every command and
exit code; the session-start rule in the skill and the instructions; the CHANGELOG's Unreleased
section. Standard library only."""
from __future__ import annotations

import io
import json
import re
import unittest
from pathlib import Path

import relay_integrations as ri

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "integration" / "src"
TABLE = json.loads((ROOT / "integration" / "harnesses.json").read_text("utf-8"))
DOCS = ROOT / "docs"
TESTED = {"machine": "yes", "pending": "not yet", "docs-only": "from docs"}
SESSION_START = ("{{replies:cursor}}", "{{replies:copilot}}", "{{replies:plain-session}}")


def read(path: Path) -> str:
    return path.read_text("utf-8")


def replies_kind(entry) -> str:
    """per prompt, session start or none, from what Hook writes for the replies piece."""
    alt = entry["pieces"]["replies"][0]
    method = alt["method"]
    if method == "none":
        return "none"
    if method == "plugin":
        text = "".join(read(p) for p in sorted((SRC / entry["plugin"]["render"]).rglob("*")) if p.is_file())
    elif method == "file":
        text = read(SRC / alt["source"])
    elif method == "key":
        text = json.dumps(alt["value"])
    else:
        raise AssertionError(f"{entry['id']}: replies method {method}")
    return "session start" if any(s in text for s in SESSION_START) else "per prompt"


def short_name(entry) -> str:
    """What the skill calls a harness: "Copilot" for both Copilot entries, "Antigravity"."""
    return entry["name"].replace("VS Code ", "").replace(" CLI", "")


def agents_rows():
    """{name: [cells]} for the rows of the table under "## The agents"."""
    text = read(DOCS / "agents.md")
    section = text.split("\n## The agents\n", 1)[1].split("\n## ", 1)[0]
    rows = {}
    for line in section.splitlines():
        if not line.startswith("| ") or line.startswith("| Agent ") or set(line) <= set("|- "):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows[cells[0]] = cells
    return rows


class AgentsDocTests(unittest.TestCase):
    def test_one_row_per_table_entry_in_table_order(self):
        self.assertEqual(list(agents_rows()), [e["name"] for e in TABLE])

    def test_replies_and_tested_columns_follow_the_table(self):
        rows = agents_rows()
        for entry in TABLE:
            cells = rows[entry["name"]]
            with self.subTest(entry["id"]):
                self.assertEqual(len(cells), 7, cells)
                self.assertTrue(cells[4].startswith(replies_kind(entry)), (cells[4], replies_kind(entry)))
                self.assertEqual(cells[6], TESTED[entry["verified"]])
                self.assertEqual(cells[5] == "none", not entry.get("owner_steps"), cells[5])

    def test_every_command_and_exit_code(self):
        text = read(DOCS / "agents.md")
        parser = ri._parser(io.StringIO())
        names = next(a for a in parser._actions if a.dest == "cmd").choices
        for name in names:
            self.assertIn(f"`relay integrations {name}", text)
        line = next(l for l in text.splitlines() if l.startswith("Exit codes"))
        for code in ("0", "1", "2", "4"):
            self.assertRegex(line, rf"\b{code}\b")
        for flag in ("--force", "--piece", "--harness", "--dry-run", "--json", "--smoke"):
            self.assertIn(flag, text)

    def test_a_removed_agent_stays_removed(self):
        text = read(DOCS / "agents.md")
        commands = text.split("\n## Commands\n", 1)[1].split("\n## ", 1)[0]
        removing = text.split("\n## Removing Hook\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn("--include-removed", commands)
        for section in (commands, removing):
            self.assertIn("stays removed", section)
            self.assertIn("--harness X", section)

    def test_keep_mine_is_off_for_an_edit_in_a_file_the_agent_no_longer_reads(self):
        edited = read(DOCS / "agents.md").split("\n## Edited files\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn("AGENTS.override.md", edited)
        self.assertIn("Keep Mine is off", edited)

    def test_the_fix_menu_maps_to_commands(self):
        text = read(DOCS / "agents.md")
        for words in ("Keep Mine", "Show Difference", "Use Hook's", "`relay integrations accept",
                      "`relay integrations diff", "reinstall --force --harness"):
            self.assertIn(words, text)


class SessionStartRuleTests(unittest.TestCase):
    """Agents without a per-prompt replies hook check their asks themselves."""

    def rule(self, text: str) -> str:
        return next(l for l in re.split(r"\n(?=- |\S)", text) if "relay_list" in l and "start of a session" in l)

    def test_the_skill_names_every_agent_without_a_per_prompt_hook(self):
        skill = read(ROOT / "skill" / "instructables" / "SKILL.md")
        answer = skill.split("\n## Reading the answer\n", 1)[1].split("\n## ", 1)[0]
        rule = self.rule(answer)
        self.assertIn("relay_status {id}", rule)
        for entry in TABLE:
            if replies_kind(entry) != "per prompt":
                self.assertIn(short_name(entry), rule)
        for entry in TABLE:
            if replies_kind(entry) == "per prompt":
                self.assertNotRegex(rule, rf"\b{re.escape(short_name(entry))}\b")

    def test_the_instructions_carry_the_same_rule(self):
        rule = self.rule(read(SRC / "instructions" / "hook.md"))
        self.assertIn("relay_status {id}", rule)
        self.assertIn("Hook:", rule)


class DocsSetTests(unittest.TestCase):
    def test_the_claude_md_section_is_gone(self):
        self.assertFalse((DOCS / "claude-md-section.md").exists())
        for path in [ROOT / "README.md"] + sorted(DOCS.glob("*.md")):
            self.assertNotIn("claude-md-section", read(path), path.name)

    def test_the_index_and_reference_pages(self):
        self.assertIn("(agents.md)", read(DOCS / "README.md"))
        self.assertIn("(docs/agents.md)", read(ROOT / "README.md"))
        config = read(DOCS / "configuration.md")
        for words in ("integrations.json", "~/.local/share/hook/plugins"):
            self.assertIn(words, config)
        trouble = read(DOCS / "troubleshooting.md")
        for words in ("relay integrations status", "Edited by you", "blocked", "/hooks", "Reload Window"):
            self.assertIn(words, trouble)
        install = read(DOCS / "install.md")
        self.assertIn("(agents.md)", install)
        self.assertNotIn("claude mcp add", install)

    def test_claude_code_is_the_plugin_rules_file_and_migration(self):
        text = read(DOCS / "claude-code.md")
        for words in ("hook@hook", "~/.claude/rules/hook.md", "relay integrations migrate claude-md",
                      "(agents.md)"):
            self.assertIn(words, text)
        self.assertNotIn("## MCP tools", text)


class ChangelogTests(unittest.TestCase):
    def test_the_integrations_release_names_them_and_every_docs_only_agent(self):
        text = read(ROOT / "CHANGELOG.md")
        sections = text.split("\n## [")[1:]
        newest = next(s for s in sections if s.startswith("Unreleased]") or s.startswith("0.13.0]"))
        for words in ("relay integrations", "relay hook replies", "Settings › Agents",
                      "docs/claude-md-section.md", "### Removed", "### Changed", "### Added"):
            self.assertIn(words, newest)
        for entry in TABLE:
            if entry["verified"] == "docs-only":
                self.assertIn(entry["name"], newest)


if __name__ == "__main__":
    unittest.main()
