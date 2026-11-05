"""relay_owner_steps: owner-only integration steps and the drift ask reach the owner as
instructables, through a fake Hook queue, a temp HOME and fake harness CLIs. Standard library only."""
from __future__ import annotations

import copy
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))

import relay_edits as ed  # noqa: E402
import relay_owner_steps as ros  # noqa: E402
from integration_kit import SECRET, World, real_table, synthetic_table  # noqa: E402

NOW = datetime(2026, 11, 3, 10, 0, 0, tzinfo=timezone.utc)
TRUST = "Trust Hook's prompt hook in Codex"
RELOAD = "Reload Cursor to load Hook's plugin"
WARP = "Add Hook's rule to Warp"


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, "utf-8")
    return path


def entries(*ids):
    table = real_table()
    return [copy.deepcopy(e) for e in table if e["id"] in ids]


class Base(unittest.TestCase):
    ids = ("codex", "cursor", "warp")

    def setUp(self):
        self.w = World(entries(*self.ids))
        self.w.rules_from_table()
        self.home = self.w.home
        self.w.add_cli("codex")
        (self.home / ".codex").mkdir()
        write(self.home / ".codex" / "config.toml", '[mcp_servers.other]\ncommand = "x"\nenv = { KEY = "%s" }\n' % SECRET)
        (self.home / ".cursor").mkdir()
        (self.home / ".warp").mkdir()
        self.hub = self.w.hub

    def tearDown(self):
        self.w.close()

    def sync(self, *extra, **kw):
        rc, out, err = self.w.run("sync", *extra, **kw)
        self.assertEqual(rc, 0, out + err)
        return out + err

    def asks(self):
        return self.w.manifest().get("asks") or {}


class TableStepsTest(unittest.TestCase):
    def test_every_table_step_renders_a_valid_instructable(self):
        w = World(real_table())
        try:
            values = w.values()
            n = 0
            for entry in real_table():
                for step in entry["owner_steps"]:
                    doc = ros.render_step(entry, step, values)      # raises InvalidAsk
                    self.assertEqual(doc["title"], step["title"])
                    self.assertNotIn("{{", json.dumps(doc))
                    n += 1
            self.assertGreaterEqual(n, 3)
        finally:
            w.close()

    def test_a_bad_step_raises(self):
        w = World(real_table())
        try:
            entry = copy.deepcopy(next(e for e in real_table() if e["id"] == "codex"))
            step = entry["owner_steps"][0]
            step["steps"][0]["do"] = "Run `codex --trust-all` in Terminal"
            with self.assertRaises(ros.InvalidAsk):
                ros.render_step(entry, step, w.values())
        finally:
            w.close()

    def test_warp_points_at_the_instructions_file(self):
        w = World(real_table())
        try:
            entry = next(e for e in real_table() if e["id"] == "warp")
            doc = ros.render_step(entry, entry["owner_steps"][0], w.values())
            files = [s["file"] for s in doc["steps"] if "file" in s]
            self.assertEqual(files, ["~/.local/share/hook/current/integration/instructions/hook.md"])
        finally:
            w.close()


