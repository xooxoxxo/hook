"""relay_integrations: detect, plan, apply, manifest, drift, accept, diff, remove and status,
against a 3-entry synthetic table, a temp HOME and fake harness CLIs. Standard library only."""
from __future__ import annotations

import copy
import json
import os
import sys
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))

import relay_edits as ed  # noqa: E402
import relay_integrations as ri  # noqa: E402
from integration_kit import SECRET, World, real_table, synthetic_table  # noqa: E402

NOW = datetime(2026, 11, 3, 10, 0, 0, tzinfo=timezone.utc)


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, "utf-8")
    return path


class Base(unittest.TestCase):
    table = None

    def setUp(self):
        self.w = World(copy.deepcopy(self.table or synthetic_table()))
        self.w.rules_from_table()
        self.home = self.w.home
        # alpha (by bin), beta (by path), gamma (by app)
        self.w.add_cli("alpha")
        (self.home / ".beta").mkdir()
        self.w.add_app("Gamma.app")
        write(self.home / ".beta" / "settings.json",
              '{\n  // Beta settings\n  "mcpServers": {\n    "other": {"command": "x", "env": {"KEY": "%s"}},\n  },\n}\n'
              % SECRET)
        write(self.home / ".beta" / "hooks.json",
              '{\n  "hooks": {\n    "UserPromptSubmit": [\n      {"hooks": [{"type": "command", "command": "other"}]}\n    ]\n  }\n}\n')
        write(self.home / ".alpha" / "AGENTS.md", "# My rules\n\nBe kind.\n")

    def tearDown(self):
        self.w.close()

    def sync(self, *extra, **kw):
        rc, out, err = self.w.run("sync", *extra, **kw)
        self.assertEqual(rc, 0, out + err)
        return out

    def state(self, hid, piece):
        return self.w.piece(hid, piece)["state"]


class DetectTest(Base):
    def test_detect_by_bin_path_and_app(self):
        det = ri.detect(self.w.table, self.w.values(), ri.Runner(self.w.env(), self.home))
        self.assertTrue(det["alpha"].found)
        self.assertIn("bin alpha", det["alpha"].why)
        self.assertTrue(det["beta"].found)
        self.assertIn("path ~/.beta", det["beta"].why)
        self.assertTrue(det["gamma"].found)
        self.assertIn("app Gamma.app", det["gamma"].why)
        self.w.drop_cli("alpha")
        det = ri.detect(self.w.table, self.w.values(), ri.Runner(self.w.env(), self.home))
        self.assertFalse(det["alpha"].found)

    def test_probe(self):
        table = copy.deepcopy(self.w.table)
        table[2]["detect"] = {"bins": [], "paths": [], "apps": [],
                              "probe": {"argv": ["gam", "--help"], "expect": "coding agent", "timeout": 1}}
        runner = ri.Runner(self.w.env(), self.home)
        self.assertFalse(ri.detect(table, self.w.values(), runner)["gamma"].found)   # no binary
        self.w.add_cli("gam")
        self.assertFalse(ri.detect(table, self.w.values(), runner)["gamma"].found)   # prints nothing
        self.w.config["stdout"]["gam"] = "gam, a coding agent\n"
        self.w.save_config()
        self.assertTrue(ri.detect(table, self.w.values(), runner)["gamma"].found)
        self.w.config["sleep"]["gam"] = 3
        self.w.save_config()
        self.assertFalse(ri.detect(table, self.w.values(), runner)["gamma"].found)   # timed out


