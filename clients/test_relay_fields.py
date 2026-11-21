"""relay_fields and the `fields` fallback in relay post, amend and append. Stdlib only."""
from __future__ import annotations

import io
import json
import unittest

import relay_cli
import relay_client as rc
import relay_fields
from test_relay_amend import ASK, H2
from test_relay_append import APPEND, NOTE, AppendPond
from test_relay_append import FEATURES as APPEND_FEATURES
from test_relay_client import ITEM_ID, Base, FakeClock

ROWS = [{"label": "Name", "value": "requests-ip", "copy": True},
        {"label": "Method", "value": "POST"}]
TABLE = {"v": 1, "title": "Add the rate limit rule", "steps": [
    {"do": "Add the custom rule", "detail": "Same shape as the press-account rule.", "fields": ROWS,
     "substeps": [{"do": "Save"}]},
    {"do": "Deploy"}]}
AS_SUBSTEPS = {"v": 1, "title": "Add the rate limit rule", "steps": [
    {"do": "Add the custom rule", "detail": "Same shape as the press-account rule.", "id": "s1", "substeps": [
        {"do": "Name", "code": "requests-ip", "lang": "text", "id": "s1-f1"},
        {"do": "Method", "code": "POST", "lang": "text", "id": "s1-f2"},
        {"do": "Save", "id": "s1.1"}]},
    {"do": "Deploy", "id": "s2"}]}
NOTE_ONE = ("the Pond doesn't list the fields feature: the settings of steps[0] were sent as sub-steps "
            "(label as do, value as code)")


class RowsAsSubstepsTests(unittest.TestCase):
    def test_a_post_without_ids_numbers_every_step_first(self):
        out, moved = relay_fields.rows_as_substeps(TABLE, number=True)
        self.assertEqual(out, AS_SUBSTEPS)
        self.assertEqual(moved, ["steps[0]"])
        self.assertIn("fields", TABLE["steps"][0])                      # the input is not mutated

    def test_given_ids_are_kept(self):
        ask = {"v": 1, "title": "t", "steps": [{"do": "Add it", "id": "rule", "fields": ROWS[:1]}]}
        out, _ = relay_fields.rows_as_substeps(ask, number=True)
        self.assertEqual(out["steps"], [{"do": "Add it", "id": "rule", "substeps": [
            {"do": "Name", "code": "requests-ip", "lang": "text", "id": "rule-f1"}]}])

    def test_without_number_a_step_without_an_id_gives_rows_none(self):
        out, _ = relay_fields.rows_as_substeps({"steps": [{"do": "Add it", "fields": ROWS[:1]}]})
        self.assertEqual(out, {"steps": [{"do": "Add it", "substeps": [
            {"do": "Name", "code": "requests-ip", "lang": "text"}]}]})

    def test_a_sub_steps_rows_follow_it_as_siblings(self):
        ask = {"steps": [{"do": "Fill in the form", "id": "form", "substeps": [
            {"do": "Open it", "id": "open"}, {"do": "Enter these", "id": "enter", "fields": ROWS},
            {"do": "Submit", "id": "submit"}]}]}
        out, moved = relay_fields.rows_as_substeps(ask)
        self.assertEqual([(s["do"], s["id"]) for s in out["steps"][0]["substeps"]],
                         [("Open it", "open"), ("Enter these", "enter"), ("Name", "enter-f1"),
                          ("Method", "enter-f2"), ("Submit", "submit")])
        self.assertNotIn("fields", out["steps"][0]["substeps"][1])
        self.assertEqual(moved, ["steps[0].substeps[1]"])

    def test_a_taken_or_long_id_falls_back_to_f_k(self):
        long_id = "a" * 22
        ask = {"steps": [{"do": "Add it", "id": long_id, "fields": ROWS},
                         {"do": "Other", "id": "f1"}]}
        out, _ = relay_fields.rows_as_substeps(ask)
        self.assertEqual([s["id"] for s in out["steps"][0]["substeps"]], ["f2", "f3"])

    def test_the_same_body_gives_the_same_ids(self):
        self.assertEqual(relay_fields.rows_as_substeps(TABLE, number=True),
                         relay_fields.rows_as_substeps(TABLE, number=True))

    def test_too_many_sub_steps_are_refused(self):
        ask = {"steps": [{"do": "Add it", "fields": [{"label": f"L{n}", "value": "v"} for n in range(8)],
                          "substeps": [{"do": "a"}, {"do": "b"}, {"do": "c"}]}]}
        with self.assertRaises(relay_fields.FieldsDontFit) as ctx:
            relay_fields.rows_as_substeps(ask)
        self.assertIn("steps[0].fields:", str(ctx.exception))
        self.assertIn("11 sub-steps (at most 10)", str(ctx.exception))

    def test_no_fields_is_unchanged(self):
        self.assertEqual(relay_fields.rows_as_substeps(ASK, number=True), (ASK, []))
        self.assertFalse(relay_fields.has_fields({"steps": [{"do": "a", "fields": None}]}))

    def test_the_note_names_every_step(self):
        self.assertEqual(relay_fields.fallback_note(["steps[0]"]), NOTE_ONE)
        self.assertIn("the settings of steps[0], steps[2].substeps[1] were",
                      relay_fields.fallback_note(["steps[0]", "steps[2].substeps[1]"]))