class PostingTest(Base):
    def test_codex_trust_after_the_replies_hook_is_first_written(self):
        self.sync()
        self.assertEqual(self.hub.titles().count(TRUST), 1)
        self.assertEqual(self.hub.posts[0]["project"], "Hook")
        rec = self.asks()["codex-trust"]
        self.assertEqual((rec["state"], rec["askId"], rec["harness"]), ("open", "ask-1", "codex"))
        self.assertEqual(self.w.harness("codex")["state"], "needs-owner")
        steps = self.w.harness("codex")["ownerSteps"]
        self.assertEqual(steps, [{"id": "codex-trust", "title": TRUST, "askId": "ask-1", "state": "open"}])
        self.sync()                                    # unchanged: no new post
        self.assertEqual(self.hub.titles().count(TRUST), 1)

    def test_codex_trust_again_after_a_link_root_change_once_closed(self):
        self.sync()
        clone = self.w.root / "clone"
        write(clone / "mcp" / "relay_mcp.py", "")
        write(clone / "bin" / "relay", "")
        (clone / "integration").symlink_to(self.w.link_root / "integration")
        self.sync(link_root=clone)                      # fired, but the first ask is open
        self.assertEqual(self.hub.titles().count(TRUST), 1)
        self.hub.close("ask-1")
        self.sync()                                     # back to current: fires, first ask now closed
        self.assertEqual(self.hub.titles().count(TRUST), 2)
        self.assertEqual(self.asks()["codex-trust"]["state"], "open")

    def test_cursor_reload_only_when_the_plugin_tree_changed(self):
        self.sync()
        self.assertEqual(self.hub.titles().count(RELOAD), 1)
        ask = self.asks()["cursor-reload"]["askId"]
        self.hub.close(ask)
        self.sync()
        self.assertEqual(self.hub.titles().count(RELOAD), 1)
        self.assertEqual(self.asks()["cursor-reload"]["state"], "done")
        self.w.build("9.9.10")                           # the skill's version stamp changes the tree
        self.sync()
        self.assertEqual(self.hub.titles().count(RELOAD), 2)

    def test_warp_rule_posted_once_and_done_clears_needs_owner(self):
        self.sync()
        self.assertEqual(self.hub.titles().count(WARP), 1)
        self.assertEqual(self.w.piece("warp", "instructions")["state"], "needs-owner")
        self.assertEqual(self.w.harness("warp")["state"], "needs-owner")
        self.sync()
        self.assertEqual(self.hub.titles().count(WARP), 1)
        self.hub.close(self.asks()["warp-rule"]["askId"])
        self.sync()
        self.assertEqual(self.asks()["warp-rule"]["state"], "done")
        self.assertEqual(self.w.piece("warp", "instructions")["state"], "installed")
        self.assertEqual(self.w.harness("warp")["state"], "installed")
        self.w.build("9.9.10")
        self.sync()
        self.assertEqual(self.hub.titles().count(WARP), 1)

    def test_skipped_counts_as_finished(self):
        self.sync()
        self.hub.close(self.asks()["warp-rule"]["askId"], "declined")
        self.sync()
        self.assertEqual(self.asks()["warp-rule"]["state"], "skipped")
        piece = self.w.piece("warp", "instructions")
        self.assertEqual((piece["state"], piece["note"]), ("installed", "skipped by you"))

    def test_no_asks_records_pending_and_the_next_sync_posts(self):
        self.sync("--no-asks")
        self.assertEqual(self.hub.posts, [])
        self.assertEqual(self.hub.gets, [])
        for sid in ("codex-trust", "cursor-reload", "warp-rule"):
            self.assertEqual(self.asks()[sid]["state"], "pending", sid)
        self.assertEqual(self.w.harness("codex")["state"], "needs-owner")
        self.sync()
        self.assertEqual(sorted(self.hub.titles()), sorted([TRUST, RELOAD, WARP]))
        self.assertEqual({self.asks()[s]["state"] for s in ("codex-trust", "cursor-reload", "warp-rule")}, {"open"})
        self.sync()
        self.assertEqual(len(self.hub.posts), 3)

    def test_if_changed_still_reads_and_posts_asks(self):
        self.sync("--no-asks")
        self.sync("--if-changed")                       # a recent sync, but asks wait to be posted
        self.assertEqual(sorted(self.hub.titles()), sorted([TRUST, RELOAD, WARP]))
        self.hub.close(self.asks()["warp-rule"]["askId"])
        self.sync("--if-changed")                       # open asks: read them
        self.assertEqual(self.asks()["warp-rule"]["state"], "done")

    def test_unreachable_hook_records_pending_and_exits_0(self):
        self.hub.unreachable = True
        out = self.sync()
        self.assertIn("pending", out)
        self.assertEqual(self.asks()["codex-trust"]["state"], "pending")
        self.hub.unreachable = False
        self.hub.missing = True                         # no Hook config at all
        self.sync()
        self.assertEqual(self.asks()["codex-trust"]["state"], "pending")
        self.hub.missing = False
        self.sync()
        self.assertEqual(self.asks()["codex-trust"]["state"], "open")
        self.assertEqual(self.hub.titles().count(TRUST), 1)

    def test_remove_drops_the_harness_asks(self):
        self.sync()
        rc, out, err = self.w.run("remove", "--harness", "warp")
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn("warp-rule", self.asks())
        self.assertIn("codex-trust", self.asks())

    def test_dry_run_posts_nothing(self):
        rc, out, err = self.w.run("sync", "--dry-run")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.hub.posts, [])

    def test_the_refresh_budget_keeps_the_last_state(self):
        self.sync()
        calls = []

        class Slow:
            local = True
            timeout = 2.0

            def get(self, ask_id):
                calls.append(ask_id)
                return {"item": {"status": "resolved"}, "events": []}

        ticks = iter([0.0, 0.0, 5.0, 5.0, 5.0, 5.0])
        m = type("M", (), {"data": json.loads(json.dumps(self.w.manifest()))})()
        ros.refresh(m, lambda **kw: Slow(), budget_s=2.0, clock=lambda: next(ticks))
        self.assertEqual(len(calls), 1)                   # the budget ran out after one
        states = sorted(a["state"] for a in m.data["asks"].values())
        self.assertEqual(states, ["done", "open", "open"])

    def test_no_posted_text_holds_a_config_value(self):
        self.sync()
        cfg = self.home / ".codex" / "config.toml"
        cfg.write_text(cfg.read_text().replace("relay_mcp.py", "relay_mcp.py.mine"))
        self.sync()
        self.assertTrue(any(t.startswith("Choose what to keep") for t in self.hub.titles()))
        self.assertNotIn(SECRET, self.hub.text())
        self.assertNotIn("relay_mcp.py.mine", self.hub.text())


