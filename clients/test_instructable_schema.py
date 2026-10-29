"""The instructable JSON Schema's step, sub-step, verify and question shapes. Standard library only."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parent.parent / "schema" / "instructable.v1.json").read_text("utf-8"))
VERIFY_KEYS = {"do", "where", "code", "lang", "expect", "detail", "url"}
LEAF_KEYS = VERIFY_KEYS | {"question", "blocking", "warning", "optional", "file", "id"}
ID_PATTERN = "^[a-z0-9][a-z0-9.-]{0,23}$"


class SchemaTest(unittest.TestCase):
    def test_verify_is_a_step_that_never_asks(self):
        verify = SCHEMA["$defs"]["verify"]
        self.assertEqual(set(verify["properties"]), VERIFY_KEYS)
        self.assertEqual(verify["required"], ["do"])
        self.assertIs(verify["additionalProperties"], False)
        self.assertEqual(SCHEMA["properties"]["verify"], {"$ref": "#/$defs/verify"})

    def test_a_leaf_is_a_sub_step_that_may_ask(self):
        leaf = SCHEMA["$defs"]["leaf"]
        self.assertEqual(set(leaf["properties"]), LEAF_KEYS)
        self.assertEqual(leaf["required"], ["do"])
        self.assertIs(leaf["additionalProperties"], False)
        self.assertEqual(leaf["properties"]["question"], {"$ref": "#/$defs/question"})
        for key in VERIFY_KEYS:
            self.assertEqual(leaf["properties"][key], SCHEMA["$defs"]["verify"]["properties"][key])

    def test_a_step_is_a_leaf_plus_substeps(self):
        step = SCHEMA["$defs"]["step"]
        self.assertEqual(set(step["properties"]), LEAF_KEYS | {"substeps"})
        self.assertEqual(step["required"], ["do"])
        self.assertIs(step["additionalProperties"], False)
        self.assertEqual(step["properties"]["substeps"],
                         {"type": "array", "minItems": 1, "maxItems": 10, "items": {"$ref": "#/$defs/leaf"}})
        for key in LEAF_KEYS:
            self.assertEqual(step["properties"][key], SCHEMA["$defs"]["leaf"]["properties"][key])

    def test_a_question_has_a_prompt_up_to_six_distinct_choices_and_multi(self):
        question = SCHEMA["$defs"]["question"]
        self.assertEqual(set(question["properties"]), {"prompt", "choices", "multi"})
        self.assertEqual(question["required"], ["prompt"])
        self.assertIs(question["additionalProperties"], False)
        self.assertEqual(question["properties"]["prompt"], {"type": "string", "minLength": 1, "maxLength": 300})
        choices = question["properties"]["choices"]
        self.assertEqual((choices["minItems"], choices["maxItems"], choices["uniqueItems"]), (0, 6, True))
        self.assertEqual(choices["items"], {"type": "string", "minLength": 1, "maxLength": 60})
        self.assertEqual(question["properties"]["multi"], {"type": "boolean", "default": False})

    def test_optional_is_a_boolean_on_steps_and_leaves_never_on_verify(self):
        for name in ("step", "leaf"):
            optional = SCHEMA["$defs"][name]["properties"]["optional"]
            self.assertEqual(optional["type"], "boolean")
            self.assertIs(optional["default"], False)
            self.assertIn("blocking", optional["description"])
        self.assertNotIn("optional", SCHEMA["$defs"]["verify"]["properties"])

    def test_file_is_a_local_path_on_steps_and_leaves_never_on_verify(self):
        for name in ("step", "leaf"):
            self.assertEqual(SCHEMA["$defs"][name]["properties"]["file"]["$ref"], "#/$defs/localPath")
        self.assertNotIn("file", SCHEMA["$defs"]["verify"]["properties"])
        local = SCHEMA["$defs"]["localPath"]
        self.assertEqual((local["type"], local["maxLength"]), ("string", 500))
        import re
        pattern = re.compile(local["pattern"])
        for good in ("/tmp/plan.md", "~/notes/plan.md", "/"):
            self.assertTrue(pattern.search(good), good)
        for bad in ("notes/plan.md", "~user/plan.md", "file:///tmp/x", "", "/tmp/a\nb", "/tmp/a\tb"):
            self.assertFalse(pattern.search(bad), bad)

    def test_a_link_has_exactly_one_of_url_and_path(self):
        link = SCHEMA["properties"]["links"]["items"]
        self.assertEqual(set(link["properties"]), {"label", "url", "path"})
        self.assertEqual(link["required"], ["label"])
        self.assertEqual(link["properties"]["path"], {"$ref": "#/$defs/localPath"})
        self.assertEqual(link["oneOf"], [{"required": ["url"]}, {"required": ["path"]}])

    def test_blocking_and_warning_sit_on_steps_and_leaves_never_on_verify(self):
        for name in ("step", "leaf"):
            props = SCHEMA["$defs"][name]["properties"]
            self.assertEqual(props["blocking"]["type"], "boolean")
            self.assertIs(props["blocking"]["default"], False)
            self.assertEqual((props["warning"]["type"], props["warning"]["maxLength"]), ("string", 300))
            self.assertNotIn("minLength", props["warning"])   # the validators accept an empty warning
        self.assertNotIn("blocking", SCHEMA["$defs"]["verify"]["properties"])
        self.assertNotIn("warning", SCHEMA["$defs"]["verify"]["properties"])
        self.assertEqual(SCHEMA["$defs"]["step"]["properties"]["blocking"],
                         SCHEMA["$defs"]["leaf"]["properties"]["blocking"])
        self.assertEqual(SCHEMA["$defs"]["step"]["properties"]["warning"],
                         SCHEMA["$defs"]["leaf"]["properties"]["warning"])

    def test_id_sits_on_steps_and_leaves_never_on_verify(self):
        import re
        for name in ("step", "leaf"):
            prop = SCHEMA["$defs"][name]["properties"]["id"]
            self.assertEqual((prop["type"], prop["pattern"]), ("string", ID_PATTERN))
        self.assertEqual(SCHEMA["$defs"]["step"]["properties"]["id"], SCHEMA["$defs"]["leaf"]["properties"]["id"])
        verify = SCHEMA["$defs"]["verify"]
        self.assertNotIn("id", verify["properties"])
        self.assertIs(verify["additionalProperties"], False)      # so verify.id is refused
        pattern = re.compile(ID_PATTERN)
        for good in ("s1", "r2-1", "s3.1", "a" * 24):
            self.assertTrue(pattern.search(good), good)
        for bad in ("S1x", "a" * 25, "-s1", ".s", "", "s 1"):
            self.assertFalse(pattern.search(bad), bad)

    def test_steps_use_step(self):
        self.assertEqual(SCHEMA["properties"]["steps"]["items"], {"$ref": "#/$defs/step"})
        self.assertEqual(SCHEMA["properties"]["steps"]["maxItems"], 20)

    def test_the_description_states_the_totals(self):
        self.assertIn("Steps plus sub-steps total at most 60.", SCHEMA["description"])
        self.assertIn("At most 20 of them ask a question; verify never does.", SCHEMA["description"])


if __name__ == "__main__":
    unittest.main()