class SyncTest(Base):
    def test_first_sync_installs_everything_second_is_a_no_op(self):
        self.sync()
        for hid in ("alpha", "beta", "gamma"):
            h = self.w.harness(hid)
            self.assertEqual(h["state"], "installed", h)
            self.assertTrue(h["managed"])
        calls = self.w.calls()
        self.assertEqual([c["argv"][:2] for c in calls], [["mcp", "add"]])
        self.assertIn("relay", ed.loads_jsonc((self.home / ".alpha" / "config.json").read_text())["mcpServers"])
        skill = self.home / ".agents" / "skills" / "instructables" / "SKILL.md"
        self.assertTrue(skill.is_file() and not skill.parent.is_symlink())
        self.assertIn("hook:begin id=instructions", (self.home / ".alpha" / "AGENTS.md").read_text())
        self.assertTrue((self.home / ".beta" / "rules" / "hook.md").is_file())
        self.assertTrue((self.home / ".gamma" / "hooks" / "hook.json").is_file())
        before, baks = self.w.snapshot(), self.w.baks()
        self.w.clear_calls()
        self.sync()
        self.assertEqual(self.w.calls(), [])
        self.assertEqual(self.w.baks(), baks)
        after = self.w.snapshot(skip=[".config/relay"])
        self.assertEqual({k: v for k, v in before.items() if not k.startswith(".config/relay")}, after)

    def test_shared_files_get_one_backup_on_first_edit(self):
        self.sync()
        self.assertEqual(self.w.baks(), [".alpha/AGENTS.md.bak", ".beta/hooks.json.bak", ".beta/settings.json.bak"])
        self.assertEqual((self.home / ".beta/settings.json.bak").read_text().count(SECRET), 1)

    def test_drift_is_left_and_force_replaces_with_a_backup(self):
        self.sync()
        settings = self.home / ".beta" / "settings.json"
        text = ed.json_set(settings.read_text(), ["mcpServers", "relay", "args"], ["mine.py"])
        settings.write_text(text)
        agents = self.home / ".alpha" / "AGENTS.md"
        agents.write_text(agents.read_text().replace("Owner asks go to Hook", "Owner asks go to MY Hook"))
        self.assertEqual(self.state("beta", "mcp"), "drifted")
        self.assertEqual(self.state("alpha", "instructions"), "drifted")
        self.assertEqual(self.w.harness("beta")["state"], "drifted")
        self.sync()
        self.assertEqual(settings.read_text(), text)
        baks = self.w.baks()
        rc, out, err = self.w.run("reinstall", "--force", "--harness", "beta", "--piece", "mcp")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.state("beta", "mcp"), "installed")
        self.assertEqual(self.state("alpha", "instructions"), "drifted")      # only that piece
        self.assertEqual(len(self.w.baks()), len(baks) + 1)
        rc, out, err = self.w.run("reinstall", "--force", "--harness", "alpha")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.state("alpha", "instructions"), "installed")
        self.assertIn("Be kind.", agents.read_text())

    def test_removed_by_you_is_drift(self):
        self.sync()
        hooks = self.home / ".beta" / "hooks.json"
        hooks.write_text(ed.json_remove_matching(hooks.read_text(), ["hooks", "UserPromptSubmit"],
                                                 lambda e: "hook replies" in json.dumps(e)))
        p = self.w.piece("beta", "replies")
        self.assertEqual((p["state"], p["note"]), ("drifted", "removed by you"))

    def test_reinstall_rewrites_installed_items(self):
        self.sync()
        self.w.clear_calls()
        rc, out, err = self.w.run("reinstall", "--harness", "alpha")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual([c["argv"][:2] for c in self.w.calls()], [["mcp", "remove"], ["mcp", "add"]])

    def test_only_known_harnesses_without_auto_setup(self):
        rc, out, err = self.w.run("set", "auto-setup", "off")
        self.assertEqual(rc, 0, out + err)
        self.sync("--harness", "alpha")
        self.sync()
        st = self.w.status()
        self.assertEqual(st["autoSetup"], False)
        self.assertEqual(st["newlyDetected"], ["beta", "gamma"])
        self.assertEqual(self.w.harness("beta")["state"], "not-set-up")
        self.sync("--include-new")
        self.assertEqual(self.w.status()["newlyDetected"], [])


    def test_set_auto_setup_answers_in_json(self):
        rc, out, err = self.w.run("set", "auto-setup", "off", "--json")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(json.loads(out), {"autoSetup": False})
        self.assertEqual(self.w.status()["autoSetup"], False)
        rc, out, err = self.w.run("set", "auto-setup", "on", "--json")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(json.loads(out), {"autoSetup": True})


class AppFixtureTest(Base):
    """The app's sample status (Tests/RelayCoreTests/Fixtures/integrations-status.json) has
    the keys a real `status --json` prints, so the Swift model decodes what the CLI says."""

    FIXTURE = Path(__file__).resolve().parent.parent / "Tests" / "RelayCoreTests" / "Fixtures" / "integrations-status.json"

    def test_the_app_fixture_matches_the_status_shape(self):
        self.sync()
        real = self.w.status()
        sample = json.loads(self.FIXTURE.read_text("utf-8"))
        self.assertEqual(set(sample), set(real))
        real_h = real["harnesses"][0]
        for h in sample["harnesses"]:
            self.assertEqual(set(h) - {"smoke"}, set(real_h), h["id"])
            for p in h["pieces"]:
                self.assertEqual(set(p), set(real_h["pieces"][0]), (h["id"], p["piece"]))
        states = {p["state"] for h in sample["harnesses"] for p in h["pieces"]}
        self.assertLessEqual({p["state"] for h in real["harnesses"] for p in h["pieces"]}, states)
        self.assertLessEqual(set(ri.STATE_ORDER) | {"accepted", "none"}, states)


class AcceptDiffTest(Base):
    def drift_block(self):
        self.sync()
        agents = self.home / ".alpha" / "AGENTS.md"
        text = agents.read_text()
        self.assertIn("# Owner asks go to Hook", text)
        agents.write_text(text.replace("# Owner asks go to Hook", "# Owner asks go to my queue"))
        return agents

    def test_accept_keeps_the_edit_until_hook_or_the_file_changes(self):
        agents = self.drift_block()
        rc, out, err = self.w.run("accept", "--harness", "alpha", "--piece", "instructions")
        self.assertEqual(rc, 0, out + err)
        p = self.w.piece("alpha", "instructions")
        self.assertEqual((p["state"], p["note"]), ("accepted", "your edit is kept"))
        self.assertEqual(self.w.harness("alpha")["state"], "installed")
        text = agents.read_text()
        self.sync()
        self.assertEqual(agents.read_text(), text)
        # a further user edit
        agents.write_text(text.replace("Be kind.", "Be very kind."))
        self.assertEqual(self.state("alpha", "instructions"), "accepted")   # outside the block
        agents.write_text(text.replace("keep working", "keep on working"))
        self.assertEqual(self.state("alpha", "instructions"), "drifted")
        agents.write_text(text)
        self.assertEqual(self.state("alpha", "instructions"), "accepted")
        # a new bundle text
        self.w.build(instructions="# Owner asks go to Hook\n\nA new text.\n")
        self.assertEqual(self.state("alpha", "instructions"), "drifted")

    def test_accept_refuses_an_installed_piece(self):
        self.sync()
        rc, out, err = self.w.run("accept", "--harness", "beta", "--piece", "mcp")
        self.assertEqual(rc, 1)
        self.assertIn("not edited", err)

    def test_diff_for_block_key_file_and_copy(self):
        agents = self.drift_block()
        settings = self.home / ".beta" / "settings.json"
        settings.write_text(ed.json_set(settings.read_text(), ["mcpServers", "relay", "args"], ["mine.py"]))
        rules = self.home / ".beta" / "rules" / "hook.md"
        rules.write_text(rules.read_text() + "my line\n")
        skill = self.home / ".agents" / "skills" / "instructables" / "SKILL.md"
        skill.write_text(skill.read_text() + "my skill line\n")
        cases = [("alpha", "instructions", "# Owner asks go to my queue"), ("beta", "mcp", '"mine.py"'),
                 ("beta", "instructions", "my line"), ("gamma", "skill", "my skill line")]
        for hid, piece, frag in cases:
            with self.subTest(hid=hid, piece=piece):
                rc, out, err = self.w.run("diff", "--harness", hid, "--piece", piece)
                self.assertEqual(rc, 0, err)
                self.assertTrue(out.startswith("--- "), out)
                self.assertTrue(any(line.startswith("-") and frag in line for line in out.splitlines()), out)
                self.assertEqual(err, "")
        rc, out, err = self.w.run("diff", "--harness", "beta", "--piece", "mcp", "--json")
        data = json.loads(out)
        self.assertEqual(set(data), {"harness", "piece", "target", "diff"})
        self.assertEqual((data["harness"], data["piece"], data["target"]), ("beta", "mcp", "~/.beta/settings.json"))
        self.assertNotIn(SECRET, out)
        self.assertTrue(self.w.piece("beta", "mcp")["diffable"])
        self.assertFalse(self.w.piece("alpha", "mcp")["diffable"])

    def test_diff_refuses_an_undrifted_piece(self):
        self.sync()
        rc, out, err = self.w.run("diff", "--harness", "beta", "--piece", "mcp")
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")


