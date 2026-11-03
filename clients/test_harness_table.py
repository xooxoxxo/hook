"""The harness table (integration/harnesses.json) against its schema and the plan's rules,
and the small JSON Schema validator that checks it. Standard library only."""
from __future__ import annotations

import copy
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any, Iterator, List, Tuple

import relay_bundle
import relay_jsonschema as js
import relay_lint
from test_relay_bundle import personal_hits

ROOT = Path(__file__).resolve().parent.parent
TABLE_PATH = ROOT / "integration" / "harnesses.json"
SCHEMA_PATH = ROOT / "integration" / "harnesses.schema.json"
INSTRUCTABLE = json.loads((ROOT / "schema" / "instructable.v1.json").read_text("utf-8"))

IDS = ["claude-code", "codex", "gemini-cli", "antigravity", "copilot-cli", "vscode-copilot", "cursor",
       "opencode", "zed", "pi", "devin", "factory", "kiro", "amp", "cline", "goose", "junie", "warp"]
ON_THE_MAC = {"claude-code", "codex", "gemini-cli", "copilot-cli", "cursor", "opencode", "zed", "pi"}
PIECES = ("mcp", "skill", "instructions", "replies")
LEVELS = ("docs-only", "pending", "machine")       # lowest first
DUMMY = {
    "home": "/Users/me", "harness_home": "/Users/me/.harness", "python": "python3",
    "mcp_server": "/Users/me/.local/share/hook/current/mcp/relay_mcp.py",
    "relay": "/Users/me/.local/share/hook/current/bin/relay",
    "bundle": "/Users/me/.local/share/hook/current/integration",
    "instructions": "/Users/me/.local/share/hook/current/integration/instructions/hook.md",
    "instructions_home_ref": "~/.local/share/hook/current/integration/instructions/hook.md",
    "plugins": "/Users/me/.local/share/hook/plugins", "version": "0.13.0", "schema": "1",
}


def load() -> Tuple[List[dict], dict]:
    return json.loads(TABLE_PATH.read_text("utf-8")), json.loads(SCHEMA_PATH.read_text("utf-8"))


