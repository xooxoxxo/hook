"""An ask's `brief`: sent as it is to a Pond that lists the brief feature, dropped with a note
on one that doesn't, and the Ask about this events never read as the owner's acts."""
from __future__ import annotations

import io
import json
import unittest
from pathlib import Path

import relay_cli
import relay_client as rc
import relay_replies
import relay_wait
from test_relay_amend import ASK
from test_relay_append import FEATURES as APPEND_FEATURES
from test_relay_append import AppendPond
from test_relay_client import ITEM_ID, Base, FakeClock

BRIEF = ("## Why\nThe import job needs read access to charges.\n\n"
         "## Links I used\n- [Restricted keys](https://payments.example.test/docs/keys)\n")
WITH_BRIEF = {"v": 1, "title": "Create a restricted key", "steps": [{"do": "Open the API keys page"}],
              "brief": BRIEF}
NOTE = rc.BRIEF_NOTE
ASK_ABOUT_KINDS = ("ask_about_question", "ask_about_answer")
SCHEMA = json.loads((Path(__file__).resolve().parent.parent / "schema" / "instructable.v1.json")
                    .read_text(encoding="utf-8"))


class BriefPond(AppendPond):
    def __init__(self, features):
        super().__init__("1.14.0", features)


class BriefTests(Base):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()

    def client(self):
        cfg = {"mailboxURL": "https://pond.example.test/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=self.env, urlopen=self.http, sleep=self.clock.sleep,
                         monotonic=self.clock.monotonic)

    def posted(self):
        sent = [json.loads(r.data)["instructable"] for r in self.http.sent("/asks")]
        return [{k: v for k, v in ins.items() if k != "from"} for ins in sent]

    def test_a_pond_with_the_feature_gets_the_brief(self):
        self.http = BriefPond(APPEND_FEATURES + ["brief"])
        res = self.client().post("Acme", WITH_BRIEF)
        self.assertEqual(self.posted(), [WITH_BRIEF])
        self.assertNotIn("notes", res)

    def test_askabout_alone_is_not_the_brief_feature(self):
        """The gate is `brief`: a Pond lists it whether or not it has a key for Ask about this."""
        self.http = BriefPond(APPEND_FEATURES + ["askAbout"])
        res = self.client().post("Acme", WITH_BRIEF)
        self.assertNotIn("brief", self.posted()[0])
        self.assertEqual(res["notes"], [NOTE])

    def test_a_pond_without_the_feature_gets_the_ask_without_it_and_a_note(self):
        for features in (APPEND_FEATURES, None):
            with self.subTest(features=features):
                self.http = BriefPond(features)
                rc._ponds.clear()
                res = self.client().post("Acme", WITH_BRIEF)
                self.assertEqual(self.posted(), [{k: v for k, v in WITH_BRIEF.items() if k != "brief"}])
                self.assertEqual(res["notes"], [NOTE])

    def test_the_callers_instructable_is_not_changed(self):
        self.http = BriefPond(APPEND_FEATURES)
        ask = json.loads(json.dumps(WITH_BRIEF))
        self.client().post("Acme", ask)
        self.assertEqual(ask, WITH_BRIEF)

    def test_no_brief_means_no_note(self):
        self.http = BriefPond(APPEND_FEATURES)
        for ask in (ASK, {**ASK, "brief": None}):
            with self.subTest(ask=ask):
                self.assertNotIn("notes", self.client().post("Acme", ask))

    def test_amend_sends_the_brief_or_drops_it_the_same_way(self):
        for features, sent_brief, notes in ((APPEND_FEATURES + ["brief"], True, None),
                                            (APPEND_FEATURES, False, [NOTE])):
            with self.subTest(features=features):
                self.http = BriefPond(features)
                rc._ponds.clear()
                self.client().post("Acme", ASK)
                fixed = {"v": 1, "title": "Check Node", "steps": [{"do": "Run it", "id": "s1"}], "brief": BRIEF}
                res = self.client().amend(ITEM_ID, "Add the background", fixed)
                sent = json.loads(self.http.sent(f"/asks/{ITEM_ID}/amend")[-1].data)["instructable"]
                self.assertEqual("brief" in sent, sent_brief)
                self.assertEqual(res.get("notes"), notes)

    def test_relay_post_prints_the_note(self):
        self.http = BriefPond(APPEND_FEATURES)
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(["post", "Acme", "--json", "-"], stdin=io.StringIO(json.dumps(WITH_BRIEF)),
                              stdout=out, stderr=err, env=self.env, client_factory=lambda **_: self.client())
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn(f"note: {NOTE}\n", err.getvalue())

    def test_post_help_says_how_to_write_one(self):
        self.assertIn("`brief`", relay_cli.BRIEF_SENTENCE)
        self.assertIn("8000", relay_cli.BRIEF_SENTENCE)
        self.assertIn("send the `brief` again", relay_cli.AMEND_SENTENCE)


class SchemaTests(unittest.TestCase):
    def test_brief_is_an_ask_level_string_of_at_most_8000_characters(self):
        brief = SCHEMA["properties"]["brief"]
        self.assertEqual((brief["type"], brief["maxLength"]), ("string", 8000))
        self.assertNotIn("brief", SCHEMA["required"])
        for name in ("step", "leaf", "verify"):
            self.assertNotIn("brief", SCHEMA["$defs"][name]["properties"])


class AskAboutEventsTests(unittest.TestCase):
    """The Pond stores Ask about this as ask_about_question (actor owner) and ask_about_answer
    (actor hook). No reader of the owner's acts may count them: they must never wake a session."""

    def test_no_owner_kind_list_holds_them(self):
        for kind in ASK_ABOUT_KINDS:
            with self.subTest(kind=kind):
                self.assertNotIn(kind, relay_wait.OWNER_KINDS)
                self.assertNotIn(kind, rc.OWNER_EVENT_KINDS)
                self.assertNotIn(kind, rc.OWNER_LABELS)
                self.assertNotIn(kind, relay_replies.POSTER_ONLY)

    def test_the_readers_skip_them(self):
        events = [{"seq": 9 + i, "itemId": ITEM_ID, "kind": kind, "actor": actor, "text": "What is it?",
                   "at": "2026-11-21T09:00:00+00:00", "rev": 1, "auth": "owner-key"}
                  for i, (kind, actor) in enumerate(zip(ASK_ABOUT_KINDS, ("owner", "hook")))]
        self.assertEqual(relay_wait.owner_answers(events, 0), [])
        for event in events:
            self.assertIsNone(relay_replies._label(event)[0])

if __name__ == "__main__":
    unittest.main()