class SharedAndLegacyTest(Base):
    def test_foreign_skill_folder_is_left_alone(self):
        mine = write(self.home / ".agents" / "skills" / "instructables" / "SKILL.md", "my own skill\n")
        self.sync()
        self.assertEqual(mine.read_text(), "my own skill\n")
        p = self.w.piece("beta", "skill")
        self.assertEqual(p["state"], "drifted")
        self.assertIn("not Hook's", p["note"])
        self.assertTrue(p["diffable"])

    def test_legacy_link_is_replaced_by_a_copy(self):
        clone = self.w.root / "clone"
        write(clone / "mcp" / "relay_mcp.py", "")
        write(clone / "skill" / "instructables" / "SKILL.md", "old\n")
        link = self.home / ".agents" / "skills" / "instructables"
        link.parent.mkdir(parents=True)
        link.symlink_to(clone / "skill" / "instructables")
        self.sync()
        self.assertFalse(link.is_symlink())
        self.assertTrue((link / "SKILL.md").is_file())
        self.assertEqual((clone / "skill" / "instructables" / "SKILL.md").read_text(), "old\n")

    def test_shared_copy_is_reference_counted(self):
        self.sync()
        skill = self.home / ".agents" / "skills" / "instructables"
        rec = self.w.manifest()["targets"][f"{skill}#tree"]
        self.assertEqual(sorted(rec["owners"]), ["alpha", "beta", "gamma"])
        for hid in ("alpha", "beta"):
            rc, out, err = self.w.run("remove", "--harness", hid)
            self.assertEqual(rc, 0, out + err)
            self.assertTrue(skill.is_dir())
        rc, out, err = self.w.run("remove", "--harness", "gamma")
        self.assertEqual(rc, 0, out + err)
        self.assertFalse(skill.exists())
        self.assertFalse((self.home / ".agents").exists())     # the folders Hook made

    def test_link_root_change_rewrites_everything_once(self):
        clone = self.w.root / "clone"
        write(clone / "mcp" / "relay_mcp.py", "")
        write(clone / "bin" / "relay", "")
        (clone / "integration").symlink_to(self.w.link_root / "integration")
        self.sync(link_root=clone)
        self.assertIn(str(clone), (self.home / ".beta" / "settings.json").read_text())
        st = self.w.status()
        self.assertEqual(st["linkRoot"], str(clone))
        rc, out, err = self.w.run("status", "--json")
        states = {(h["id"], p["piece"]): p["state"] for h in json.loads(out)["harnesses"] for p in h["pieces"]}
        for key in [("alpha", "mcp"), ("beta", "mcp"), ("beta", "replies")]:
            self.assertEqual(states[key], "outdated", key)
        self.assertEqual(states[("beta", "instructions")], "installed")   # names no path
        self.w.clear_calls()
        self.sync()
        self.assertEqual([c["argv"][:2] for c in self.w.calls()], [["mcp", "remove"], ["mcp", "add"]])
        self.assertNotIn(str(clone), (self.home / ".beta" / "settings.json").read_text())
        self.assertEqual(self.w.status()["linkRoot"], "~/.local/share/hook/current")
        for h in self.w.status()["harnesses"]:
            self.assertEqual(h["state"], "installed", h)
        self.w.clear_calls()
        snap = self.w.snapshot(skip=[".config/relay"])
        self.sync()
        self.assertEqual(self.w.calls(), [])
        self.assertEqual(self.w.snapshot(skip=[".config/relay"]), snap)


