"""relay_semver against the shared vectors (the same file RelayCore's SemverTests read). Stdlib only."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

import relay_semver as sv

VECTORS = Path(__file__).resolve().parent.parent / "Tests" / "RelayCoreTests" / "Fixtures" / "semver-vectors.json"
CASES = json.loads(VECTORS.read_text("utf-8"))["cases"]


def of(kind):
    return [c for c in CASES if c["kind"] == kind]


class VectorTests(unittest.TestCase):
    def test_the_file_is_whole(self):
        self.assertGreaterEqual(len(CASES), 50)
        for kind in ("version", "order", "range", "pond"):
            self.assertTrue(of(kind), kind)

    def test_versions(self):
        for case in of("version"):
            with self.subTest(case["input"]):
                v = sv.parse_version(case["input"])
                if not case["valid"]:
                    self.assertIsNone(v)
                    continue
                major, minor, patch, pre = case["parts"]
                self.assertEqual((v.major, v.minor, v.patch, list(v.prerelease)), (major, minor, patch, pre))

    def test_order(self):
        for case in of("order"):
            with self.subTest(a=case["a"], b=case["b"]):
                a, b = sv.parse_version(case["a"]), sv.parse_version(case["b"])
                self.assertEqual(sv.compare(a, b), case["cmp"])
                self.assertEqual(sv.compare(b, a), -case["cmp"])
                self.assertEqual(a < b, case["cmp"] < 0)
                self.assertEqual(a > b, case["cmp"] > 0)
                self.assertEqual(a <= b, case["cmp"] <= 0)

    def test_ranges(self):
        for case in of("range"):
            with self.subTest(case["range"]):
                if not case["valid"]:
                    with self.assertRaises(ValueError) as ctx:
                        sv.parse_range(case["range"])
                    self.assertTrue(str(ctx.exception).startswith("invalid range: "))
                    continue
                rng = sv.parse_range(case["range"])
                self.assertTrue(case["checks"])
                for check in case["checks"]:
                    v = sv.parse_version(check["version"])
                    self.assertEqual(rng.contains(v), check["contains"], check["version"])
                    self.assertEqual(rng.fit(v), check["fit"], check["version"])

    def test_ponds(self):
        for case in of("pond"):
            with self.subTest(info=case["info"]):
                effective, legacy = sv.pond_version(case["info"])
                self.assertEqual(effective, sv.parse_version(case["effective"]))
                self.assertEqual(legacy, case["legacy"])


class HelperTests(unittest.TestCase):
    def test_at_least(self):
        self.assertTrue(sv.at_least(sv.parse_version("1.1.0"), "1.1.0"))
        self.assertTrue(sv.at_least(sv.parse_version("1.3.2"), "1.1.0"))
        self.assertTrue(sv.at_least(sv.parse_version("2.0.0"), "1.1.0"))
        self.assertFalse(sv.at_least(sv.parse_version("1.0.0"), "1.1.0"))
        self.assertFalse(sv.at_least(sv.parse_version("1.1.0-rc.1"), "1.1.0"))

    def test_str_is_the_version(self):
        self.assertEqual(str(sv.parse_version("1.2.0-rc.1+b.2")), "1.2.0-rc.1")
        self.assertEqual(str(sv.parse_version("1.1.0")), "1.1.0")

    def test_a_bad_range_names_the_bad_part(self):
        with self.assertRaises(ValueError) as ctx:
            sv.parse_range(">=1.0.0 ^1.1")
        self.assertEqual(str(ctx.exception), "invalid range: ^1.1")

    def test_equal_versions_ignore_build(self):
        self.assertEqual(sv.parse_version("1.0.0+a"), sv.parse_version("1.0.0+b"))


if __name__ == "__main__":
    unittest.main()
