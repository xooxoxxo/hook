"""`relay wait`: owner-answer filtering, output, timeout, retries and the CLI wiring. Stdlib only."""
from __future__ import annotations

import io
import unittest

import relay_cli
import relay_wait as rw
from relay_client import ConfigMissing, NotFound, Refused, Unreachable

ITEM_ID = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"
ITEM = {"id": ITEM_ID, "projectId": "Acme", "title": "Check Node", "status": "open"}


def event(seq, kind, actor, text=None):
    return {"seq": seq, "itemId": ITEM_ID, "kind": kind, "actor": actor, "text": text,
            "at": f"2026-10-11T09:0{seq}:00+00:00"}


def detail(*events):
    return {"item": dict(ITEM), "events": list(events)}


class FakeAsk:
    """Client stand-in: each get() takes the next outcome (a detail dict or an exception); the last repeats."""

    def __init__(self, *outcomes, local=False):
        self.local = local
        self.outcomes = list(outcomes)
        self.gets = []

    def get(self, ask_id):
        self.gets.append(ask_id)
        outcome = self.outcomes.pop(0) if len(self.outcomes) > 1 else self.outcomes[0]
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class FakeClock:
    def __init__(self):
        self.now = 1000.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class WaitTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def wait(self, client, **kw):
        out, err = io.StringIO(), io.StringIO()
        code = rw.run(client, ITEM_ID, out=out, err=err, sleep=self.clock.sleep,
                      monotonic=self.clock.monotonic, **kw)
        return code, out.getvalue(), err.getvalue()

    def test_answer_already_there_returns_at_once(self):
        client = FakeAsk(detail(event(1, "posted", "session"), event(2, "reply", "owner", "use staging\nnot prod")))
        self.assertEqual(self.wait(client), (0, "[Acme] Check Node\n"
                                                "  ↳ owner reply 2026-10-11T09:02:00+00:00: use staging ⏎ not prod\n"
                                                "last seq: 2\n", ""))
        self.assertEqual((client.gets, self.clock.sleeps), ([ITEM_ID], []))

    def test_after_skips_earlier_answers(self):
        client = FakeAsk(detail(event(1, "posted", "session"), event(2, "reply", "owner", "first"),
                                event(3, "resolved", "owner", "ok")))
        self.assertEqual(self.wait(client, after=2), (0, "[Acme] Check Node\n"
                                                         "  ↳ owner resolved 2026-10-11T09:03:00+00:00: ok\n"
                                                         "last seq: 3\n", ""))
        self.assertEqual(self.wait(client, after=3, timeout=30)[0], 3)

    def test_only_owner_answers_count(self):
        session_only = detail(event(1, "posted", "session"), event(2, "resolved", "session", "fixed it myself"))
        answered = detail(event(1, "posted", "session"), event(2, "resolved", "session", "fixed it myself"),
                          event(3, "declined", "owner"))
        client = FakeAsk(session_only, session_only, answered)
        code, out, err = self.wait(client)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out, "[Acme] Check Node\n  ↳ owner declined 2026-10-11T09:03:00+00:00\nlast seq: 3\n")
        self.assertEqual(self.clock.sleeps, [20.0, 20.0])

    def test_reopen_wakes_the_waiter(self):
        closed = detail(event(1, "posted", "session"), event(2, "resolved", "owner"))
        reopened = detail(event(1, "posted", "session"), event(2, "resolved", "owner"), event(3, "reopened", "owner"))
        client = FakeAsk(closed, reopened)
        self.assertEqual(self.wait(client, after=2), (0, "[Acme] Check Node\n"
                                                         "  ↳ owner reopened 2026-10-11T09:03:00+00:00\n"
                                                         "last seq: 3\n", ""))
        self.assertEqual(self.clock.sleeps, [20.0])
        self.assertIn("reopened", rw.OWNER_KINDS)

    def test_missing_title_and_project_fall_back(self):
        client = FakeAsk({"item": {"id": ITEM_ID}, "events": [event(4, "resolved", "owner")]})
        self.assertEqual(self.wait(client)[1],
                         f"[] {ITEM_ID}\n  ↳ owner resolved 2026-10-11T09:04:00+00:00\nlast seq: 4\n")

    def test_timeout_exits_3_with_the_exact_line(self):
        client = FakeAsk(detail(event(1, "posted", "session")))
        self.assertEqual(self.wait(client, timeout=60),
                         (3, "", f"no owner answer on {ITEM_ID} within 60 s\n"))
        self.assertEqual((len(client.gets), self.clock.sleeps), (4, [20.0, 20.0, 20.0]))

    def test_unreachable_and_5xx_are_retried_then_the_answer_wins(self):
        client = FakeAsk(Unreachable("Hook isn't running"), Refused(502, "HTTP 502"),
                         detail(event(1, "posted", "session"), event(2, "reply", "owner", "go")), local=True)
        code, out, err = self.wait(client)
        self.assertEqual(code, 0)
        self.assertTrue(out.endswith("last seq: 2\n"))
        self.assertEqual(err, "relay wait: Hook isn't running; retrying every 2 s\n")
        self.assertEqual(self.clock.sleeps, [2.0, 2.0])

    def test_unreachable_until_the_deadline_times_out(self):
        client = FakeAsk(Unreachable("mailbox unreachable: http://mailbox.example: timed out"))
        code, out, err = self.wait(client, timeout=40)
        self.assertEqual((code, out), (3, ""))
        self.assertEqual(err.splitlines(), ["relay wait: mailbox unreachable: http://mailbox.example: timed out;"
                                            " retrying every 20 s",
                                            f"no owner answer on {ITEM_ID} within 40 s"])

    def test_not_found_and_4xx_end_the_wait(self):
        with self.assertRaises(NotFound):
            self.wait(FakeAsk(NotFound(f"no ask with id {ITEM_ID}")))
        with self.assertRaises(Refused):
            self.wait(FakeAsk(Refused(401, "unauthorized")))
        self.assertEqual(self.clock.sleeps, [])

    def test_default_interval_is_2_s_local_and_20_s_mailbox(self):
        quiet = detail(event(1, "posted", "session"))
        self.assertEqual(self.wait(FakeAsk(quiet, local=True), timeout=5)[0], 3)
        self.assertEqual(self.clock.sleeps, [2.0, 2.0, 2.0])
        self.clock.sleeps = []
        self.assertEqual(self.wait(FakeAsk(quiet), timeout=5)[0], 3)
        self.assertEqual(self.clock.sleeps, [20.0])

    def test_interval_has_a_1_s_floor(self):
        quiet = detail(event(1, "posted", "session"))
        self.wait(FakeAsk(quiet), timeout=2, interval=0.25)
        self.assertEqual(self.clock.sleeps, [1.0, 1.0])
        self.clock.sleeps = []
        self.wait(FakeAsk(quiet), timeout=10, interval=5)
        self.assertEqual(self.clock.sleeps, [5.0, 5.0])


