"""Every harness table entry, installed into a realistic fixture HOME and taken out again:
sync, the golden edited files, a second sync that changes nothing, an edit that shows as
drift, remove back to the original bytes, and a broken config that blocks. Each entry runs
with no harness CLI and, when it uses one, with fake CLIs on PATH.

Goldens live in fixtures/harness-homes/<id>/after*/ with the temp HOME written as /HOME. A
variant whose migration (the Claude Code one) changed files that uninstall never puts back has
removed*/ too: those files as they are after remove, and a .gone list of the ones that are
gone. Regenerate them with HOOK_UPDATE_GOLDEN=1 and read every diff. Standard library only."""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))

import relay_edits as ed  # noqa: E402
from integration_kit import SECRET, World, real_table  # noqa: E402

HOMES = Path(__file__).resolve().parent / "fixtures" / "harness-homes"
UPDATE = os.environ.get("HOOK_UPDATE_GOLDEN") == "1"
SKIP = (".config/relay", ".local/share/hook/current", ".local/share/hook/backups")
TABLE = real_table()
IDS = [e["id"] for e in TABLE]
HASH_SHA = re.compile(rb"(# hook:begin id=\S+ sha=)[0-9a-f]{16}")


def clis(entry: Dict[str, Any]) -> List[str]:
    """Every binary the entry's detection, alternatives and plugin can call."""
    names: Set[str] = set(entry["detect"]["bins"])
    probe = entry["detect"].get("probe")
    if probe:
        names.add(probe["argv"][0])
    for alts in entry["pieces"].values():
        for alt in alts:
            if alt["method"] == "cli":
                names.add(alt["requires"])
    plugin = entry.get("plugin") or {}
    for group in ("add", "update", "remove"):
        for argv in plugin.get(group) or []:
            names.add(argv[0])
    return sorted(names)


def files(root: Path, skip=()) -> Dict[str, bytes]:
    out: Dict[str, bytes] = {}
    for here, dirs, names in os.walk(root):
        for name in names + [d for d in dirs if (Path(here) / d).is_symlink()]:
            path = Path(here) / name
            rel = path.relative_to(root).as_posix()
            if any(rel == s or rel.startswith(s + "/") for s in skip):
                continue
            out[rel] = ("link:" + os.readlink(path)).encode() if path.is_symlink() else path.read_bytes()
    return out


