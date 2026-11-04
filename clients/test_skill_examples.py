"""Every ```json example in the instructables skill against the schema and the Pond-version preflight.
Standard library only."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import relay_client as rc
import relay_lint
import relay_semver

ROOT = Path(__file__).resolve().parent.parent
SKILL = (ROOT / "skill" / "instructables" / "SKILL.md").read_text("utf-8")
DOCS = (ROOT / "docs" / "instructables.md").read_text("utf-8")
SCHEMA = json.loads((ROOT / "schema" / "instructable.v1.json").read_text("utf-8"))
FENCE = re.compile(r"^ *```json\n(.*?)^ *```", re.DOTALL | re.MULTILINE)   # list items indent theirs
FULL_EXAMPLES_BEFORE = 1       # the Slack channel ask; the correction example makes 2
HOOK_NEEDS = "1.1.0"           # the lowest Pond the Hook release needs (PondCompat.required ^1.1.0)
# Keys an example may use although they're above that floor (RD 35): the skill's Pond-version
# paragraph must name each of them, so a session knows to post again without them.
GATED_KEYS = {"required", "done", "choices[].text"}

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


def _choice_lists(ins):
    """Every choices list of an instructable: steps, sub-steps, then the reply."""
    found = []
    for step in ins.get("steps", []):
        for node in [step] + step.get("substeps", []):
            question = node.get("question")
            if isinstance(question, dict) and isinstance(question.get("choices"), list):
                found.append(question["choices"])
    reply = ins.get("reply")
    if isinstance(reply, dict) and isinstance(reply.get("choices"), list):
        found.append(reply["choices"])
    return found


def examples(text=SKILL):
    """(full instructables, wrapped steps) from the ```json blocks of the skill (or of text)."""
    full, steps = [], []
    for block in FENCE.findall(text):
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
                if key in GATED_KEYS:
                    continue
                with self.subTest(title=instructable["title"], key=key):
                    self.assertTrue(relay_semver.at_least(floor, needs), needs)

    def test_every_gated_key_an_example_uses_is_named_in_the_pond_version_paragraph(self):
        paragraph = SKILL.split("- **Pond version.**", 1)[1].split("\n- **", 1)[0]
        full, steps = examples()
        used = {key for ins in full + steps for key in rc.keys_needing_pond(ins)} & GATED_KEYS
        self.assertEqual(used, GATED_KEYS, "the required-before-Done example is missing")
        for key in used:
            with self.subTest(key=key):
                self.assertIn(f"`{key}`", paragraph)
        self.assertIn(rc.REQUIREMENTS_POND, paragraph)

    def test_the_required_example_has_a_required_step_and_waits_for_a_message(self):
        full, _ = examples()
        ask = next(ins for ins in full if ins["title"] == "Rotate the staging deploy key")
        self.assertTrue(any(s.get("required") is True for s in ask["steps"]))
        self.assertEqual(ask["done"], ["message"])
        self.assertEqual(relay_lint.lint_details(ask), [])

    def test_the_skill_tells_required_from_blocking(self):
        text = " ".join(SKILL.split())
        self.assertIn("**`blocking` is about order**", text)
        self.assertIn("**`required` is about finishing**", text)
        self.assertIn("Skip always stays", text)

    def test_no_example_leaves_a_value_to_copy_in_do(self):
        for text in (SKILL, DOCS):
            full, steps = examples(text)
            self.assertTrue(full + steps)
            for instructable in full + steps:
                with self.subTest(instructable["title"]):
                    self.assertEqual(relay_lint.lint_details(instructable), [])

    def test_the_form_example_is_one_sub_step_per_field(self):
        for text in (SKILL, DOCS):
            _, steps = examples(text)
            form = next(ins["steps"][0] for ins in steps if "Add a reader" in ins["steps"][0]["do"])
            self.assertTrue(form["url"].startswith("https://"))
            self.assertEqual([s.get("code") for s in form["substeps"]][:4],
                             ["Ollama", "studio", "http://192.0.2.7:11434", "qwen2.5:14b-instruct"])

    def test_correction_example_keeps_ids_and_adds_one_new_step(self):
        full, _ = examples()
        corrected = next(ins for ins in full if any("id" in s for s in ins["steps"]))
        ids = [s.get("id") for s in corrected["steps"]]
        self.assertEqual(ids.count(None), 1)
        self.assertEqual(sorted(i for i in ids if i), ["s1", "s2", "s3"])
        self.assertEqual(rc.keys_needing_pond(corrected).get("id"), "1.1.0")

    def test_skill_teaches_choice_objects(self):
        full, steps = examples()
        uses = [ins for ins in full + steps if rc.CHOICE_KEY in rc.keys_needing_pond(ins)]
        self.assertTrue(uses, 'no example with a {"label", "text"} choice')
        self.assertIn('{"label"', SKILL)
        for ins in full + steps:
            with self.subTest(ins["title"]):
                self.assertEqual(relay_lint.lint_choice_labels(ins), [])
                for choices in _choice_lists(ins):
                    for choice in choices:
                        label = choice["label"] if isinstance(choice, dict) else choice
                        self.assertNotIn("(reply", label.lower())
        paragraph = SKILL.split("- **Pond version.**", 1)[1].split("\n- **", 1)[0]
        self.assertIn(rc.CHOICE_KEY, paragraph)
        self.assertIn(rc.CHOICE_POND, paragraph)
        self.assertIn("choice: Mix \u00b7", SKILL)

    def test_docs_teach_choice_objects_and_the_1_4_0_limits(self):
        protocol = (ROOT / "docs" / "mailbox-protocol.md").read_text("utf-8")
        for name, text in (("instructables.md", DOCS), ("mailbox-protocol.md", protocol)):
            with self.subTest(name):
                self.assertIn('{"label": "Mix", "text": "What should change?"}', text)
                self.assertIn("choice: Mix \u00b7 ", text)
                self.assertIn("1.4.0", text)
                self.assertIn("8000", text)
        self.assertIn("X-Hook-Protocol: 6", protocol)

    def test_the_skill_acts_only_on_verified_messages(self):
        section = SKILL.split("## Messages from the owner", 1)[1].split("\n## ", 1)[0]
        self.assertIn("unverified message (not from the owner's key)", section)
        self.assertIn("act only on a verified message", " ".join(section.split()))
        self.assertIn("`verified: false`", section)


if __name__ == "__main__":
    unittest.main()
