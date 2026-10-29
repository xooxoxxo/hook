"""Every ```json example in the instructables skill against the schema and the Pond-version preflight.
Standard library only."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import relay_client as rc
import relay_semver

ROOT = Path(__file__).resolve().parent.parent
SKILL = (ROOT / "skill" / "instructables" / "SKILL.md").read_text("utf-8")
SCHEMA = json.loads((ROOT / "schema" / "instructable.v1.json").read_text("utf-8"))
FENCE = re.compile(r"^ *```json\n(.*?)^ *```", re.DOTALL | re.MULTILINE)   # list items indent theirs
FULL_EXAMPLES_BEFORE = 1       # the Slack channel ask; the correction example makes 2
HOOK_NEEDS = "1.1.0"           # the lowest Pond the Hook release needs (PondCompat.required ^1.1.0)

TYPES = {"string": str, "boolean": bool, "integer": int, "array": list, "object": dict}


def check(value, schema, path, errors):
    """The parts of JSON Schema the instructable schema uses: $ref, const, enum, type,
    properties/required/additionalProperties, items/minItems/maxItems, oneOf, string lengths
    and pattern."""
    if "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        check(value, SCHEMA["$defs"][name], path, errors)
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: not one of {schema['enum']}")
    kind = schema.get("type")
    if kind is not None:
        expected = TYPES[kind]
        if not isinstance(value, expected) or (kind == "integer" and isinstance(value, bool)):
            errors.append(f"{path}: must be {kind}")
            return
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}: required")
        for key, sub in value.items():
            if key in props:
                check(sub, props[key], f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}.{key}: unknown key")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", len(value)):
            errors.append(f"{path}: wrong number of items")
        for i, item in enumerate(value):
            if "items" in schema:
                check(item, schema["items"], f"{path}[{i}]", errors)
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", len(value)):
            errors.append(f"{path}: wrong length")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: must match {schema['pattern']}")
    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            trial = []
            check(value, option, path, trial)
            matches += not trial
        if matches != 1:
            errors.append(f"{path}: must match exactly one of oneOf")


def examples():
    """(full instructables, wrapped steps) from the skill's ```json blocks."""
    full, steps = [], []
    for block in FENCE.findall(SKILL):
        obj = json.loads(block)
        if "v" in obj:
            full.append(obj)
        else:
            steps.append({"v": 1, "title": "Example", "steps": [obj]})
    return full, steps


class SkillExampleTest(unittest.TestCase):
    def test_the_examples_are_all_there(self):
        full, steps = examples()
        self.assertGreater(len(full), FULL_EXAMPLES_BEFORE)
        self.assertGreaterEqual(len(steps), 2)
        self.assertTrue(any(any("id" in s for s in ins["steps"]) for ins in full),
                        "the correction example with step ids is missing")

    def test_each_example_passes_the_schema(self):
        full, steps = examples()
        for instructable in full + steps:
            with self.subTest(instructable["title"]):
                errors = []
                check(instructable, SCHEMA, "$", errors)
                self.assertEqual(errors, [])

    def test_the_checker_catches_what_it_should(self):
        bad = {"v": 1, "title": "x", "steps": [{"do": "a", "id": "S1"}], "verify": {"do": "b", "id": "s9"}}
        errors = []
        check(bad, SCHEMA, "$", errors)
        self.assertIn("$.steps[0].id: must match ^[a-z0-9][a-z0-9.-]{0,23}$", errors)
        self.assertIn("$.verify.id: unknown key", errors)

    def test_each_example_passes_the_pond_preflight_for_this_hook(self):
        full, steps = examples()
        floor = relay_semver.parse_version(HOOK_NEEDS)
        for instructable in full + steps:
            for key, needs in rc.keys_needing_pond(instructable).items():
                with self.subTest(title=instructable["title"], key=key):
                    self.assertTrue(relay_semver.at_least(floor, needs), needs)

    def test_correction_example_keeps_ids_and_adds_one_new_step(self):
        full, _ = examples()
        corrected = next(ins for ins in full if any("id" in s for s in ins["steps"]))
        ids = [s.get("id") for s in corrected["steps"]]
        self.assertEqual(ids.count(None), 1)
        self.assertEqual(sorted(i for i in ids if i), ["s1", "s2", "s3"])
        self.assertEqual(rc.keys_needing_pond(corrected).get("id"), "1.1.0")


if __name__ == "__main__":
    unittest.main()