class Cycle:
    """One entry, one fixture variant, with or without its CLIs."""

    def __init__(self, test: unittest.TestCase, hid: str, variant: str, with_cli: bool) -> None:
        self.t = test
        self.hid = hid
        self.entry = next(e for e in TABLE if e["id"] == hid)
        self.before = HOMES / hid / variant
        suffix = variant[len("before"):]
        self.golden = HOMES / hid / ("after" + suffix + ("-cli" if with_cli else ""))
        self.removed = HOMES / hid / ("removed" + suffix + ("-cli" if with_cli else ""))
        self.w = World(TABLE)
        self.w.rules_from_table()
        if with_cli:
            self.w.add_cli(*clis(self.entry))
        shutil.rmtree(self.w.home)
        shutil.copytree(self.before, self.w.home, symlinks=True)
        self.link_root_setup()
        self.out: List[str] = []

    def link_root_setup(self) -> None:
        # The fixture replaced HOME; put the link root (and its bundle) back.
        lr = self.w.link_root
        (lr / "mcp").mkdir(parents=True, exist_ok=True)
        (lr / "mcp" / "relay_mcp.py").write_text("# fake MCP server\n", "utf-8")
        (lr / "bin").mkdir(exist_ok=True)
        self.w.fake_relay()
        self.w.build()

    def run(self, *argv: str) -> Tuple[int, str, str]:
        rc, out, err = self.w.run(*argv)
        self.out.append(out + err)
        return rc, out, err

    def sync(self) -> None:
        rc, out, err = self.run("sync", "--include-new", "--harness", self.hid)
        self.t.assertEqual(rc, 0, out + err)

    def owned_trees(self) -> List[str]:
        m = self.w.manifest()
        trees = []
        for rec in m["targets"].values():
            if rec.get("kind") in ("copy", "plugin") and rec.get("path"):
                trees.append(Path(rec["path"]).relative_to(self.w.home).as_posix())
        return trees

    def changed(self) -> Dict[str, bytes]:
        before = files(self.before)
        skip = SKIP + tuple(self.owned_trees())
        now = files(self.w.home, skip)
        home = str(self.w.home).encode()
        # A TOML or YAML marker's sha covers values that name the temp HOME; it is checked
        # by the read-back in relay_edits, so the goldens leave it out.
        return {rel: HASH_SHA.sub(rb"\1<sha16>", data.replace(home, b"/HOME")) for rel, data in now.items()
                if ".bak" not in rel and before.get(rel) != data}

    # --- the steps ---

    def step_golden(self) -> None:
        got = self.changed()
        if UPDATE:
            if self.golden.exists():
                shutil.rmtree(self.golden)
            for rel, data in got.items():
                path = self.golden / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            if not got:
                self.golden.mkdir(parents=True)
                (self.golden / ".none").write_text("", "utf-8")
            return
        self.t.assertTrue(self.golden.is_dir(), f"no golden {self.golden}; run with HOOK_UPDATE_GOLDEN=1")
        want = {k: v for k, v in files(self.golden).items() if k != ".none"}
        self.t.assertEqual(sorted(got), sorted(want))
        for rel in want:
            self.t.assertEqual(got[rel].decode("utf-8", "replace"), want[rel].decode("utf-8", "replace"), rel)

    def step_idempotent(self) -> None:
        snap = files(self.w.home, (".config/relay",))
        self.w.clear_calls()
        self.sync()
        self.t.assertEqual(self.w.calls(), [], "a second sync called a harness CLI")
        self.t.assertEqual(files(self.w.home, (".config/relay",)), snap, "a second sync changed a file")

    def pieces_by_target(self) -> Dict[str, List[str]]:
        h = self.w.manifest()["harnesses"][self.hid]
        out: Dict[str, List[str]] = {}
        for piece, info in (h.get("pieces") or {}).items():
            out.setdefault(info["target"], []).append(piece)
        if h.get("plugin"):
            for piece, alts in self.entry["pieces"].items():
                if any(a["method"] == "plugin" for a in alts):
                    out.setdefault(h["plugin"], []).append(piece)
        return out

    def tamper_target(self) -> Optional[Tuple[str, Dict[str, Any], List[str]]]:
        m = self.w.manifest()
        order = {"key": 0, "cli": 1, "block": 2, "file": 3, "copy": 4, "plugin": 5}
        mine = [(k, m["targets"][k], pieces) for k, pieces in self.pieces_by_target().items()
                if k in m["targets"] and self.hid in m["targets"][k]["owners"]]
        mine = [t for t in mine if t[1]["kind"] != "cli" or t[1].get("writes")]
        mine.sort(key=lambda t: order.get(t[1]["kind"], 9))
        return mine[0] if mine else None

    def tamper(self, rec: Dict[str, Any]) -> Path:
        kind, path = rec["kind"], Path(rec["path"]) if rec.get("path") else None
        if kind == "cli":
            loc = rec["writes"]
            path = Path(loc.split("#", 1)[0])
            fmt, dotted = loc.split("#", 1)[1].split(":", 1) if ":" in loc.split("#", 1)[1] else ("exists", "")
            if fmt in ("json", "jsonc"):
                keypath = rec.get("keypath") or dotted.split(".")
                path.write_text(ed.json_set(path.read_text(), list(keypath) + ["x-mine"], True))
            elif fmt == "toml":
                path.write_text(path.read_text().replace('fake = "', 'fake = "mine-'))
            else:
                (path / "mine.txt").write_text("mine\n") if path.is_dir() else None
            return path
        if kind == "key":
            text = path.read_text()
            keypath = rec["keypath"]
            if rec.get("op") == "append":
                text = ed.json_remove_matching(text, keypath, lambda e: rec["match"] in json.dumps(e))
            elif rec["format"] in ("json", "jsonc"):
                text = ed.json_set(text, keypath + ["x-mine"], True)
            else:
                text = text.replace('"python3"', '"python3.12"')
            path.write_text(text)
        elif kind == "block":
            text = path.read_text()
            text = text.replace("send ONE instructable", "send one instructable")
            path.write_text(text)
        elif kind == "file":
            path.write_text(path.read_text() + "my line\n")
        else:
            (path / "mine.md").write_text("mine\n")
        return path

    def step_drift(self) -> None:
        found = self.tamper_target()
        self.t.assertIsNotNone(found, "Hook wrote nothing it could check")
        key, rec, pieces = found
        snap = files(self.w.home, (".config/relay",))
        path = self.tamper(rec)
        tampered = files(self.w.home, (".config/relay",))
        self.t.assertNotEqual(tampered, snap, f"the tamper changed nothing ({key})")
        for piece in pieces:
            self.t.assertEqual(self.w.piece(self.hid, piece)["state"], "drifted", (piece, key))
        self.sync()
        self.t.assertEqual(files(self.w.home, (".config/relay",)), tampered, "a sync touched a drifted target")
        for piece in pieces:
            self.t.assertEqual(self.w.piece(self.hid, piece)["state"], "drifted", (piece, key))
        # put the original back for the remove step
        for rel, data in tampered.items():
            if rel not in snap:
                (self.w.home / rel).unlink()
        for rel, data in snap.items():
            if tampered.get(rel) != data and not data.startswith(b"link:"):
                (self.w.home / rel).write_bytes(data)
        self.t.assertEqual(self.w.harness(self.hid)["state"] in ("installed", "needs-owner", "not-set-up"), True,
                           self.w.harness(self.hid))

    def after_remove(self) -> Dict[str, bytes]:
        """before/, with what a migration changed for good (removed*/) laid over it."""
        expected = files(self.before)
        if self.removed.is_dir():
            home = str(self.w.home).encode()
            for rel, data in files(self.removed).items():
                if rel != ".gone":
                    expected[rel] = data.replace(b"/HOME", home)
            gone = self.removed / ".gone"
            for rel in (gone.read_text("utf-8").split() if gone.is_file() else []):
                expected.pop(rel, None)
        return expected

    def capture_removed(self) -> None:
        """HOOK_UPDATE_GOLDEN: write removed*/ for a variant whose migration changed files."""
        if self.removed.exists():
            shutil.rmtree(self.removed)
        if not self.w.manifest().get("migrations"):
            return
        rc, out, err = self.run("remove", "--harness", self.hid)
        self.t.assertEqual(rc, 0, out + err)
        before, now = files(self.before), files(self.w.home, SKIP)
        home = str(self.w.home).encode()
        changed = {rel: data.replace(home, b"/HOME") for rel, data in now.items()
                   if rel in before and before[rel] != data}
        gone = sorted(rel for rel in before if rel not in now)
        if not changed and not gone:
            return
        for rel, data in changed.items():
            path = self.removed / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.removed.mkdir(parents=True, exist_ok=True)
        (self.removed / ".gone").write_text("".join(g + "\n" for g in gone), "utf-8")

    def step_remove(self) -> None:
        rc, out, err = self.run("remove", "--harness", self.hid)
        self.t.assertEqual(rc, 0, out + err)
        before = self.after_remove()
        now = files(self.w.home, SKIP)
        for rel, data in before.items():
            self.t.assertIn(rel, now, f"{rel} is gone after remove")
            self.t.assertEqual(now[rel], data, f"{rel} differs from before/ after remove")
        extra = sorted(rel for rel in now if rel not in before and ".bak" not in rel)
        self.t.assertEqual(extra, [], "files left after remove")
        dirs = {p.relative_to(self.w.home).as_posix() for p in self.w.home.rglob("*") if p.is_dir()}
        before_dirs = {p.relative_to(self.before).as_posix() for p in self.before.rglob("*") if p.is_dir()}
        left = sorted(d for d in dirs - before_dirs
                      if not any(d == s or d.startswith(s + "/") or s.startswith(d + "/") for s in SKIP))
        self.t.assertEqual(left, [], "folders left after remove")
        self.t.assertNotIn(self.hid, self.w.manifest()["harnesses"])

    def main_config(self, recs: List[Dict[str, Any]]) -> Optional[Tuple[Path, List[str]]]:
        for rec in recs:
            if rec["kind"] == "key" and rec.get("format") in ("json", "jsonc"):
                return Path(rec["path"]), [rec["piece"]]
            if rec["kind"] == "cli" and rec.get("writes", "").split("#")[-1].startswith(("json:", "jsonc:")):
                return Path(rec["writes"].split("#", 1)[0]), [rec["piece"]]
        return None

    def step_broken(self, recs: List[Dict[str, Any]]) -> None:
        found = self.main_config(recs)
        if found is None:
            return                              # nothing Hook parses (plugin or Markdown only)
        path, pieces = found
        original = path.read_text() if path.exists() else '{"a": 1}\n'
        broken = original.rstrip()[:-1] + ",\n  \"x\": \n"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(broken)
        os.utime(path, ns=(1_000_000_000, 1_000_000_000))
        self.sync()
        self.t.assertEqual(path.read_text(), broken)
        self.t.assertEqual(path.stat().st_mtime_ns, 1_000_000_000)
        for piece in pieces:
            self.t.assertEqual(self.w.piece(self.hid, piece)["state"], "blocked", piece)
        self.t.assertEqual(self.w.harness(self.hid)["state"], "blocked")

    def go(self) -> None:
        try:
            self.sync()
            self.step_golden()
            if UPDATE:
                self.capture_removed()
                return
            self.step_idempotent()
            if self.hid not in self.w.manifest()["harnesses"]:
                # Without its CLI nothing of this entry can be installed: every piece says why.
                for p in self.w.harness(self.hid)["pieces"]:
                    self.t.assertEqual(p["state"], "not-set-up", p)
                    self.t.assertTrue((p["note"] or "").startswith("needs `"), p)
                return
            recs = [r for r in self.w.manifest()["targets"].values() if self.hid in r["owners"]]
            self.step_drift()
            self.step_remove()
            self.step_broken(recs)
            for blob in self.out:
                self.t.assertNotIn(SECRET, blob)
        finally:
            self.w.close()


