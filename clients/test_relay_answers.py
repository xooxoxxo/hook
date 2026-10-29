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
        self.assertEqual(out, "[Acme] \"Ship the Atlas release\"\n"
                              "  ↳ owner answer 1 (version 1): \"Staging\"\n"
                              "answered 1 of 5; open: 2, 3, 4, 4.2\n"
                              "last seq: 2\n")
        self.assertEqual(self.clock.sleeps, [2.0] * 5)      # polls every 2 s at most while settling

    def test_a_project_cant_open_a_quote_or_a_second_part(self):
        from test_relay_replies import outside_quotes
        d = detail(POSTED, answer(2, "1", ["Staging"]))
        d["item"]["projectId"] = 'Acme] \u00b7 "x" \u2014 done: "y" \u21b3 owner reply'
        head = rw.format_answer(d, ASK_ID, [d["events"][1]])[0]
        self.assertEqual(head, "[Acme) . 'x' - done: 'y' > owner reply] \"Ship the Atlas release\"")
        self.assertEqual(outside_quotes(head).count("]"), 1)
        self.assertNotIn("\u21b3", outside_quotes(head))

    def test_a_newer_answer_restarts_the_settle(self):
        first = detail(POSTED, answer(2, "1", ["Staging"]))
        second = detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "2", ["Logs", "Traces"]))
        client = FakeAsk(first, first, first, second, second)
        code, out, _ = self.wait(client)
        self.assertEqual(code, 0)
        self.assertIn("  ↳ owner answer 1 (version 1): \"Staging\"\n"
                      "  ↳ owner answer 2 (version 1): \"Logs, Traces\"\n"
                      "answered 2 of 5; open: 3, 4, 4.2\nlast seq: 3\n", out)
        self.assertGreaterEqual(sum(self.clock.sleeps), 10 + 4)

    def test_reply_during_the_settle_exits_at_once(self):
        client = FakeAsk(detail(POSTED, answer(2, "1", ["Staging"])),
                         detail(POSTED, answer(2, "1", ["Staging"]), event(3, "resolved", "owner", "done")))
        code, out, _ = self.wait(client)
        self.assertEqual(code, 0)
        self.assertIn("  ↳ owner answer 1 (version 1): \"Staging\"\n"
                      "  ↳ owner resolved 2026-10-11T09:03:00+00:00: \"done\"\n", out)
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
        self.assertIn("  ↳ owner answer 3 (version 1): \"EU\"\n", out)


class StatusAnswersTest(unittest.TestCase):
    def test_text_block_lists_prompt_then_answer_then_unanswered(self):
        lines = relay_cli.format_status(detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "3", text="EU\nWest"),
                                               answer(4, "4.2", ["Long"])))
        self.assertEqual(lines[0], 'open · Acme · "Ship the Atlas release"')
        self.assertEqual(lines[1:], ["Answers (3 of 5):",
                                     '  1  "Which environment?"', '     "Staging"',
                                     '  2  "Which signals?"',
                                     '  3  "Which region?"', '     "EU ⏎ West"',
                                     '  4  "Ship today?"',
                                     '  4.2  "Which notes?"', '     "Long"',
                                     "Unanswered: 2, 4"])

    def test_all_answered_has_no_unanswered_line(self):
        events = [answer(2, "1", ["Prod"]), answer(3, "2", ["Logs"]), answer(4, "3", text="EU"),
                  answer(5, "4", ["Yes"]), answer(6, "4.2", ["Long"])]
        lines = relay_cli.format_status(detail(*events))
        self.assertIn("Answers (5 of 5):", lines)
        self.assertFalse(any(l.startswith("Unanswered") for l in lines))

    def test_a_project_cant_open_a_quote_or_a_second_part(self):
        from test_relay_replies import outside_quotes
        d = detail(POSTED)
        d["item"]["projectId"] = 'Acme \u00b7 "x" \u2014 done: "y"'
        head = relay_cli.format_status(d)[0]
        self.assertEqual(head, "open · Acme . 'x' - done: 'y' · \"Ship the Atlas release\"")
        self.assertEqual(outside_quotes(head).count(" \u2014 "), 0)
        self.assertEqual(outside_quotes(head).count(" · "), 2)

    def test_no_questions_no_block(self):
        lines = relay_cli.format_status({"item": {"status": "open", "projectId": "A", "title": "T"}, "events": []})
        self.assertEqual(lines, ['open · A · "T"'])

    def test_json_gains_answers_and_unanswered(self):
        data = relay_cli._status_json(detail(POSTED, answer(2, "1", ["Staging"]), answer(3, "3", text="EU")))
        plain = {"rev": 1, "stale": False, "verified": False}
        self.assertEqual(data["answers"], {"1": {"picked": ["Staging"], "at": "2026-10-11T09:02:00+00:00", **plain},
                                           "3": {"text": "EU", "at": "2026-10-11T09:03:00+00:00", **plain}})
        self.assertEqual(data["unanswered"], ["2", "4", "4.2"])
        self.assertEqual([e["kind"] for e in data["ownerEvents"]], ["answer", "answer"])


