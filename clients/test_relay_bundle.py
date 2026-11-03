"""The integration bundle: one build from integration/src and the skill, stamped, reproducible.
Standard library only."""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import tempfile
import unittest
from pathlib import Path

import relay_bundle as rb

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "integration" / "src"
SKILL = ROOT / "skill" / "instructables"
VERSION = "0.13.0"
STAMP = f"<!-- hook:instructions v={rb.BUNDLE_SCHEMA} app={VERSION} -->"

LAYOUT = [
    "bundle.json",
    "harnesses.json",
    "instructions/hook.md",
    "instructions/hook.mdc",
    "instructions/hook.instructions.md",
    "instructions/hook.steering.md",
    "skills/instructables/SKILL.md",
    "plugins/claude/.claude-plugin/plugin.json",
    "plugins/claude/.claude-plugin/marketplace.json",
    "plugins/claude/hooks/claude-hooks.json",
    "plugins/claude/render.json",
    "plugins/gemini/gemini-extension.json",
    "plugins/gemini/hooks/hooks.json",
    "plugins/gemini/render.json",
    "plugins/cursor/.cursor-plugin/plugin.json",
    "plugins/cursor/mcp.json",
    "plugins/cursor/hooks/hooks.json",
    "plugins/cursor/render.json",
    "plugins/antigravity/.antigravity-plugin/plugin.json",
    "plugins/antigravity/hooks/hooks.json",
    "plugins/antigravity/render.json",
    "files/copilot-hooks.json",
    "files/opencode-hook.ts",
    "files/amp-hook.ts",
    "files/pi-hook.ts",
]

VALUES = {
    "home": "/Users/me", "harness_home": "/Users/me/.codex", "python": "python3",
    "mcp_server": "/Users/me/.local/share/hook/current/mcp/relay_mcp.py",
    "relay": "/Users/me/.local/share/hook/current/bin/relay",
    "bundle": "/Users/me/.local/share/hook/current/integration",
    "instructions": "/Users/me/.local/share/hook/current/integration/instructions/hook.md",
    "instructions_home_ref": "~/.local/share/hook/current/integration/instructions/hook.md",
    "plugins": "/Users/me/.local/share/hook/plugins", "version": VERSION, "schema": "1",
}


# Words that must never ship (a personal name and personal tool names), kept as sha256 so the
# public repo doesn't carry them either: (length, sha256 of the lowercased word).
PERSONAL = {
    (5, "44bde2d04ce3e32ffd0f306f186521d25e2c3db08071c5be3b38dc646ac03eb8"),
    (5, "bccd59099ea0c5954b98efc6977dd73b18517d639fc9b86a8d41d1f9cab72a8b"),
    (9, "454fb67ac222cfc4aea5b62f201f94c1207196e1fa9922093f154c70a4e06d73"),
}
PLAIN_BANNED = re.compile(r"/Users/(?!me/)|\bXO-[0-9]+")


def personal_hits(text):
    """Words in text that start with a PERSONAL word, plus /Users/<someone> paths and XO ids."""
    hits = PLAIN_BANNED.findall(text)
    for token in set(re.findall(r"[a-z0-9-]+", text.lower())):
        for length, sha in PERSONAL:
            if len(token) >= length and hashlib.sha256(token[:length].encode()).hexdigest() == sha:
                hits.append(token)
    return hits