class FailureTest(Base):
    def test_unparseable_config_is_blocked_and_untouched(self):
        bad = write(self.home / ".beta" / "settings.json", '{"mcpServers": {"other": "%s",\n' % SECRET)
        os.utime(bad, ns=(1_000_000_000, 1_000_000_000))
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(bad.read_text(), '{"mcpServers": {"other": "%s",\n' % SECRET)
        self.assertEqual(bad.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(self.state("beta", "mcp"), "blocked")
        self.assertEqual(self.w.harness("beta")["state"], "blocked")
        self.assertEqual(self.state("beta", "instructions"), "installed")
        self.assertNotIn(SECRET, out + err)

    def test_failing_cli_is_blocked_with_exit_4_and_others_apply(self):
        self.w.config["fail"] = ["alpha"]
        self.w.save_config()
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 4, out + err)
        p = self.w.piece("alpha", "mcp")
        self.assertEqual(p["state"], "blocked")
        self.assertEqual(p["note"], "alpha: fake failure")
        self.assertEqual(self.w.harness("beta")["state"], "installed")
        self.assertEqual(self.state("alpha", "instructions"), "installed")
        self.w.config["fail"] = []
        self.w.save_config()
        self.sync()
        self.assertEqual(self.state("alpha", "mcp"), "installed")

    def test_dry_run_writes_nothing(self):
        before = self.w.snapshot()
        rc, out, err = self.w.run("sync", "--dry-run")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.w.snapshot(), before)
        self.assertEqual(self.w.calls(), [])
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 11)            # 4 pieces x 3, less alpha's none (beta and gamma join the skill)
        self.assertTrue(all(line.startswith("would ") for line in lines), lines)

    def test_empty_table_or_missing_bundle_exits_2(self):
        self.w.table = []
        tables = self.w.link_root / "integration" / "harnesses.json"
        tables.write_text("[]\n")
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 2)
        self.assertIn("harness table", err)
        rc, out, err = self.w.run("status", link_root=self.w.root / "nowhere")
        self.assertEqual(rc, 2)
        self.assertIn("bundle", err)

    def test_lock_serializes_and_times_out(self):
        values = self.w.values()
        with ri.lock(values, timeout=0.2):
            rc, out, err = self.w.run("sync", env=self.w.env(HOOK_LOCK_TIMEOUT="0.2"))
            self.assertEqual(rc, 2)
            self.assertIn("lock", err)
        self.w.config["sleep"]["alpha"] = 0.4
        self.w.save_config()
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.w.run("reinstall", "--harness", "alpha")))
                   for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual([r[0] for r in results], [0, 0])
        rows = [json.loads(line) for line in self.w.log.read_text().splitlines()]
        spans, open_at = [], None
        for row in rows:
            if "argv" in row:
                open_at = row["start"]
            else:
                spans.append((open_at, row["end"]))
        spans.sort()
        for (a0, a1), (b0, b1) in zip(spans, spans[1:]):
            self.assertLessEqual(a1, b0 + 0.05)

    def test_bad_arguments_exit_1(self):
        rc, out, err = self.w.run("accept")
        self.assertEqual(rc, 1)
        rc, out, err = self.w.run("sync", "--harness", "nope")
        self.assertEqual(rc, 1)


class RemoveTest(Base):
    def test_remove_all_restores_shared_files_byte_for_byte(self):
        shared = [".beta/settings.json", ".beta/hooks.json", ".alpha/AGENTS.md"]
        before = {rel: (self.home / rel).read_bytes() for rel in shared}
        snap = self.w.snapshot()
        self.sync()
        rc, out, err = self.w.run("set", "auto-setup", "off")
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        for rel in shared:
            self.assertEqual((self.home / rel).read_bytes(), before[rel], rel)
        self.assertFalse((self.home / ".alpha" / "config.json").exists())
        self.assertFalse((self.home / ".local" / "share" / "hook" / "plugins").exists())
        after = self.w.snapshot(skip=[".config"])
        extra = sorted(set(after) - set(snap))
        self.assertTrue(all(".bak" in rel for rel in extra), extra)
        m = self.w.manifest()
        self.assertEqual(m["harnesses"], {})
        self.assertEqual(m["autoSetup"], False)
        self.assertEqual(self.w.status()["harnesses"][0]["managed"], False)

    def test_drifted_target_is_left_on_remove_unless_forced(self):
        self.sync()
        rules = self.home / ".beta" / "rules" / "hook.md"
        rules.write_text("mine\n")
        rc, out, err = self.w.run("remove", "--harness", "beta")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(rules.read_text(), "mine\n")
        self.assertIn("left", out)
        rc, out, err = self.w.run("remove", "--harness", "beta", "--force")
        self.assertEqual(rc, 0, out + err)
        self.assertFalse(rules.exists())

    def test_an_unrecorded_hookish_file_gets_a_backup_and_comes_back_on_remove(self):
        mine = "# My notes\n\nRun `relay replies --new` after each answer.\n"
        rules = write(self.home / ".beta" / "rules" / "hook.md", mine)
        self.sync()
        self.assertNotEqual(rules.read_text(), mine)
        bak = rules.with_name("hook.md.bak")
        self.assertEqual(bak.read_text(), mine)
        rec = next(r for r in self.w.manifest()["targets"].values() if r.get("path") == str(rules))
        self.assertIs(rec["created"], False)
        rc, out, err = self.w.run("remove", "--harness", "beta")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(rules.read_text(), mine)
        self.assertFalse(bak.exists())
        self.assertIn("restored ~/.beta/rules/hook.md", out)

    def test_an_edited_unrecorded_file_keeps_both_copies_on_forced_remove(self):
        mine = "relay replies --new\n"
        rules = write(self.home / ".beta" / "rules" / "hook.md", mine)
        self.sync()
        rules.write_text("Hook's text, edited\n")
        rc, out, err = self.w.run("remove", "--harness", "beta", "--force")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(rules.read_text(), mine)
        edited = [p for p in rules.parent.iterdir() if p.name.startswith("hook.md.bak")]
        self.assertEqual([p.read_text() for p in edited], ["Hook's text, edited\n"])

    def test_remove_all_keeps_records_it_left_or_failed_to_remove(self):
        self.sync()
        rules = self.home / ".beta" / "rules" / "hook.md"
        rules.write_text("mine\n")
        self.w.config["fail"] = ["alpha"]
        self.w.save_config()
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 4, out + err)
        self.assertIn("left ~/.beta/rules/hook.md", out)
        self.assertEqual(rules.read_text(), "mine\n")
        m = self.w.manifest()
        self.assertEqual(sorted(m["harnesses"]), ["alpha", "beta"])
        self.assertEqual(sorted(r.get("piece") for r in m["targets"].values()), ["instructions", "mcp"])
        self.assertEqual(self.w.harness("beta")["managed"], True)
        self.assertEqual(self.state("beta", "instructions"), "drifted")
        self.assertEqual(self.state("alpha", "mcp"), "installed")
        self.assertEqual(self.w.harness("gamma")["managed"], False)
        self.w.config["fail"] = []
        self.w.save_config()
        baks = self.w.baks()
        self.sync()
        self.assertEqual(rules.read_text(), "mine\n")
        self.assertEqual(self.state("beta", "instructions"), "drifted")
        self.assertEqual([b for b in self.w.baks() if b not in baks and "rules" in b], [])
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(sorted(self.w.manifest()["harnesses"]), ["beta"])
        config = self.home / ".alpha" / "config.json"
        self.assertFalse(config.exists() and "relay" in config.read_text())