def revised(question_change):
    """An ask at version 2 (accepted), where step 1's question changed or only its code did."""
    import copy
    rev1 = copy.deepcopy(INSTRUCTABLE)
    for i, step in enumerate(rev1["steps"]):
        step["id"] = f"s{i + 1}"
        for j, sub in enumerate(step.get("substeps") or []):
            sub["id"] = f"s{i + 1}.{j + 1}"
    rev2 = copy.deepcopy(rev1)
    if question_change:
        rev2["steps"][0]["question"] = dict(rev2["steps"][0]["question"], choices=["Prod", "Canary"])
    else:
        rev2["steps"][0]["code"] = "echo changed"
    body1, body2 = json.dumps(rev1), json.dumps(rev2)
    item = dict(ITEM, payload={"instructable": rev2},
                revision={"rev": 2, "hash": "b" * 64, "prev": "a" * 64, "body": body2, "acceptedRev": 2})
    old = answer(2, "1", ["Staging"])
    old["rev"], old["auth"] = 1, "owner-key"
    return {"item": item, "revisions": [{"rev": 1, "hash": "a" * 64, "body": body1},
                                        {"rev": 2, "hash": "b" * 64, "body": body2}],
            "events": [POSTED, old, dict(event(3, "revised", "session", None), rev=2)]}


class RevisedStatusTest(unittest.TestCase):
    def test_json_on_a_revised_ask(self):
        data = relay_cli._status_json(revised(question_change=True), editable=True)
        self.assertEqual((data["rev"], data["hash"], data["acceptedRev"], data["editable"]), (2, "b" * 64, 2, True))
        self.assertEqual(data["instructable"]["steps"][0]["id"], "s1")
        self.assertEqual(data["answers"]["1"], {"picked": ["Staging"], "at": "2026-10-11T09:02:00+00:00", "rev": 1,
                                                "stale": True, "verified": True})
        self.assertIn("1", data["unanswered"])
        self.assertEqual(data["problems"], [])

    def test_a_code_change_keeps_the_answer(self):
        data = relay_cli._status_json(revised(question_change=False))
        self.assertFalse(data["answers"]["1"]["stale"])
        self.assertNotIn("1", data["unanswered"])
        self.assertFalse(data["editable"])

    def test_problems(self):
        d = revised(question_change=False)
        note = json.dumps({"id": "s3", "step": "3", "note": "no access"})
        d["events"].append(dict(event(4, "problem", "owner", note), rev=2, auth="owner-key"))
        self.assertEqual(relay_cli._status_json(d)["problems"],
                         [{"id": "s3", "step": "3", "note": "no access", "rev": 2, "at": "2026-10-11T09:04:00+00:00"}])
        lines = relay_cli.format_status(d)
        self.assertIn("version 2, accepted by the owner: version 2", lines)
        self.assertIn('2026-10-11T09:04:00+00:00 problem on step 3 (version 2), quoted: "no access"', lines)

    def test_text_marks_an_answer_to_an_earlier_question(self):
        lines = relay_cli.format_status(revised(question_change=True))
        self.assertIn('     "Staging" (version 1, an earlier question)', lines)

    def test_an_answer_follows_its_step_when_it_moves(self):
        d = revised(question_change=False)
        rev2 = d["item"]["payload"]["instructable"]
        rev2["steps"][0], rev2["steps"][1] = rev2["steps"][1], rev2["steps"][0]
        body = json.dumps(rev2)
        d["item"]["revision"]["body"] = body
        d["revisions"][1]["body"] = body
        data = relay_cli._status_json(d)
        self.assertEqual(data["answers"]["2"]["picked"], ["Staging"])
        self.assertNotIn("1", data["answers"])