class DriftAskTest(unittest.TestCase):
    def make_table(self):
        return copy.deepcopy(synthetic_table())

    def setUp(self):
        self.w = World(self.make_table())
        self.w.rules_from_table()
        self.home = self.w.home
        self.w.add_cli("alpha")
        (self.home / ".beta").mkdir()
        write(self.home / ".beta" / "settings.json",
              '{\n  // Beta\n  "mcpServers": {\n    "other": {"command": "x", "env": {"KEY": "%s"}},\n  },\n}\n' % SECRET)
        write(self.home / ".alpha" / "AGENTS.md", "# My rules\n\nBe kind.\n")
        self.hub = self.w.hub
        self.sync()
        self.settings = self.home / ".beta" / "settings.json"
        self.agents = self.home / ".alpha" / "AGENTS.md"

    def tearDown(self):
        self.w.close()

    def sync(self, *extra):
        rc, out, err = self.w.run("sync", *extra)
        self.assertEqual(rc, 0, out + err)
        return out

    def edit_both(self):
        self.settings.write_text(ed.json_set(self.settings.read_text(), ["mcpServers", "relay", "args"], ["mine.py"]))
        self.agents.write_text(self.agents.read_text().replace("# Owner asks go to Hook", "# Owner asks go to my queue"))

    def drift(self):
        return self.hub.last("Choose what to keep")

    def test_one_bundled_ask_with_file_and_question_steps(self):
        self.edit_both()
        self.sync()
        post = self.drift()
        doc = post["instructable"]
        self.assertEqual(doc["title"], "Choose what to keep in files Hook manages (2)")
        ros.validate(doc)
        self.assertEqual(len(doc["steps"]), 2)
        by_file = {s["file"]: s for s in doc["steps"]}
        self.assertEqual(sorted(by_file), ["~/.alpha/AGENTS.md", "~/.beta/settings.json"])
        for path, step in by_file.items():
            self.assertEqual(step["question"], {"prompt": f"{path}: keep your edit or use Hook's?",
                                                "choices": ["Keep mine", "Use Hook's"]})
            self.assertLessEqual(len(step["do"]), 60)
            self.assertNotIn("~/", step["do"])
            self.assertTrue(step["code"].startswith("relay integrations diff --harness "))
        self.assertNotIn(SECRET, self.hub.text())
        self.assertNotIn("mine.py", self.hub.text())
        self.sync()                                     # the same edits: not asked again
        self.assertEqual(sum(t.startswith("Choose what") for t in self.hub.titles()), 1)

    def test_use_hooks_forces_a_rewrite_and_keep_mine_accepts(self):
        self.edit_both()
        self.sync()
        post = self.drift()
        steps = post["instructable"]["steps"]
        n_settings = str(1 + [s["file"] for s in steps].index("~/.beta/settings.json"))
        n_agents = str(1 + [s["file"] for s in steps].index("~/.alpha/AGENTS.md"))
        self.hub.answer(post["id"], n_settings, "Use Hook's")
        self.hub.answer(post["id"], n_agents, "Keep mine")
        baks = self.w.baks()
        kept = self.agents.read_text()
        self.sync()
        self.assertNotIn("mine.py", self.settings.read_text())
        self.assertEqual(self.w.piece("beta", "mcp")["state"], "installed")
        self.assertEqual(len(self.w.baks()), len(baks) + 1)
        self.assertEqual(self.agents.read_text(), kept)
        self.assertEqual(self.w.piece("alpha", "instructions")["state"], "accepted")
        self.assertEqual(self.w.manifest()["asks"]["drift"]["state"], "done")   # Hook closed it
        self.assertEqual(self.hub.resolved[-1][:2], (post["id"], "resolved"))
        self.sync()
        self.assertEqual(sum(t.startswith("Choose what") for t in self.hub.titles()), 1)

    def test_an_unverified_answer_on_a_pond_does_not_count(self):
        self.edit_both()
        self.sync()
        post = self.drift()
        self.hub.answer(post["id"], "1", "Use Hook's", auth="token")
        self.hub.answer(post["id"], "2", "Use Hook's", auth="token")
        self.sync()
        self.assertEqual(self.w.piece("beta", "mcp")["state"], "drifted")
        self.assertEqual(self.w.piece("alpha", "instructions")["state"], "drifted")

    def test_an_edit_after_the_ask_is_not_overwritten(self):
        self.settings.write_text(ed.json_set(self.settings.read_text(), ["mcpServers", "relay", "args"], ["mine.py"]))
        self.sync()
        post = self.drift()
        self.hub.answer(post["id"], "1", "Use Hook's")
        self.settings.write_text(ed.json_set(self.settings.read_text(), ["mcpServers", "relay", "args"], ["mine2.py"]))
        self.hub.close(post["id"])
        self.sync()
        self.assertIn("mine2.py", self.settings.read_text())
        self.assertEqual(self.w.piece("beta", "mcp")["state"], "drifted")
        self.assertEqual(sum(t.startswith("Choose what") for t in self.hub.titles()), 2)   # asked anew

    def test_no_asks_posts_no_drift_ask(self):
        self.edit_both()
        self.sync("--no-asks")
        self.assertFalse(any(t.startswith("Choose what") for t in self.hub.titles()))
        self.sync()
        self.assertTrue(any(t.startswith("Choose what") for t in self.hub.titles()))



class MovedDriftAskTest(DriftAskTest):
    """Keep mine on an edit left in a file the agent no longer reads (a `prefer` file filled up)
    keeps nothing: the edit stays where it is and the piece stays Edited by you."""

    def make_table(self):
        table = super().make_table()
        table[0]["pieces"]["instructions"][0]["prefer"] = ["{{harness_home}}/AGENTS.override.md"]
        return table

    def test_keep_mine_on_a_moved_edit_keeps_nothing(self):
        text = self.agents.read_text().replace("# Owner asks go to Hook", "# Owner asks go to my queue")
        self.agents.write_text(text)
        override = write(self.home / ".alpha" / "AGENTS.override.md", "# Override\n")
        self.sync()
        post = self.drift()
        self.assertEqual(len(post["instructable"]["steps"]), 1)
        self.hub.answer(post["id"], "1", "Keep mine")
        out = self.sync()
        self.assertIn("reinstall --force", out)
        self.assertEqual(self.agents.read_text(), text)
        self.assertEqual(override.read_text(), "# Override\n")
        self.assertEqual(self.w.piece("alpha", "instructions")["state"], "drifted")

if __name__ == "__main__":
    unittest.main()
