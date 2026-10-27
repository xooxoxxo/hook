"""Per-step answers on the clients: helpers, `relay wait` settle, status, replies. Stdlib only."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path

import relay_cli
import relay_client as rc
import relay_replies as rr
import relay_wait as rw
from answers_fixture import ASK_ID, INSTRUCTABLE, ITEM, answer, detail, event
from test_relay_wait import FakeAsk, FakeClock

POSTED = event(1, "posted", "session")


class HelpersTest(unittest.TestCase):
    def test_questions_in_document_order(self):
        self.assertEqual(list(rc.questions(INSTRUCTABLE)), ["1", "2", "3", "4", "4.2"])
        self.assertEqual(rc.questions(None), {})
        self.assertEqual(rc.questions({"steps": "x"}), {})

    def test_latest_answer_per_path_wins_and_skips_junk(self):
        events = [answer(5, "1", ["Prod"]), answer(2, "1", ["Staging"]), answer(3, "3", text="EU"),
                  answer(4, "2", ["Logs"], actor="session"), event(6, "reply", "owner", "hi"),
                  {"seq": 7, "kind": "answer", "actor": "owner", "text": "not json"}, "junk"]
        got = rc.latest_answers(events)
        self.assertEqual(got, {"1": {"picked": ["Prod"], "at": "2026-10-11T09:05:00+00:00", "seq": 5},
                               "3": {"text": "EU", "at": "2026-10-11T09:03:00+00:00", "seq": 3}})

    def test_answer_value_joins_picks_and_flattens_text(self):
        self.assertEqual(rc.answer_value({"picked": ["Logs", "Traces"]}), "Logs, Traces")
        self.assertEqual(rc.answer_value({"text": "one\ntwo"}), "one ⏎ two")

    def test_unanswered_in_document_order(self):
        events = [answer(2, "3", text="EU"), answer(3, "1", ["Staging"])]
        self.assertEqual(rc.unanswered(INSTRUCTABLE, events), ["2", "4", "4.2"])
        self.assertEqual(rc.unanswered({"steps": [{"do": "x"}]}, events), [])

    def test_instructable_of_reads_dict_or_json_string(self):
        self.assertEqual(rc.instructable_of(detail()), INSTRUCTABLE)
        as_string = {"item": {"payload": {"instructable": json.dumps(INSTRUCTABLE)}}}
        self.assertEqual(rc.instructable_of(as_string), INSTRUCTABLE)
        self.assertEqual(rc.instructable_of({"item": {"payload": {"instructable": "{bad"}}}), {})


class WaitAnswersTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def wait(self, client, **kw):
        out, err = io.StringIO(), io.StringIO()
        code = rw.run(client, ASK_ID, out=out, err=err, sleep=self.clock.sleep,
                      monotonic=self.clock.monotonic, **kw)
        return code, out.getvalue(), err.getvalue()

    def test_answer_settles_for_10_s_then_prints_lines_and_summary(self):
        one = detail(POSTED, answer(2, "1", ["Staging"]))
        client = FakeAsk(one, one, one, one, one, one, one, local=True)
        code, out, err = self.wait(client, interval=5)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out, "[Acme] Ship the Atlas release\n"
                              "  ↳ owner answer 1: Staging\n"
                              "answered 1 of 5; open: 2, 3, 4, 4.2\n"
                              "last seq: 2\n")
        self.assertEqual(self.clock.sleeps, [2.0] * 5)      # polls every 2 s at most while settling

    def test_a_newer_answer_restarts_the_settle(self):
        first = detail(POSTED, answer(2, "1", ["Staging"]))
        second = detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "2", ["Logs", "Traces"]))
        client = FakeAsk(first, first, first, second, second)
        code, out, _ = self.wait(client)
        self.assertEqual(code, 0)
        self.assertIn("  ↳ owner answer 1: Staging\n  ↳ owner answer 2: Logs, Traces\n"
                      "answered 2 of 5; open: 3, 4, 4.2\nlast seq: 3\n", out)
        self.assertGreaterEqual(sum(self.clock.sleeps), 10 + 4)

    def test_reply_during_the_settle_exits_at_once(self):
        client = FakeAsk(detail(POSTED, answer(2, "1", ["Staging"])),
                         detail(POSTED, answer(2, "1", ["Staging"]), event(3, "resolved", "owner", "done")))
        code, out, _ = self.wait(client)
        self.assertEqual(code, 0)
        self.assertIn("  ↳ owner answer 1: Staging\n  ↳ owner resolved 2026-10-11T09:03:00+00:00: done\n", out)
        self.assertEqual(self.clock.sleeps, [2.0])

    def test_all_answered_has_no_open_list_and_after_skips_old_answers(self):
        everything = [answer(2, "1", ["Prod"]), answer(3, "2", ["Logs"]), answer(4, "3", text="EU"),
                      answer(5, "4", ["Yes"]), answer(6, "4.2", ["Long"])]
        code, out, _ = self.wait(FakeAsk(detail(POSTED, *everything)))
        self.assertIn("answered 5 of 5\nlast seq: 6\n", out)
        self.assertEqual(self.wait(FakeAsk(detail(POSTED, *everything)), after=6, timeout=30)[0], 3)

    def test_ask_without_questions_prints_no_summary(self):
        plain = {"item": {"id": ASK_ID, "projectId": "Acme", "title": "T", "payload": {"instructable": {"v": 1}}},
                 "events": [POSTED, event(2, "reply", "owner", "ok")]}
        out = self.wait(FakeAsk(plain))[1]
        self.assertNotIn("answered", out)
        self.assertTrue(out.endswith("last seq: 2\n"))

    def test_timeout_during_a_settle_still_reports_the_answer(self):
        one = detail(POSTED, answer(2, "3", text="EU"))
        code, out, _ = self.wait(FakeAsk(one), timeout=6, interval=2)
        self.assertEqual(code, 0)
        self.assertIn("  ↳ owner answer 3: EU\n", out)


class StatusAnswersTest(unittest.TestCase):
    def test_text_block_lists_prompt_then_answer_then_unanswered(self):
        lines = relay_cli.format_status(detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "3", text="EU\nWest"),
                                               answer(4, "4.2", ["Long"])))
        self.assertEqual(lines[0], "open · Acme · Ship the Atlas release")
        self.assertEqual(lines[1:], ["Answers (3 of 5):",
                                     "  1  Which environment?", "     Staging",
                                     "  2  Which signals?",
                                     "  3  Which region?", "     EU ⏎ West",
                                     "  4  Ship today?",
                                     "  4.2  Which notes?", "     Long",
                                     "Unanswered: 2, 4"])

    def test_all_answered_has_no_unanswered_line(self):
        events = [answer(2, "1", ["Prod"]), answer(3, "2", ["Logs"]), answer(4, "3", text="EU"),
                  answer(5, "4", ["Yes"]), answer(6, "4.2", ["Long"])]
        lines = relay_cli.format_status(detail(*events))
        self.assertIn("Answers (5 of 5):", lines)
        self.assertFalse(any(l.startswith("Unanswered") for l in lines))

    def test_no_questions_no_block(self):
        lines = relay_cli.format_status({"item": {"status": "open", "projectId": "A", "title": "T"}, "events": []})
        self.assertEqual(lines, ["open · A · T"])

    def test_json_gains_answers_and_unanswered(self):
        data = relay_cli._status_json(detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "3", text="EU")))
        self.assertEqual(data["answers"], {"1": {"picked": ["Staging"], "at": "2026-10-11T09:02:00+00:00"},
                                           "3": {"text": "EU", "at": "2026-10-11T09:03:00+00:00"}})
        self.assertEqual(data["unanswered"], ["2", "4", "4.2"])
        self.assertEqual([e["kind"] for e in data["ownerEvents"]], ["answer", "answer"])


class RepliesAnswersTest(unittest.TestCase):
    def setUp(self):
        from test_relay_replies import FakeQueue
        self.tmp = tempfile.TemporaryDirectory()
        self.queue = FakeQueue({"RELAY_CONFIG": str(Path(self.tmp.name) / "relay" / "config.json")})
        self.queue.items[ASK_ID] = {"id": ASK_ID, "projectId": "Acme", "title": "Ship the Atlas release"}

    def tearDown(self):
        self.tmp.cleanup()

    def replies(self, **kw):
        out, err = io.StringIO(), io.StringIO()
        code = rr.run(self.queue, new=True, out=out, err=err, **{"hook": False, "session_id": None, **kw})
        return code, out.getvalue(), err.getvalue()

    def test_answers_print_like_other_owner_kinds_and_hook_line(self):
        self.replies(hook=True, session_id="s1")
        for ev in (answer(1, "3.2", ["Staging"]), answer(2, "4", text="Use the EU region")):
            self.queue.add(ASK_ID, ev["kind"], ev["actor"], ev["text"])
        self.queue.add(ASK_ID, "answer", "session", '{"step":"1","picked":["Prod"]}')
        self.queue.add(ASK_ID, "answer", "owner", "garbled")
        code, out, _ = self.replies(hook=True, session_id="s1")
        self.assertEqual(out, f"Hook: [{ASK_ID}] Acme · Ship the Atlas release — answer 3.2: Staging\n"
                              f"Hook: [{ASK_ID}] Acme · Ship the Atlas release — answer 4: Use the EU region\n"
                              f"Hook: [{ASK_ID}] Acme · Ship the Atlas release — answer: garbled\n")


if __name__ == "__main__":
    unittest.main()