def strings(node: Any, path: str = "$") -> Iterator[Tuple[str, str]]:
    """(path, string) for every string (keys included) anywhere in node."""
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield f"{path}.{key}<key>", key
            yield from strings(value, f"{path}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from strings(value, f"{path}[{i}]")


def alternatives(entry: dict) -> Iterator[Tuple[str, dict]]:
    for piece in PIECES:
        for alt in entry["pieces"][piece]:
            yield piece, alt


class HarnessTableTest(unittest.TestCase):
    def setUp(self):
        self.table, self.schema = load()
        self.by_id = {e["id"]: e for e in self.table}

    def test_table_validates_against_schema(self):
        self.assertEqual(js.validate(self.table, self.schema), [])

    def test_ids_unique_and_count(self):
        ids = [e["id"] for e in self.table]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(sorted(ids), sorted(IDS))
        self.assertEqual(len(ids), 18)

    def test_every_piece_present(self):
        for entry in self.table:
            with self.subTest(entry["id"]):
                self.assertEqual(set(entry["pieces"]), set(PIECES))
                for piece in PIECES:
                    self.assertTrue(entry["pieces"][piece], piece)

    def test_plugin_pieces_have_a_plugin(self):
        for entry in self.table:
            with self.subTest(entry["id"]):
                uses = any(alt["method"] == "plugin" for _, alt in alternatives(entry))
                self.assertEqual(uses, entry["plugin"] is not None)
                if entry["plugin"]:
                    render = entry["plugin"]["render"]
                    self.assertTrue((ROOT / "integration" / "src" / render).is_dir(), render)

    def test_verified_levels(self):
        for entry in self.table:
            with self.subTest(entry["id"]):
                levels = [alt["verified"] for _, alt in alternatives(entry)]
                if entry["plugin"]:
                    levels.append(entry["plugin"]["verified"])
                self.assertEqual(entry["verified"], min(levels, key=LEVELS.index))
                self.assertEqual(entry["verified"], "pending" if entry["id"] in ON_THE_MAC else "docs-only")

    def test_placeholders_known(self):
        for entry in self.table:
            for path, text in strings(entry):
                for name in relay_bundle.template_names(text):
                    with self.subTest(entry=entry["id"], path=path):
                        self.assertTrue(relay_bundle.known_placeholder(name), name)
                self.assertNotIn("{{", re.sub(r"\{\{[^{}]*\}\}", "", text), f"{entry['id']} {path}")

    def test_sources_exist_in_the_bundle(self):
        files = {p.relative_to(ROOT / "integration" / "src").as_posix() for p in (ROOT / "integration" / "src").rglob("*")}
        bundle_paths = {"skills/instructables"} | {f"instructions/hook{ext}" for ext in
                                                   (".md", ".mdc", ".instructions.md", ".steering.md")}
        for entry in self.table:
            for piece, alt in alternatives(entry):
                if "source" in alt:
                    with self.subTest(entry=entry["id"], piece=piece):
                        self.assertTrue(alt["source"] in bundle_paths or alt["source"] in files, alt["source"])

    def test_no_versioned_paths(self):
        for entry in self.table:
            for path, text in strings(entry):
                with self.subTest(entry=entry["id"], path=path):
                    self.assertNotIn("/hook/0.", text)
                    self.assertIsNone(re.search(r"/v?\d+\.\d+(\.\d+)?(/|$)", text), text)

    def test_no_documents_folder(self):
        for entry in self.table:
            for path, text in strings(entry):
                with self.subTest(entry=entry["id"], path=path):
                    self.assertNotRegex(text, r"(~|\{\{home\}\})/Documents|/Documents/")

    def test_no_personal_strings(self):
        for path in (TABLE_PATH, SCHEMA_PATH):
            text = path.read_text("utf-8")
            self.assertNotIn("/Users/", text)
            self.assertEqual(personal_hits(text), [])

    def test_owner_step_shape(self):
        steps = [(e["id"], s) for e in self.table for s in e["owner_steps"]]
        self.assertEqual(sorted(s["id"] for _, s in steps), ["codex-trust", "cursor-reload", "warp-rule"])
        for harness, step in steps:
            with self.subTest(step["id"]):
                body = {k: v for k, v in step.items() if k not in ("id", "when")}
                text = relay_bundle.render_text(json.dumps(body), DUMMY, json_escape=True)
                instructable = dict(json.loads(text), v=1)
                self.assertEqual(js.validate(instructable, INSTRUCTABLE), [])
                self.assertEqual(relay_lint.lint_instructable(instructable), [])
                target = step["when"].split(":", 1)
                if target[0] == "after":
                    entry = self.by_id[harness]
                    self.assertTrue(target[1] == "plugin" and entry["plugin"] or target[1] in PIECES, step["when"])

    def test_owner_alternatives_name_a_step(self):
        for entry in self.table:
            ids = {s["id"] for s in entry["owner_steps"]}
            for piece, alt in alternatives(entry):
                if alt["method"] == "owner":
                    with self.subTest(entry=entry["id"], piece=piece):
                        self.assertIn(alt["step"], ids)

    def test_sources_https_and_checked_date(self):
        for entry in self.table:
            with self.subTest(entry["id"]):
                self.assertTrue(entry["sources"])
                for url in entry["sources"]:
                    self.assertTrue(url.startswith("https://"), url)
                self.assertEqual(entry["checked"], "2026-11-03")

    def test_shared_skill_target(self):
        agents = [e["id"] for e in self.table for alt in e["pieces"]["skill"]
                  if alt["method"] == "copy" and alt["path"] == "~/.agents/skills/instructables"]
        self.assertEqual(len(agents), 15)
        self.assertNotIn("kiro", agents)
        self.assertEqual(self.by_id["kiro"]["pieces"]["skill"][0]["path"], "~/.kiro/skills/instructables")

    def test_cli_alternatives_come_first_and_have_a_file_fallback(self):
        for entry in self.table:
            mcp = entry["pieces"]["mcp"]
            methods = [alt["method"] for alt in mcp]
            if "cli" in methods:
                with self.subTest(entry["id"]):
                    self.assertEqual(methods[0], "cli")
                    self.assertEqual(mcp[0]["requires"], mcp[0]["add"][0])
                    if entry["id"] != "claude-code":
                        self.assertEqual(methods[1:], ["key"])
                        self.assertEqual(mcp[0]["writes"]["path"], mcp[1]["path"])
                        self.assertEqual(mcp[0]["writes"]["key"], mcp[1]["key"])

    def test_replies_formats(self):
        expected = {"claude-code": None, "codex": "claude", "gemini-cli": None, "antigravity": None,
                    "copilot-cli": "copilot", "vscode-copilot": "copilot", "cursor": None, "opencode": "plain",
                    "zed": "none", "pi": "plain", "devin": "claude", "factory": "claude", "kiro": "none",
                    "amp": "plain", "cline": "none", "goose": "none", "junie": "none", "warp": "none"}
        for entry in self.table:
            with self.subTest(entry["id"]):
                alt = entry["pieces"]["replies"][0]
                want = expected[entry["id"]]
                if want is None:
                    self.assertEqual(alt["method"], "plugin")
                elif want == "none":
                    self.assertEqual(alt["method"], "none")
                    self.assertTrue(alt["reason"])
                elif alt["method"] == "file":
                    src = (ROOT / "integration" / "src" / alt["source"]).read_text("utf-8")
                    self.assertTrue(f"{{{{replies:{want}}}}}" in src or f'"--format", "{want}"' in src, src[:200])
                else:
                    self.assertIn(f"{{{{replies:{want}}}}}", json.dumps(alt["value"]))

    def test_the_bundle_carries_the_table(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        manifest = relay_bundle.build(ROOT / "integration" / "src", ROOT / "skill" / "instructables", TABLE_PATH,
                                      tmp / "integration", "0.13.0")
        self.assertIn("harnesses.json", manifest["files"])
        self.assertEqual((tmp / "integration" / "harnesses.json").read_bytes(), TABLE_PATH.read_bytes())

    def test_schema_rejects_unknown_method(self):
        bad = copy.deepcopy(self.table)
        bad[0]["pieces"]["mcp"][0]["method"] = "magic"
        errors = js.validate(bad, self.schema)
        self.assertTrue(any(e.startswith("$[0].pieces.mcp[0]") for e in errors), errors)
        missing = copy.deepcopy(self.table)
        missing[1]["pieces"]["replies"][0].pop("match")
        self.assertEqual(js.validate(missing, self.schema),
                         ["$[1].pieces.replies[0]: matches none of oneOf", "$[1].pieces.replies[0].match: required"])

    def test_schema_rejects_other_mistakes(self):
        cases = [
            lambda t: t[1].update(extra=True),                                       # unknown key
            lambda t: t[1].update(verified="maybe"),
            lambda t: t[1]["pieces"].pop("skill"),
            lambda t: t[1]["pieces"]["replies"][0].pop("match"),                     # append without match
            lambda t: t[1]["pieces"]["instructions"][0].update(content="ref-or-full"),   # no ref
            lambda t: t[1]["pieces"]["mcp"][1].update(format="ini"),
            lambda t: t[1]["owner_steps"][0].update(when="later"),
            lambda t: t[1].update(sources=[]),
            lambda t: t[1].update(checked="3 Nov"),
            lambda t: t[1]["pieces"]["mcp"][1].update(path="relative/config.toml"),
            lambda t: t[1]["pieces"].update(replies=[]),
            lambda t: t[16]["pieces"]["replies"][0].pop("reason"),                   # none without reason
        ]
        self.assertEqual(self.table[1]["id"], "codex")
        self.assertEqual(self.table[16]["id"], "junie")
        for i, mutate in enumerate(cases):
            with self.subTest(i):
                bad = copy.deepcopy(self.table)
                mutate(bad)
                self.assertNotEqual(js.validate(bad, self.schema), [])


class JsonSchemaTest(unittest.TestCase):
    def test_types_consts_and_enums(self):
        self.assertEqual(js.validate(1, {"type": "integer"}), [])
        self.assertEqual(js.validate(True, {"type": "integer"}), ["$: must be integer"])
        self.assertEqual(js.validate(None, {"type": ["string", "null"]}), [])
        self.assertEqual(js.validate(1, {"const": True}), ["$: must be true"])
        self.assertEqual(js.validate("b", {"enum": ["a"]}), ['$: must be one of ["a"]'])

    def test_objects_arrays_and_strings(self):
        schema = {"type": "object", "required": ["a"], "additionalProperties": False,
                  "properties": {"a": {"type": "array", "minItems": 1, "maxItems": 2, "uniqueItems": True,
                                       "items": {"type": "string", "minLength": 2, "maxLength": 3, "pattern": "^x"}}}}
        self.assertEqual(js.validate({"a": ["xy"]}, schema), [])
        self.assertEqual(js.validate({}, schema), ["$.a: required"])
        self.assertEqual(js.validate({"a": ["xy"], "b": 1}, schema), ["$.b: unknown key"])
        self.assertEqual(js.validate({"a": []}, schema), ["$.a: at least 1 item(s)"])
        self.assertIn("$.a: items must be unique", js.validate({"a": ["xy", "xy"]}, schema))
        self.assertEqual(js.validate({"a": ["y", "xyzw"]}, schema),
                         ["$.a[0]: at least 2 character(s)", "$.a[0]: must match ^x", "$.a[1]: at most 3 character(s)"])
        self.assertEqual(js.validate({"k": 1}, {"additionalProperties": {"type": "string"}}), ["$.k: must be string"])

    def test_refs_and_one_of(self):
        schema = {"$defs": {"a": {"type": "object", "additionalProperties": False, "required": ["m"],
                                  "properties": {"m": {"const": "a"}, "x": {"type": "string"}}},
                            "b": {"type": "object", "additionalProperties": False, "required": ["m", "y"],
                                  "properties": {"m": {"const": "b"}, "y": {"type": "integer"}}}},
                  "oneOf": [{"$ref": "#/$defs/a"}, {"$ref": "#/$defs/b"}]}
        self.assertEqual(js.validate({"m": "a"}, schema), [])
        self.assertEqual(js.validate({"m": "b", "y": 2}, schema), [])
        errors = js.validate({"m": "b", "y": "two"}, schema)
        self.assertEqual(errors, ["$: matches none of oneOf", "$.y: must be integer"])
        self.assertEqual(js.validate(1, {"anyOf": [{"type": "string"}, {"type": "integer"}]}), [])
        self.assertEqual(js.validate(1, {"oneOf": [{"type": "number"}, {"type": "integer"}]}),
                         ["$: matches 2 of oneOf, must match exactly one"])

    def test_unsupported_keywords_raise(self):
        with self.assertRaises(js.SchemaError):
            js.validate(1, {"minimum": 0})
        with self.assertRaises(js.SchemaError):
            js.validate(1, {"$ref": "other.json"})

    def test_instructable_schema_agrees_with_the_skill_checker(self):
        good = {"v": 1, "title": "x", "steps": [{"do": "a", "id": "s1"}], "verify": {"do": "b"}}
        bad = {"v": 1, "title": "x", "steps": [{"do": "a", "id": "S1"}], "verify": {"do": "b", "id": "s9"}}
        self.assertEqual(js.validate(good, INSTRUCTABLE), [])
        errors = js.validate(bad, INSTRUCTABLE)
        self.assertIn("$.steps[0].id: must match ^[a-z0-9][a-z0-9.-]{0,23}$", errors)
        self.assertIn("$.verify.id: unknown key", errors)


if __name__ == "__main__":
    unittest.main()
