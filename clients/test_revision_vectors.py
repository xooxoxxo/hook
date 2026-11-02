"""relay_client against the shared revision vectors (Tests/RelayCoreTests/Fixtures/revision-vectors.json,
written by the Pond's gen_revision_vectors; RelayCore's tests read the same file). Stdlib only."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

import relay_client as rc

VECTORS = Path(__file__).resolve().parent.parent / "Tests" / "RelayCoreTests" / "Fixtures" / "revision-vectors.json"
FILE = json.loads(VECTORS.read_text("utf-8"))
CASES = FILE["cases"]
KINDS = ("hash", "canonical", "assign", "amend", "answerRule", "enrollCode", "keyHash", "stub", "duplicateKey")


def of(kind):
    return [c for c in CASES if c["kind"] == kind]


class RevisionVectorTests(unittest.TestCase):
    def test_the_file_is_whole(self):
        self.assertEqual(FILE["version"], 1)
        self.assertGreaterEqual(len(CASES), 60)
        for kind in KINDS:
            self.assertTrue(of(kind), kind)

    def test_an_edit_key_hashes_as_the_pond_stores_it(self):
        for case in of("keyHash"):
            with self.subTest(case["name"]):
                self.assertEqual(rc.EditKeys.key_hash(case["secret"]), case["hash"])


if __name__ == "__main__":
    unittest.main()