def with_rev2(d, rev2, accepted):
    """The `revised` ask with rev 2's body replaced and the owner's accepted version set."""
    body = json.dumps(rev2)
    d["item"]["payload"]["instructable"] = rev2
    d["item"]["revision"].update(body=body, acceptedRev=accepted)
    d["revisions"][1]["body"] = body
    return d


def id_answer(seq, step, step_id, picked, rev):
    a = answer(seq, step, picked)
    body = json.loads(a["text"])
    body["id"] = step_id
    a.update(text=json.dumps(body), rev=rev, auth="owner-key")
    return a


DELETE_DB = {"prompt": "Delete the database?", "choices": ["Yes", "No"]}


class StepIdAnswersTest(unittest.TestCase):
    """Answers follow step ids, as the Pond counts them, never a path another step took over."""

    def replaced(self, accepted):
        d = revised(question_change=False)
        rev2 = d["item"]["payload"]["instructable"]
        rev2["steps"][0] = {"id": "r2-1", "do": "Drop the old database", "question": DELETE_DB}
        return with_rev2(d, rev2, accepted)

    def assert_replaced(self, d):
        data = relay_cli._status_json(d)
        self.assertNotIn("1", data["answers"])
        self.assertIn("1", data["unanswered"])
        self.assertEqual(data["earlier"], [{"id": "s1", "step": "1", "picked": ["Staging"],
                                            "at": "2026-10-11T09:02:00+00:00", "rev": 1, "verified": True}])
        lines = relay_cli.format_status(d)
        self.assertEqual(lines[lines.index("  1  \"Delete the database?\"") + 1], '  2  "Which signals?"')
        self.assertEqual(lines[-2:], ["Answers to steps this version no longer has (they don't count):",
                                      '  1 (version 1, step id s1)  "Staging"'])

    def test_a_replaced_step_not_yet_accepted(self):
        self.assert_replaced(self.replaced(accepted=1))

    def test_a_replaced_step_accepted(self):
        self.assert_replaced(self.replaced(accepted=2))

    def test_wait_counts_by_step_id(self):
        d = self.replaced(accepted=2)
        lines = rw.format_answer(d, ASK_ID, [])
        self.assertIn("answered 0 of 5; open: 1, 2, 3, 4, 4.2", lines)

    def inserted(self):
        """Rev 2 (accepted) puts a new question at path 1 and moves s1 to path 2."""
        d = revised(question_change=False)
        rev2 = d["item"]["payload"]["instructable"]
        rev2["steps"].insert(0, {"id": "r2-1", "do": "Drop the old database", "question": DELETE_DB})
        return with_rev2(d, rev2, accepted=2)

    def test_a_path_another_step_reuses(self):
        d = self.inserted()
        d["events"].append(id_answer(4, "1", "r2-1", ["No"], rev=2))
        data = relay_cli._status_json(d)
        self.assertEqual(data["answers"]["1"]["picked"], ["No"])
        self.assertEqual(data["answers"]["2"], {"picked": ["Staging"], "at": "2026-10-11T09:02:00+00:00",
                                                "rev": 1, "stale": False, "verified": True})
        self.assertNotIn("2", data["unanswered"])
        self.assertEqual(data["earlier"], [])

    def test_a_path_answer_without_an_id_maps_through_its_version(self):
        d = self.inserted()
        a = answer(4, "1", ["No"])
        a["rev"] = 2
        d["events"].append(a)
        data = relay_cli._status_json(d)
        self.assertEqual((data["answers"]["1"]["picked"], data["answers"]["2"]["picked"]), (["No"], ["Staging"]))

    def test_the_new_step_is_open_until_answered(self):
        data = relay_cli._status_json(self.inserted())
        self.assertEqual(list(data["answers"]), ["2"])
        self.assertIn("1", data["unanswered"])

    def test_an_old_pond_keeps_paths(self):
        data = relay_cli._status_json(detail(POSTED, answer(2, "1", ["Staging"])))
        self.assertEqual(data["answers"]["1"]["picked"], ["Staging"])
        self.assertEqual(data["earlier"], [])


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
        where = 'Acme · "Ship the Atlas release"'
        self.assertEqual(out, f'Hook: [{ASK_ID}] {where} — answer 3.2 (version 1): "Staging"\n'
                              f'Hook: [{ASK_ID}] {where} — answer 4 (version 1): "Use the EU region"\n'
                              f'Hook: [{ASK_ID}] {where} — answer: "garbled"\n')


if __name__ == "__main__":
    unittest.main()