class RemovedHarnessTest(Base):
    """What the owner removed stays removed: a plain sync (the app's daily one), --include-new,
    --if-changed and Reinstall All leave it; Set Up (sync --harness X) brings it back."""

    def alpha_set_up(self):
        config = self.home / ".alpha" / "config.json"
        return config.exists() and "relay" in config.read_text()

    def test_a_removed_harness_is_not_set_up_again(self):
        self.sync()
        rc, out, err = self.w.run("remove", "--harness", "alpha")
        self.assertEqual(rc, 0, out + err)
        self.assertFalse(self.alpha_set_up())
        self.assertEqual(self.w.manifest()["removed"], ["alpha"])
        self.w.clear_calls()
        for argv in (("sync",), ("sync", "--include-new"), ("reinstall",), ("sync", "--if-changed")):
            rc, out, err = self.w.run(*argv)
            self.assertEqual(rc, 0, out + err)
            self.assertFalse(self.alpha_set_up(), argv)
            if "--if-changed" in argv:                                     # the status, as it is
                self.assertIn("Alpha: not-set-up (removed by you)", out)
            else:
                self.assertNotIn("alpha", out, argv)
        self.assertEqual(self.w.calls(), [])
        h = self.w.harness("alpha")
        self.assertEqual((h["detected"], h["managed"], h["removed"], h["state"]), (True, False, True, "not-set-up"))
        st = self.w.status()
        self.assertNotIn("alpha", st["newlyDetected"])
        self.assertEqual(self.w.harness("beta")["removed"], False)
        self.w.run("set", "auto-setup", "off")
        self.assertNotIn("alpha", self.w.status()["newlyDetected"])     # no Notice for it either
        rc, out, err = self.w.run("sync", "--harness", "alpha", "--dry-run")
        self.assertEqual(self.w.manifest()["removed"], ["alpha"])          # a dry run keeps it removed
        self.sync("--harness", "alpha")                                    # Set Up
        self.assertTrue(self.alpha_set_up())
        self.assertNotIn("removed", self.w.manifest())
        self.assertEqual(self.w.harness("alpha")["removed"], False)
        self.assertEqual(self.state("alpha", "mcp"), "installed")

    def test_remove_all_is_not_undone_by_the_apps_launch_sync(self):
        self.sync(now=NOW)
        rc, out, err = self.w.run("remove", "--all", now=NOW)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.w.manifest()["removed"], ["alpha", "beta", "gamma"])
        snap = self.w.snapshot(skip=[".config"])
        for argv in (("sync", "--if-changed", "--include-new"), ("sync",), ("sync", "--include-new")):
            rc, out, err = self.w.run(*argv, now=NOW + timedelta(minutes=1))
            self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.w.snapshot(skip=[".config"]), snap)
        self.assertEqual(self.w.manifest()["harnesses"], {})
        self.assertEqual(self.w.status()["newlyDetected"], [])
        rc, out, err = self.w.run("sync", "--include-removed")             # a first install
        self.assertEqual(rc, 0, out + err)
        self.assertTrue(self.alpha_set_up())
        self.assertEqual(sorted(self.w.manifest()["harnesses"]), ["alpha", "beta", "gamma"])
        self.assertNotIn("removed", self.w.manifest())

    def test_a_removed_harness_with_an_edit_left_is_not_topped_up(self):
        self.sync()
        rules = self.home / ".beta" / "rules" / "hook.md"
        rules.write_text("mine\n")
        rc, out, err = self.w.run("remove", "--harness", "beta")
        self.assertEqual(rc, 0, out + err)
        settings = (self.home / ".beta" / "settings.json").read_text()
        self.assertNotIn('"relay"', settings)
        self.sync()
        self.assertEqual((self.home / ".beta" / "settings.json").read_text(), settings)
        self.assertEqual(rules.read_text(), "mine\n")
        h = self.w.harness("beta")
        self.assertEqual((h["managed"], h["removed"]), (True, True))
        self.assertEqual(self.state("beta", "instructions"), "drifted")

    def test_a_dry_run_remove_records_nothing(self):
        self.sync()
        rc, out, err = self.w.run("remove", "--harness", "alpha", "--dry-run")
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn("removed", self.w.manifest())