class FieldsPond(AppendPond):
    def __init__(self, features):
        super().__init__("1.13.0", features)


class FallbackTests(Base):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()

    def client(self):
        cfg = {"mailboxURL": "https://pond.example.test/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=self.env, urlopen=self.http, sleep=self.clock.sleep,
                         monotonic=self.clock.monotonic)

    def posted(self):
        """What each post sent, without the `from` relay post fills in."""
        sent = [json.loads(r.data)["instructable"] for r in self.http.sent("/asks")]
        return [{k: v for k, v in ins.items() if k != "from"} for ins in sent]

    def test_a_pond_with_the_feature_gets_fields_as_they_are(self):
        self.http = FieldsPond(APPEND_FEATURES + ["fields"])
        res = self.client().post("Acme", TABLE)
        self.assertEqual(self.posted(), [TABLE])
        self.assertNotIn("notes", res)

    def test_a_pond_without_the_feature_gets_sub_steps_and_a_note(self):
        for features in (APPEND_FEATURES, None):
            with self.subTest(features=features):
                self.http = FieldsPond(features)
                rc._ponds.clear()
                res = self.client().post("Acme", TABLE)
                self.assertEqual(self.posted(), [AS_SUBSTEPS])
                self.assertEqual(res["notes"], [NOTE_ONE])

    def test_rows_that_dont_fit_are_refused_before_anything_is_sent(self):
        self.http = FieldsPond(APPEND_FEATURES)
        ask = {"v": 1, "title": "t", "steps": [
            {"do": "Add it", "fields": [{"label": f"Setting {n}", "value": "v"} for n in range(11)]}]}
        with self.assertRaises(rc.Refused) as ctx:
            self.client().post("Acme", ask)
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(self.http.sent("/asks"), [])

    def test_amend_falls_back_too(self):
        self.http = FieldsPond(APPEND_FEATURES)
        self.client().post("Acme", ASK)
        fixed = {"v": 1, "title": "Check Node", "steps": [{"do": "Run it", "id": "s1", "fields": ROWS[:1]}]}
        res = self.client().amend(ITEM_ID, "Name the rule", fixed)
        sent = json.loads(self.http.sent(f"/asks/{ITEM_ID}/amend")[0].data)["instructable"]
        self.assertEqual(sent["steps"], [{"do": "Run it", "id": "s1", "substeps": [
            {"do": "Name", "code": "requests-ip", "lang": "text", "id": "s1-f1"}]}])
        self.assertEqual(res["notes"], [NOTE_ONE])

    def test_append_falls_back_too(self):
        self.http = FieldsPond(APPEND_FEATURES)
        self.client().post("Acme", ASK)
        res = self.client().append(ITEM_ID, NOTE, [{"do": "Add the rule", "fields": ROWS}])
        sent = json.loads(self.http.sent(APPEND)[0].data)["steps"]
        self.assertEqual(sent, [{"do": "Add the rule", "substeps": [
            {"do": "Name", "code": "requests-ip", "lang": "text"},
            {"do": "Method", "code": "POST", "lang": "text"}]}])
        self.assertEqual(res["notes"], [NOTE_ONE])
        self.assertEqual(res["hash"], H2)

    def test_relay_post_prints_the_note(self):
        self.http = FieldsPond(APPEND_FEATURES)
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(["post", "Acme", "--json", "-"], stdin=io.StringIO(json.dumps(TABLE)),
                              stdout=out, stderr=err, env=self.env, client_factory=lambda **_: self.client())
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn(f"note: {NOTE_ONE}\n", err.getvalue())


if __name__ == "__main__":
    unittest.main()