class WaitCliTest(unittest.TestCase):
    def setUp(self):
        self.client = FakeAsk(detail(event(1, "posted", "session"), event(2, "reply", "owner", "first"),
                                     event(3, "resolved", "owner", "ok")))
        self.factory_kwargs = []

    def factory(self, **kw):
        self.factory_kwargs.append(kw)
        return self.client

    def run_cli(self, *argv, factory=None):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(list(argv), stdin=io.StringIO(""), stdout=out, stderr=err, env={},
                              client_factory=factory or self.factory)
        return code, out.getvalue(), err.getvalue()

    def test_wait_prints_the_answer_and_never_autolaunches(self):
        self.assertEqual(self.run_cli("wait", ITEM_ID, "--after", "2"),
                         (0, "[Acme] Check Node\n  ↳ owner resolved 2026-10-11T09:03:00+00:00: ok\nlast seq: 3\n", ""))
        self.assertEqual(self.factory_kwargs, [{"autolaunch": False, "timeout": relay_cli.DEFAULT_TIMEOUT}])

    def test_wait_timeout_zero_exits_3(self):
        self.assertEqual(self.run_cli("wait", ITEM_ID, "--after", "3", "--timeout", "0", "--interval", "1"),
                         (3, "", f"no owner answer on {ITEM_ID} within 0 s\n"))

    def test_wait_not_found_exits_1(self):
        self.client = FakeAsk(NotFound(f"no ask with id {ITEM_ID}"))
        self.assertEqual(self.run_cli("wait", ITEM_ID), (1, "", f"relay: no ask with id {ITEM_ID}\n"))

    def test_wait_without_config_exits_2(self):
        def no_config(**kw):
            raise ConfigMissing("No Hook config; run scripts/install.sh")
        self.assertEqual(self.run_cli("wait", ITEM_ID, factory=no_config),
                         (2, "", "relay: No Hook config; run scripts/install.sh\n"))

    def test_wait_bad_option_is_a_usage_error(self):
        code, out, err = self.run_cli("wait", ITEM_ID, "--timeout", "soon")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("--timeout", err)
        self.assertEqual(self.factory_kwargs, [])


if __name__ == "__main__":
    unittest.main()