class StatusTest(Base):
    def test_status_shape(self):
        self.sync(now=NOW)
        st = self.w.status()
        self.assertEqual(set(st), {"schema", "hookVersion", "tableChecked", "autoSetup", "lastSync", "linkRoot",
                                   "harnesses", "newlyDetected", "migrations", "errors"})
        self.assertEqual((st["schema"], st["hookVersion"], st["tableChecked"]), (1, "9.9.9", "2026-11-03"))
        self.assertEqual(st["lastSync"], "2026-11-03T10:00:00Z")
        self.assertEqual(st["linkRoot"], "~/.local/share/hook/current")
        self.assertEqual([h["id"] for h in st["harnesses"]], ["alpha", "beta", "gamma"])
        h = st["harnesses"][1]
        self.assertEqual(set(h), {"id", "name", "detected", "managed", "removed", "state", "verified", "pieces",
                                  "ownerSteps", "changes"})
        for p in h["pieces"]:
            self.assertEqual(set(p), {"piece", "method", "state", "target", "key", "note", "diffable", "keepable",
                                      "reveal"})
        mcp = h["pieces"][0]
        self.assertEqual((mcp["method"], mcp["target"], mcp["key"]), ("key", "~/.beta/settings.json", "mcpServers.relay"))
        self.assertIn({"path": "~/.beta/hooks.json", "what": "key hooks.UserPromptSubmit"}, h["changes"])
        self.assertIn({"path": "~/.beta/rules/hook.md", "what": "file"}, h["changes"])
        alpha = st["harnesses"][0]
        self.assertEqual(alpha["pieces"][3]["state"], "none")
        self.assertEqual(alpha["pieces"][0]["method"], "cli")
        self.assertEqual(alpha["pieces"][0]["target"], "~/.alpha/config.json")
        for blob in json.dumps(st), self.w.run("status")[1], self.w.run("sync", "--json")[1]:
            self.assertNotIn(SECRET, blob)
            self.assertNotIn(str(self.home), blob)

    def test_undetected_entries_are_listed(self):
        self.w.drop_cli("alpha")
        h = self.w.harness("alpha")
        self.assertEqual((h["detected"], h["managed"], h["state"]), (False, False, "not-set-up"))

    def test_if_changed_skips_a_recent_sync(self):
        self.sync(now=NOW)
        self.w.clear_calls()
        rc, out, err = self.w.run("reinstall", "--harness", "alpha", now=NOW)
        self.w.clear_calls()
        rc, out, err = self.w.run("sync", "--if-changed", "--json", now=NOW + timedelta(hours=1))
        self.assertEqual(rc, 0, out + err)
        self.assertIn("harnesses", json.loads(out))
        self.assertEqual(self.w.manifest()["lastSync"], "2026-11-03T10:00:00Z")
        rc, out, err = self.w.run("sync", "--if-changed", now=NOW + timedelta(hours=25))
        self.assertEqual(self.w.manifest()["lastSync"], "2026-11-04T11:00:00Z")

    def test_unparseable_manifest_is_moved_aside(self):
        write(self.home / ".config" / "relay" / "integrations.json", "{not json")
        st = self.w.status()
        self.assertTrue(st["errors"])
        self.sync()
        moved = list((self.home / ".config" / "relay").glob("integrations.json.bad-*"))
        self.assertEqual(len(moved), 1)
        self.assertEqual(oct(os.stat(self.home / ".config" / "relay" / "integrations.json").st_mode & 0o777), "0o600")

    def test_nothing_written_outside_home(self):
        outside = self.w.snapshot(self.w.root, skip=["home", "fakecli.log", "fakecli-state.json"])
        self.sync()
        self.w.run("remove", "--all")
        self.assertEqual(self.w.snapshot(self.w.root, skip=["home", "fakecli.log", "fakecli-state.json"]), outside)
        bundle = self.w.snapshot(self.w.link_root)
        self.sync()
        self.assertEqual(self.w.snapshot(self.w.link_root), bundle)