def variants(hid: str) -> List[str]:
    return sorted(p.name for p in (HOMES / hid).iterdir() if p.is_dir() and p.name.startswith("before"))


class FixtureHomes(unittest.TestCase):
    def test_every_entry_has_a_fixture(self):
        self.assertEqual(sorted(p.name for p in HOMES.iterdir() if p.is_dir()), sorted(IDS))
        for hid in IDS:
            self.assertIn("before", variants(hid), hid)

    def test_fixtures_hold_a_fake_secret_and_no_personal_paths(self):
        from test_relay_bundle import personal_hits
        for hid in IDS:
            if hid == "antigravity":
                continue                       # an empty antigravity-cli/ only
            text = "".join(d.decode("utf-8", "replace") for d in files(HOMES / hid / "before").values())
            self.assertIn(SECRET, text, hid)
        for path in HOMES.rglob("*"):
            if path.is_file():
                self.assertEqual(personal_hits(path.read_text("utf-8", "replace")), [], path)

    def test_codex_prefers_a_non_empty_override(self):
        w = World(TABLE)
        try:
            shutil.copytree(HOMES / "codex" / "before" / ".codex", w.home / ".codex")
            (w.home / ".codex" / "AGENTS.override.md").write_text("# Override\n")
            rc, out, err = w.run("sync", "--include-new", "--harness", "codex")
            self.assertEqual(rc, 0, out + err)
            self.assertIn("hook:begin id=instructions", (w.home / ".codex" / "AGENTS.override.md").read_text())
            self.assertNotIn("hook:begin", (w.home / ".codex" / "AGENTS.md").read_text())
        finally:
            w.close()


def _add(hid: str) -> None:
    entry = next(e for e in TABLE if e["id"] == hid)
    modes = [False] + ([True] if clis(entry) else [])

    def test(self, hid=hid, modes=modes):
        for variant in variants(hid):
            for with_cli in modes:
                with self.subTest(variant=variant, cli=with_cli):
                    Cycle(self, hid, variant, with_cli).go()
    test.__name__ = "test_" + hid.replace("-", "_")
    setattr(FixtureHomes, test.__name__, test)


for _hid in IDS:
    _add(_hid)


if __name__ == "__main__":
    unittest.main()
