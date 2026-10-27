"""The instructable JSON Schema's step, sub-step, verify and question shapes. Standard library only."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parent.parent / "schema" / "instructable.v1.json").read_text("utf-8"))
VERIFY_KEYS = {"do", "where", "code", "lang", "expect", "detail", "url"}
LEAF_KEYS = VERIFY_KEYS | {"question"}


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

    def test_steps_use_step(self):
        self.assertEqual(SCHEMA["properties"]["steps"]["items"], {"$ref": "#/$defs/step"})
        self.assertEqual(SCHEMA["properties"]["steps"]["maxItems"], 20)

    def test_the_description_states_the_totals(self):
        self.assertIn("Steps plus sub-steps total at most 60.", SCHEMA["description"])
        self.assertIn("At most 20 of them ask a question; verify never does.", SCHEMA["description"])


if __name__ == "__main__":
    unittest.main()