def frontmatter(text):
    """(frontmatter lines, body) of a Markdown file that starts with ---."""
    assert text.startswith("---\n"), text[:40]
    end = text.index("\n---\n", 4)
    return text[4:end].split("\n"), text[end + 5:]


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.table = self.tmp / "harnesses.json"
        self.table.write_text("[]\n", "utf-8")
        self.out = self.tmp / "integration"
        self.manifest = rb.build(SRC, SKILL, self.table, self.out, VERSION)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read(self, rel):
        return (self.out / rel).read_text("utf-8")

    def test_build_layout(self):
        for rel in LAYOUT:
            self.assertTrue((self.out / rel).is_file(), rel)
        on_disk = json.loads(self.read("bundle.json"))
        self.assertEqual(on_disk, self.manifest)
        self.assertEqual((on_disk["schema"], on_disk["version"]), (rb.BUNDLE_SCHEMA, VERSION))
        files = sorted(p.relative_to(self.out).as_posix() for p in self.out.rglob("*") if p.is_file())
        self.assertEqual(sorted(on_disk["files"]), [f for f in files if f != "bundle.json"])
        for rel, sha in on_disk["files"].items():
            self.assertEqual(hashlib.sha256((self.out / rel).read_bytes()).hexdigest(), sha, rel)
        for rel in LAYOUT[1:]:
            self.assertIn(rel, on_disk["files"])

    def test_stamp_first_line(self):
        self.assertTrue(self.read("instructions/hook.md").startswith(STAMP + "\n"))
        source = (SRC / "instructions" / "hook.md").read_text("utf-8")
        self.assertEqual(self.read("instructions/hook.md"), STAMP + "\n" + source)
        expected = {
            "instructions/hook.mdc": ["description: Hook owner asks", "alwaysApply: true"],
            "instructions/hook.instructions.md": ['applyTo: "**"'],
            "instructions/hook.steering.md": ["inclusion: always"],
        }
        for rel, lines in expected.items():
            with self.subTest(rel):
                head, body = frontmatter(self.read(rel))
                self.assertEqual(head, lines)
                self.assertEqual(body, STAMP + "\n" + source)

    def test_skill_version_metadata(self):
        source = (SKILL / "SKILL.md").read_text("utf-8")
        built = self.read("skills/instructables/SKILL.md")
        src_head, src_body = frontmatter(source)
        head, body = frontmatter(built)
        self.assertEqual(body, src_body)
        self.assertEqual(head[:len(src_head)], src_head)       # name and description unchanged
        self.assertEqual(head[len(src_head):], ["metadata:", f'  version: "{VERSION}"'])
        keys = [line.split(":", 1)[0] for line in head if not line.startswith(" ")]
        self.assertEqual(keys, ["name", "description", "metadata"])

    def test_skill_metadata_merges_into_an_existing_block(self):
        skill = self.tmp / "skill"
        skill.mkdir()
        (skill / "SKILL.md").write_text("---\nname: x\ndescription: y\nmetadata:\n  owner: z\n---\nbody\n", "utf-8")
        out = self.tmp / "other"
        rb.build(SRC, skill, self.table, out, VERSION)
        head, body = frontmatter((out / "skills" / "instructables" / "SKILL.md").read_text("utf-8"))
        self.assertEqual(head, ["name: x", "description: y", "metadata:", f'  version: "{VERSION}"', "  owner: z"])
        self.assertEqual(body, "body\n")

    def test_no_mcp_json_in_claude_plugin(self):
        names = [p.name for p in (self.out / "plugins" / "claude").rglob("*")]
        self.assertNotIn(".mcp.json", names)
        self.assertNotIn("mcp.json", names)
        self.assertNotIn("mcpServers", json.dumps([self.read(f"plugins/claude/{p}") for p in
                                                  (".claude-plugin/plugin.json", "hooks/claude-hooks.json")]))

    def test_build_is_reproducible(self):
        again = self.tmp / "again"
        second = rb.build(SRC, SKILL, self.table, again, VERSION)
        self.assertEqual(second, self.manifest)
        self.assertEqual((again / "bundle.json").read_bytes(), (self.out / "bundle.json").read_bytes())
        self.assertEqual(rb.tree_sha(again), rb.tree_sha(self.out))

    def test_no_symlinks_in_bundle(self):
        self.assertFalse([p for p in self.out.rglob("*") if p.is_symlink()])
        link = self.tmp / "linked"
        link.mkdir()
        (link / "a").write_text("a", "utf-8")
        os.symlink(link / "a", link / "b")
        with self.assertRaises(rb.BundleError):
            rb.tree_sha(link)

    def test_no_personal_strings(self):
        for path in self.out.rglob("*"):
            if path.is_file():
                with self.subTest(path.relative_to(self.out).as_posix()):
                    text = path.read_text("utf-8")
                    self.assertNotIn("/Users/", text)
                    self.assertEqual(personal_hits(text), [])

    def test_the_personal_check_catches_what_it_should(self):
        self.assertEqual(personal_hits("/Users/me/x and XO-12"), ["XO-12"])
        self.assertEqual(personal_hits("/Users/someone/x"), ["/Users/"])
        self.assertEqual(personal_hits("no names here, just Hook"), [])

    def test_harness_table_is_copied(self):
        self.assertEqual(self.read("harnesses.json"), "[]\n")
        out = self.tmp / "no-table"
        manifest = rb.build(SRC, SKILL, self.tmp / "missing.json", out, VERSION)
        self.assertNotIn("harnesses.json", manifest["files"])
        self.assertFalse((out / "harnesses.json").exists())

    def test_rebuild_replaces_a_bundle_and_refuses_anything_else(self):
        (self.out / "stale.txt").write_text("old", "utf-8")
        rb.build(SRC, SKILL, self.table, self.out, "0.13.1")
        self.assertFalse((self.out / "stale.txt").exists())
        self.assertEqual(json.loads(self.read("bundle.json"))["version"], "0.13.1")
        other = self.tmp / "not-ours"
        other.mkdir()
        (other / "keep.txt").write_text("mine", "utf-8")
        with self.assertRaisesRegex(rb.BundleError, "not a Hook bundle"):
            rb.build(SRC, SKILL, self.table, other, VERSION)
        self.assertEqual((other / "keep.txt").read_text("utf-8"), "mine")
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir() if ".tmp-" in p.name), [])

    def test_caches_are_stripped(self):
        skill = self.tmp / "skill-cache"
        shutil.copytree(SKILL, skill)
        (skill / ".DS_Store").write_bytes(b"x")
        (skill / "__pycache__").mkdir()
        (skill / "__pycache__" / "a.pyc").write_bytes(b"x")
        (skill / "b.pyc").write_bytes(b"x")
        out = self.tmp / "stripped"
        manifest = rb.build(SRC, skill, self.table, out, VERSION)
        self.assertEqual([f for f in manifest["files"] if f.startswith("skills/")], ["skills/instructables/SKILL.md"])

    def test_templates_use_only_known_placeholders(self):
        for path in (self.out / "plugins").rglob("*"):
            if path.is_file():
                for name in re.findall(r"\{\{([^}]*)\}\}", path.read_text("utf-8")):
                    self.assertTrue(rb.known_placeholder(name), f"{path}: {name}")

    def test_ts_files_import_only_child_process(self):
        for name in ("opencode-hook.ts", "amp-hook.ts", "pi-hook.ts"):
            with self.subTest(name):
                text = self.read(f"files/{name}")
                imports = re.findall(r"""(?:import\b[^'"]*|require\()\s*['"]([^'"]+)['"]""", text)
                self.assertEqual(imports, ["node:child_process"])
                self.assertIn('"{{relay}}"', text)
                self.assertIn('["hook", "replies", "--format", "plain"]', text)
                self.assertIn("timeout: 3000", text)

    def test_rendered_templates_are_valid_json(self):
        for rel in [r for r in self.manifest["files"] if r.endswith(".json") and r.startswith(("plugins/", "files/"))]:
            with self.subTest(rel):
                json.loads(rb.render_text(self.read(rel), VALUES, json_escape=True))


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_render_escapes_json(self):
        odd = 'C:\\odd "dir"\\relay_mcp.py'
        text = rb.render_text('{"args": ["{{mcp_server}}"]}', {"mcp_server": odd}, json_escape=True)
        self.assertEqual(json.loads(text)["args"], [odd])
        self.assertEqual(rb.render_text("run {{mcp_server}}", {"mcp_server": odd}, json_escape=False), "run " + odd)

    def test_render_unknown_placeholder_raises(self):
        with self.assertRaisesRegex(rb.RenderError, "nope"):
            rb.render_text("{{nope}}", VALUES, json_escape=False)
        with self.assertRaisesRegex(rb.RenderError, "version"):
            rb.render_text("{{version}}", {}, json_escape=False)
        with self.assertRaises(rb.RenderError):
            rb.render_text("{{replies:fancy}}", VALUES, json_escape=False)

    def test_replies_placeholder_quotes_the_relay_path(self):
        values = dict(VALUES, relay="/Users/me/it's/bin/relay")
        self.assertEqual(rb.render_text("{{replies:claude}}", values, json_escape=False),
                         "'/Users/me/it'\\''s/bin/relay' hook replies --format claude")
        self.assertEqual(rb.render_text("{{replies:plain-session}}", VALUES, json_escape=False),
                         f"'{VALUES['relay']}' hook replies --format plain --when session-start")
        text = rb.render_text('{"c": "{{replies:cursor}}"}', values, json_escape=True)
        self.assertEqual(json.loads(text)["c"], "'/Users/me/it'\\''s/bin/relay' hook replies --format cursor")

    def test_render_tree_fills_templates_and_copies_extras(self):
        table = self.tmp / "t.json"
        table.write_text("[]", "utf-8")
        bundle = self.tmp / "bundle"
        rb.build(SRC, SKILL, table, bundle, VERSION)
        dest = self.tmp / "plugins" / "claude"
        extra = rb.plugin_extras(bundle, "claude")
        self.assertEqual(extra, {"skills/instructables": bundle / "skills" / "instructables"})
        sha = rb.render_tree(bundle / "plugins" / "claude", dest, VALUES, extra)
        self.assertEqual(sha, rb.tree_sha(dest))
        self.assertFalse((dest / "render.json").exists())
        plugin = json.loads((dest / ".claude-plugin" / "plugin.json").read_text("utf-8"))
        self.assertEqual(plugin["version"], VERSION)
        hooks = json.loads((dest / "hooks" / "claude-hooks.json").read_text("utf-8"))
        hook = hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]
        self.assertEqual(hook, {"type": "command", "command": f"'{VALUES['relay']}' hook replies --format claude",
                                "timeout": 5})
        self.assertEqual((dest / "skills" / "instructables" / "SKILL.md").read_bytes(),
                         (bundle / "skills" / "instructables" / "SKILL.md").read_bytes())
        self.assertNotIn("{{", "".join(p.read_text("utf-8") for p in dest.rglob("*") if p.is_file()))
        # Rendering again over the old tree gives the same tree.
        self.assertEqual(rb.render_tree(bundle / "plugins" / "claude", dest, VALUES, extra), sha)

    def test_render_tree_missing_source_raises(self):
        src = self.tmp / "src"
        src.mkdir()
        (src / "a.json").write_text("{}", "utf-8")
        with self.assertRaises(rb.RenderError):
            rb.render_tree(src, self.tmp / "dest", VALUES, {"b.md": self.tmp / "missing.md"})
        with self.assertRaises(rb.RenderError):
            rb.render_tree(self.tmp / "nothing", self.tmp / "dest2", VALUES, {})

    def test_tree_sha_is_order_and_content_sensitive(self):
        a = self.tmp / "a"
        (a / "d").mkdir(parents=True)
        (a / "x").write_text("1", "utf-8")
        (a / "d" / "y").write_text("2", "utf-8")
        listing = "".join(f"{rel}\0{hashlib.sha256(data).hexdigest()}\n" for rel, data in
                          sorted([("d/y", b"2"), ("x", b"1")]))
        self.assertEqual(rb.tree_sha(a), hashlib.sha256(listing.encode()).hexdigest())
        before = rb.tree_sha(a)
        (a / "x").write_text("3", "utf-8")
        self.assertNotEqual(rb.tree_sha(a), before)


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        for stream in (contextlib.redirect_stdout(self.stdout), contextlib.redirect_stderr(self.stderr)):
            stream.__enter__()
            self.addCleanup(stream.__exit__, None, None, None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_main_builds(self):
        table = self.tmp / "t.json"
        table.write_text("[]", "utf-8")
        out = self.tmp / "out"
        code = rb.main(["build", "--version", VERSION, "--out", str(out), "--table", str(table)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads((out / "bundle.json").read_text("utf-8"))["version"], VERSION)

    def test_main_rejects_a_bad_version(self):
        self.assertEqual(rb.main(["build", "--version", "1.2", "--out", str(self.tmp / "o")]), 1)
        self.assertIn("not X.Y.Z", self.stderr.getvalue())
        self.assertFalse((self.tmp / "o").exists())

    def test_main_defaults_to_the_app_version(self):
        out = self.tmp / "o"
        self.assertEqual(rb.main(["build", "--out", str(out)]), 0)
        self.assertEqual(json.loads((out / "bundle.json").read_text("utf-8"))["version"], rb.app_version(ROOT))


if __name__ == "__main__":
    unittest.main()
