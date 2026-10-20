"""The instructable JSON Schema's sub-step shape. Standard library only."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

SCHEMA = json.loads((Path(__file__).resolve().parent.parent / "schema" / "instructable.v1.json").read_text("utf-8"))
LEAF_KEYS = {"do", "where", "code", "lang", "expect", "detail", "url"}


class SchemaTest(unittest.TestCase):
    def test_a_leaf_is_todays_step(self):
        leaf = SCHEMA["$defs"]["leaf"]
        self.assertEqual(set(leaf["properties"]), LEAF_KEYS)
        self.assertEqual(leaf["required"], ["do"])
        self.assertIs(leaf["additionalProperties"], False)

    def test_a_step_is_a_leaf_plus_substeps(self):
        step = SCHEMA["$defs"]["step"]
        self.assertEqual(set(step["properties"]), LEAF_KEYS | {"substeps"})
        self.assertEqual(step["required"], ["do"])
        self.assertIs(step["additionalProperties"], False)
        self.assertEqual(step["properties"]["substeps"],
                         {"type": "array", "minItems": 1, "maxItems": 10, "items": {"$ref": "#/$defs/leaf"}})
        for key in LEAF_KEYS:
            self.assertEqual(step["properties"][key], SCHEMA["$defs"]["leaf"]["properties"][key])

    def test_steps_use_step_and_verify_uses_leaf(self):
        self.assertEqual(SCHEMA["properties"]["steps"]["items"], {"$ref": "#/$defs/step"})
        self.assertEqual(SCHEMA["properties"]["steps"]["maxItems"], 20)
        self.assertEqual(SCHEMA["properties"]["verify"], {"$ref": "#/$defs/leaf"})

    def test_the_description_states_the_total(self):
        self.assertIn("Steps plus sub-steps total at most 60.", SCHEMA["description"])


if __name__ == "__main__":
    unittest.main()