class PluginTest(unittest.TestCase):
    """The plugin path, with the real claude-code entry and a fake `claude`."""

    def setUp(self):
        self.w = World([e for e in real_table() if e["id"] == "claude-code"])
        self.w.rules_from_table()
        self.w.add_cli("claude")
        (self.w.home / ".claude").mkdir()

    def tearDown(self):
        self.w.close()

    def test_update_runs_when_the_version_changes(self):
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        plug = self.w.home / ".local" / "share" / "hook" / "plugins" / "claude"
        self.assertTrue((plug / ".claude-plugin" / "plugin.json").is_file())
        self.assertTrue((plug / "skills" / "instructables" / "SKILL.md").is_file())
        self.assertFalse((plug / ".mcp.json").exists())
        argvs = [c["argv"][:3] for c in self.w.calls()]
        self.assertEqual(argvs, [["mcp", "add-json", "--scope"], ["plugin", "marketplace", "add"],
                                 ["plugin", "install", "hook@hook"]])
        self.assertEqual(self.w.harness("claude-code")["state"], "installed")
        self.w.clear_calls()
        rc, out, err = self.w.run("sync")
        self.assertEqual(self.w.calls(), [])
        self.w.build("9.9.10")
        self.assertEqual(self.w.piece("claude-code", "skill")["state"], "outdated")
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual([c["argv"] for c in self.w.calls()], [["plugin", "marketplace", "update", "hook"],
                                                              ["plugin", "update", "hook@hook", "--scope", "user"]])
        self.assertIn('"9.9.10"', (plug / ".claude-plugin" / "plugin.json").read_text())
        (plug / "hooks" / "claude-hooks.json").write_text("{}\n")
        self.assertEqual(self.w.piece("claude-code", "replies")["state"], "drifted")
        rc, out, err = self.w.run("remove", "--harness", "claude-code", "--force")
        self.assertEqual(rc, 0, out + err)
        self.assertFalse(plug.exists())

    def test_a_failed_refresh_keeps_the_new_files_and_runs_again_next_sync(self):
        self.assertEqual(self.w.run("sync")[0], 0)
        self.w.build("9.9.10")
        self.w.config["fail"] = ["claude"]
        self.w.save_config()
        self.w.clear_calls()
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("files updated, but `claude plugin marketplace update` failed: claude: fake failure", out)
        self.assertEqual([c["argv"][:3] for c in self.w.calls()], [["plugin", "marketplace", "update"]])
        plug = self.w.home / ".local" / "share" / "hook" / "plugins" / "claude"
        self.assertIn('"9.9.10"', (plug / ".claude-plugin" / "plugin.json").read_text())
        skill = self.w.piece("claude-code", "skill")
        self.assertEqual(skill["state"], "outdated")
        self.assertIn("isn't refreshed yet", skill["note"])
        self.w.config["fail"] = []
        self.w.save_config()
        self.w.clear_calls()
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn("drifted", out + err)
        self.assertEqual([c["argv"][:3] for c in self.w.calls()], [["plugin", "marketplace", "update"],
                                                                   ["plugin", "update", "hook@hook"]])
        self.assertEqual(self.w.harness("claude-code")["state"], "installed")
        self.w.clear_calls()
        self.assertEqual(self.w.run("sync")[0], 0)
        self.assertEqual(self.w.calls(), [])

    def test_a_missing_claude_doesnt_fail_the_update(self):
        self.assertEqual(self.w.run("sync")[0], 0)
        self.w.build("9.9.10")
        self.w.drop_cli("claude")
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("`claude` isn't on PATH to refresh the installed plugin; the next sync tries again", out)
        plug = self.w.home / ".local" / "share" / "hook" / "plugins" / "claude"
        self.assertIn('"9.9.10"', (plug / ".claude-plugin" / "plugin.json").read_text())
        self.assertEqual(self.w.piece("claude-code", "skill")["state"], "outdated")

    def test_remove_all_keeps_the_plugin_folder_when_the_uninstall_fails(self):
        rc, out, err = self.w.run("sync")
        self.assertEqual(rc, 0, out + err)
        plugins = self.w.home / ".local" / "share" / "hook" / "plugins"
        self.w.config["fail"] = ["claude"]
        self.w.save_config()
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 4, out + err)
        self.assertTrue((plugins / "claude" / ".claude-plugin" / "plugin.json").is_file())
        self.assertIn("claude-code", self.w.manifest()["harnesses"])
        self.assertTrue(self.w.harness("claude-code")["managed"])
        self.w.config["fail"] = []
        self.w.save_config()
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        self.assertFalse(plugins.exists())
        self.assertEqual(self.w.manifest()["harnesses"], {})


def preferring_table():
    """The synthetic table, with alpha's block preferring AGENTS.override.md (as Codex's does)."""
    table = synthetic_table()
    table[0]["pieces"]["instructions"][0]["prefer"] = ["{{harness_home}}/AGENTS.override.md"]
    return table


class PreferredFileTest(Base):
    """A `prefer` file that fills up after Hook wrote into `path` takes Hook's block: Codex reads
    only the first non-empty one of AGENTS.override.md and AGENTS.md."""
    table = preferring_table()
    MINE = "# My rules\n\nBe kind.\n"
    OVERRIDE = "# Override\n\nUse staging.\n"

    def setUp(self):
        super().setUp()
        self.agents = self.home / ".alpha" / "AGENTS.md"
        self.override = self.home / ".alpha" / "AGENTS.override.md"

    def test_status_reports_the_move_and_sync_moves_the_block(self):
        self.sync()
        self.assertIn("hook:begin id=instructions", self.agents.read_text())
        self.assertEqual(self.state("alpha", "instructions"), "installed")
        write(self.override, self.OVERRIDE)
        piece = self.w.piece("alpha", "instructions")
        self.assertEqual(piece["state"], "outdated")
        self.assertEqual(piece["target"], "~/.alpha/AGENTS.override.md")
        self.assertIn("AGENTS.override.md", piece["note"])
        self.assertIn("~/.alpha/AGENTS.md", piece["note"])
        rc, out, err = self.w.run("sync", "--dry-run")
        self.assertIn("AGENTS.override.md", out)
        self.assertEqual(self.agents.read_text().count("hook:begin"), 1)       # a dry run moves nothing
        self.sync()
        self.assertEqual(self.agents.read_text(), self.MINE)
        self.assertTrue(self.override.read_text().startswith(self.OVERRIDE))
        self.assertIn("hook:begin id=instructions", self.override.read_text())
        self.assertEqual(self.state("alpha", "instructions"), "installed")
        keys = [k for k in self.w.manifest()["targets"] if "/.alpha/AGENTS" in k]
        self.assertEqual(len(keys), 1, keys)
        self.assertEqual(self.sync().count("instructions"), 0)              # settled
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.override.read_text(), self.OVERRIDE)
        self.assertEqual(self.agents.read_text(), self.MINE)

    def test_an_edited_block_is_not_moved_without_force(self):
        self.sync()
        text = self.agents.read_text().replace("<!-- hook:end -->", "My own line.\n<!-- hook:end -->")
        self.assertNotEqual(text, self.agents.read_text())
        self.agents.write_text(text)
        write(self.override, self.OVERRIDE)
        piece = self.w.piece("alpha", "instructions")
        self.assertEqual(piece["state"], "drifted")
        self.assertIn("AGENTS.override.md", piece["note"])
        self.sync()
        self.assertEqual(self.agents.read_text(), text)
        self.assertEqual(self.override.read_text(), self.OVERRIDE)
        rc, out, err = self.w.run("diff", "--harness", "alpha", "--piece", "instructions")
        self.assertEqual(rc, 0, err)
        self.assertIn("-My own line.", out)
        self.assertIn("~/.alpha/AGENTS.md (yours)", out)
        rc, out, err = self.w.run("reinstall", "--force", "--harness", "alpha", "--piece", "instructions")
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn("hook:begin", self.agents.read_text())
        self.assertIn("hook:begin id=instructions", self.override.read_text())
        self.assertTrue(any(p.name.startswith("AGENTS.md.bak") for p in self.agents.parent.iterdir()))
        self.assertEqual(self.state("alpha", "instructions"), "installed")

    def edit_then_override(self):
        self.sync()
        text = self.agents.read_text().replace("<!-- hook:end -->", "My own line.\n<!-- hook:end -->")
        self.agents.write_text(text)
        write(self.override, self.OVERRIDE)
        return text

    def test_keep_mine_is_refused_for_an_edit_left_in_the_file_the_agent_no_longer_reads(self):
        text = self.edit_then_override()
        piece = self.w.piece("alpha", "instructions")
        self.assertEqual((piece["state"], piece["diffable"], piece["keepable"]), ("drifted", True, False))
        before = self.w.manifest()
        for argv in (("--piece", "instructions"), ()):
            rc, out, err = self.w.run("accept", "--harness", "alpha", *argv)
            self.assertEqual(rc, 1, out + err)
            self.assertIn("~/.alpha/AGENTS.override.md", err)
            self.assertIn("~/.alpha/AGENTS.md", err)
            self.assertIn("reinstall --force --harness alpha --piece instructions", err)
            self.assertEqual(self.w.manifest(), before)
        self.assertEqual(self.state("alpha", "instructions"), "drifted")
        self.assertNotEqual(self.w.harness("alpha")["state"], "installed")
        self.sync()
        self.assertEqual(self.agents.read_text(), text)
        self.assertEqual(self.override.read_text(), self.OVERRIDE)
        self.assertEqual(self.state("alpha", "instructions"), "drifted")
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("alpha instructions: left ~/.alpha/AGENTS.md", out)
        self.assertEqual(self.agents.read_text(), text)
        self.assertEqual(self.override.read_text(), self.OVERRIDE)
        self.assertTrue(any("/.alpha/AGENTS.md#" in k for k in self.w.manifest()["targets"]))

    def test_an_edit_in_the_file_the_agent_reads_can_be_kept(self):
        self.sync()
        text = self.agents.read_text().replace("<!-- hook:end -->", "My own line.\n<!-- hook:end -->")
        self.agents.write_text(text)
        piece = self.w.piece("alpha", "instructions")
        self.assertEqual((piece["state"], piece["keepable"]), ("drifted", True))
        rc, out, err = self.w.run("accept", "--harness", "alpha", "--piece", "instructions")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.state("alpha", "instructions"), "accepted")
        self.assertEqual(self.w.piece("alpha", "instructions")["keepable"], False)

    def test_an_empty_override_changes_nothing(self):
        self.sync()
        write(self.override, "")
        self.assertEqual(self.state("alpha", "instructions"), "installed")
        self.assertEqual(self.w.piece("alpha", "instructions")["target"], "~/.alpha/AGENTS.md")


class EmptyShapeTest(Base):
    def test_whitespace_only_json_files_come_back_byte_for_byte(self):
        shapes = {".beta/settings.json": "{ }", ".beta/hooks.json": "\n", ".gamma/mcp.json": "{\n}\n"}
        for rel, text in shapes.items():
            write(self.home / rel, text)
        self.sync("--include-new")
        for rel in shapes:
            self.assertIn("hook replies" if "hooks" in rel else "relay",
                          (self.home / rel).read_text(), rel)
        rc, out, err = self.w.run("remove", "--all")
        self.assertEqual(rc, 0, out + err)
        for rel, text in shapes.items():
            self.assertEqual((self.home / rel).read_text(), text, rel)


class HumanReportTest(unittest.TestCase):
    def test_a_dry_run_item_prints_its_diff_under_its_would_line(self):
        import io
        report = ri.Report(dry_run=True)
        report.results.append({"harness": "claude-code", "piece": "claude-md", "action": "migrate",
                               "target": "~/.claude/CLAUDE.md", "outcome": "would", "note": "apply",
                               "diff": ["--- a", "+++ b", "@@ -1 +1 @@", "-old", "+new"]})
        report.results.append({"harness": "claude-code", "piece": "claude-skill", "action": "migrate",
                               "target": "~/.claude/skills/instructables", "outcome": "would", "note": None})
        out = io.StringIO()
        ri._human_report(report, out)
        self.assertEqual(out.getvalue().splitlines(), [
            "would migrate claude-code claude-md: ~/.claude/CLAUDE.md (apply)",
            "  --- a", "  +++ b", "  @@ -1 +1 @@", "  -old", "  +new",
            "would migrate claude-code claude-skill: ~/.claude/skills/instructables",
        ])


if __name__ == "__main__":
    unittest.main()
