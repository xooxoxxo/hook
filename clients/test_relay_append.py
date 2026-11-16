"""relay_client.append, the appendSteps gate and appends_of. Stdlib only."""
from __future__ import annotations

import json

import relay_client as rc
from test_relay_amend import ASK, H1, H2, H3, Pond, detail
from test_relay_client import ITEM_ID, Base, FakeClock, FakeHTTP

FEATURES = ["answers", "corrections", "requirements", "appendSteps"]
STEPS = [{"do": "Open the deploy page", "url": "https://pond.example.test/deploy"},
         {"do": "Press Deploy"}]
NOTE = "the deploy steps, after your answer"
APPEND = f"/asks/{ITEM_ID}/append"


class AppendPond(Pond):
    """A Pond 1.9.0 that lists appendSteps and takes appends."""

    def __init__(self, version="1.9.0", features=FEATURES):
        super().__init__(version)
        info = {"service": "pond", "version": version, "protocol": 5}
        if features is not None:
            info["features"] = list(features)
        self.routes[("GET", "/version")] = (200, info)
        self.routes[("POST", APPEND)] = (200, {
            "item": {"id": ITEM_ID},
            "revision": {"rev": 2, "hash": H2, "kind": "append",
                         "added": [{"id": "r2-1", "path": "2"}, {"id": "r2-2", "path": "3"}]},
            "openUrl": f"https://pond.example.test/{ITEM_ID}"})
        self.queue = []     # answers for the append route, used before `routes`

    def __call__(self, req, timeout=None):
        if req.get_method() == "POST" and req.full_url.endswith(APPEND) and self.queue:
            self.requests.append(req)
            status, body = self.queue.pop(0)
            return self._answer(req, status, body)
        return super().__call__(req, timeout)


class AppendTests(Base):
    def setUp(self):
        super().setUp()
        self.http = AppendPond()
        self.keys = rc.EditKeys(self.env)
        self.clock = FakeClock()
        self.client().post("Acme", ASK)

    def client(self, env=None):
        cfg = {"mailboxURL": "https://pond.example.test/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=env or self.env, urlopen=self.http, sleep=self.clock.sleep,
                         monotonic=self.clock.monotonic)

    def append(self, steps=STEPS, **kw):
        return self.client(kw.pop("env", None)).append(ITEM_ID, NOTE, steps, **kw)

    def sent(self):
        return [json.loads(r.data) for r in self.http.sent(APPEND)]

    def test_append_happy(self):
        res = self.append()
        self.assertEqual(res, {"id": ITEM_ID, "rev": 2, "hash": H2,
                               "added": [{"id": "r2-1", "path": "2"}, {"id": "r2-2", "path": "3"}],
                               "openUrl": f"https://pond.example.test/{ITEM_ID}"})
        record = self.keys.load(ITEM_ID)
        self.assertEqual(self.sent(), [{"editKey": record["key"], "baseRev": 1, "baseHash": H1, "note": NOTE,
                                        "steps": STEPS}])
        self.assertEqual((record["lastRev"], record["lastHash"], record["hashes"]), (2, H2, [H1, H2]))

    def test_append_from_another_session_warns(self):
        res = self.append(env=dict(self.env, CLAUDE_SESSION_ID="other-session"))
        self.assertEqual(res["rev"], 2)
        self.assertIn("another session", res["warning"])

    def test_append_local_refused(self):
        with self.assertRaises(rc.LocalCantAppend) as ctx:
            self.local(FakeHTTP()).append(ITEM_ID, NOTE, STEPS)
        self.assertEqual(str(ctx.exception), "This Mac's queue can't add steps. Post a follow-up ask.")
        self.assertEqual(ctx.exception.exit_code, 1)

    def test_append_needs_feature(self):
        # Pond 1.8.0 lists features without appendSteps; an older Pond has no features key.
        for version, features in (("1.8.0", ["answers", "corrections"]), ("1.7.0", None)):
            with self.subTest(version):
                rc._ponds.clear()
                self.http = AppendPond(version, features)
                with self.assertRaises(rc.PondLacksFeature) as ctx:
                    self.append()
                self.assertEqual(ctx.exception.error, f"Your Pond ({version}) can't add steps to an ask yet. "
                                                      "Update the Pond, or post a follow-up ask.")
                self.assertEqual((ctx.exception.key, ctx.exception.feature), ("append", "appendSteps"))
                self.assertIsInstance(ctx.exception, rc.PondTooOld)
                self.assertEqual(self.http.sent(APPEND), [])

    def test_the_gate_is_the_name_never_the_version(self):
        rc._ponds.clear()
        self.http = AppendPond("1.8.5", FEATURES)       # a Pond that lists it under another number
        self.assertEqual(self.append()["rev"], 2)

    def test_pond_features(self):
        self.assertEqual(self.client().pond_features(), set(FEATURES))
        rc._ponds.clear()
        self.http = AppendPond("1.7.0", None)
        self.assertIsNone(self.client().pond_features())
        client = self.client()
        client.pond_features()
        client.pond_info()
        self.assertEqual([r.full_url for r in self.http.requests].count("https://pond.example.test/version"), 1)

    def test_append_lints_steps(self):
        steps = [{"do": "Open https://app.example.com/settings"}]
        with self.assertRaises(rc.Refused) as ctx:
            self.append(steps)
        self.assertEqual((ctx.exception.status, ctx.exception.error, ctx.exception.details),
                         (400, "invalid steps", ['steps[0].do: "https://app.example.com/settings" is a value '
                                                 'to copy: put it in code (or a URL in url)']))
        self.assertEqual(self.http.sent(APPEND), [])
        self.assertEqual(self.http.sent(f"/asks/{ITEM_ID}"), [])

    def test_append_checks_the_steps_keys_against_the_pond(self):
        rc._ponds.clear()
        steps = [{"do": "Pick one", "question": {"prompt": "Which?", "choices": [{"label": "Mix", "text": "What?"}]}}]
        self.http.routes[("GET", "/version")] = (200, {"version": "1.3.0", "protocol": 5, "features": FEATURES})
        with self.assertRaises(rc.PondTooOld) as ctx:
            self.append(steps)
        self.assertEqual(ctx.exception.key, rc.CHOICE_KEY)
        self.assertEqual(self.http.sent(APPEND), [])

    def test_no_edit_key(self):
        (self.keys_dir / f"{ITEM_ID}.json").unlink()
        with self.assertRaises(rc.NoEditKey):
            self.append()
        self.assertEqual(self.http.sent(APPEND), [])

    def test_a_key_never_goes_to_another_pond(self):
        other = {"mailboxURL": "https://other.example.test/", "tokenFile": str(self.dir / "mailbox-token")}
        with self.assertRaises(rc.NoEditKey):
            rc.Client(other, env=self.env, urlopen=self.http).append(ITEM_ID, NOTE, STEPS)
        self.assertEqual(self.http.sent(APPEND), [])

    def test_the_base_is_the_current_revision(self):
        self.http.routes[("GET", f"/asks/{ITEM_ID}")] = (200, detail(rev=3, hash_=H3, accepted=1))
        self.append()
        self.assertEqual([(s["baseRev"], s["baseHash"]) for s in self.sent()], [(3, H3)])

    def test_append_retries_stale_once(self):
        self.http.queue = [(409, {"error": "stale revision", "rev": 3, "hash": H3})]
        self.assertEqual(self.append()["rev"], 2)
        self.assertEqual([(s["baseRev"], s["baseHash"]) for s in self.sent()], [(1, H1), (3, H3)])

    def test_a_second_stale_is_refused(self):
        stale = (409, {"error": "stale revision", "rev": 3, "hash": H3})
        self.http.queue = [stale, stale]
        with self.assertRaises(rc.Refused) as ctx:
            self.append()
        self.assertEqual(ctx.exception.error, "stale revision")
        self.assertEqual(len(self.sent()), 2)

    def test_append_retries_too_soon_once(self):
        self.http.queue = [(429, {"error": "too soon", "retryAfter": 12})]
        self.assertEqual(self.append()["rev"], 2)
        self.assertEqual(self.clock.sleeps, [12])
        self.assertEqual(len(self.sent()), 2)

    def test_too_soon_past_15_seconds_is_refused_without_a_wait(self):
        self.http.queue = [(429, {"error": "too soon", "retryAfter": 40})]
        with self.assertRaises(rc.Refused) as ctx:
            self.append()
        self.assertEqual((ctx.exception.status, ctx.exception.error), (429, "too soon"))
        self.assertEqual((self.clock.sleeps, len(self.sent())), ([], 1))

    def test_append_closed_says_follow_up(self):
        self.http.queue = [(409, {"error": "ask is closed"})]
        with self.assertRaises(rc.AskClosedForAppend) as ctx:
            self.append()
        self.assertEqual(str(ctx.exception), "The owner already closed this ask. Post a follow-up ask.")
        self.assertEqual(ctx.exception.exit_code, 1)

    def test_append_switch_off(self):
        self.http.queue = [(409, {"error": "appends not enabled"})]
        with self.assertRaises(rc.AppendsOff) as ctx:
            self.append()
        self.assertEqual(str(ctx.exception), "The Pond has adding steps switched off. Post a follow-up ask.")

    def test_append_limit(self):
        self.http.queue = [(409, {"error": "append limit reached"})]
        with self.assertRaises(rc.Refused) as ctx:
            self.append()
        self.assertEqual((ctx.exception.status, ctx.exception.error),
                         (409, "This ask has had 10 additions. Post a follow-up ask."))

    def test_other_refusals_pass_through(self):
        self.http.queue = [(400, {"error": "invalid steps", "details": ["steps[0].id: used before"]})]
        with self.assertRaises(rc.Refused) as ctx:
            self.append()
        self.assertEqual((ctx.exception.error, ctx.exception.details), ("invalid steps", ["steps[0].id: used before"]))
        self.http.queue = [(403, {"error": "wrong edit key"})]
        with self.assertRaises(rc.Refused) as ctx:
            self.append()
        self.assertEqual((ctx.exception.status, ctx.exception.error), (403, "wrong edit key"))

    def test_then_needs_feature(self):
        ask = {"v": 1, "title": "Pick a region", "steps": [
            {"do": "Pick a region", "question": {"prompt": "Which region?", "choices": ["eu", "us"],
                                                 "then": "steps"}}]}
        for version, features in (("1.8.0", ["answers"]), ("1.7.0", None)):
            with self.subTest(version):
                rc._ponds.clear()
                self.http = AppendPond(version, features)
                with self.assertRaises(rc.PondLacksFeature) as ctx:
                    self.client().post("Acme", ask)
                self.assertEqual((ctx.exception.key, ctx.exception.feature), ("question.then", "appendSteps"))
                self.assertEqual(ctx.exception.error, f"Your Pond ({version}) can't take `question.then` yet. "
                                                      "Update the Pond, or leave the key out.")
                self.assertEqual(self.http.sent("/asks"), [])
        rc._ponds.clear()
        self.http = AppendPond()
        self.assertEqual(self.client().post("Acme", ask)["item"]["id"], ITEM_ID)
        sub = {"v": 1, "title": "Sub", "steps": [{"do": "Two parts", "substeps": [
            {"do": "Pick", "question": {"prompt": "Which?", "then": "steps"}}]}]}
        rc._ponds.clear()
        self.http = AppendPond("1.8.0", ["answers"])
        with self.assertRaises(rc.PondLacksFeature):
            self.client().post("Acme", sub)

    def test_appends_of(self):
        body1 = {"v": 1, "title": "T", "steps": [{"do": "a", "id": "s1"}]}
        body2 = dict(body1, steps=body1["steps"] + [{"do": "b", "id": "r2-1", "substeps": [{"do": "c", "id": "r2-2"}]}])
        body3 = dict(body2, steps=[{"do": "A", "id": "s1"}] + body2["steps"][1:])
        body4 = dict(body3, steps=body3["steps"] + [{"do": "d", "id": "r4-1"}])
        served = {"item": {"id": ITEM_ID, "status": "open", "payload": {"instructable": body4},
                           "revision": {"rev": 4, "hash": "d" * 64, "kind": "append", "acceptedRev": 4}},
                  "revisions": [
                      {"rev": 1, "hash": H1, "at": "2026-11-15T10:00:00Z", "reason": "", "body": json.dumps(body1)},
                      {"rev": 2, "hash": H2, "at": "2026-11-15T10:05:00Z", "reason": "after the region",
                       "body": json.dumps(body2), "kind": "append"},
                      {"rev": 3, "hash": H3, "at": "2026-11-15T10:07:00Z", "reason": "typo",
                       "body": json.dumps(body3)},
                      {"rev": 4, "hash": "d" * 64, "at": "2026-11-15T10:09:00Z", "reason": "one more",
                       "body": json.dumps(body4), "kind": "append"}]}
        self.assertEqual(rc.appends_of(served), [
            {"rev": 2, "at": "2026-11-15T10:05:00Z", "note": "after the region", "added": ["r2-1", "r2-2"]},
            {"rev": 4, "at": "2026-11-15T10:09:00Z", "note": "one more", "added": ["r4-1"]}])
        self.assertEqual(rc.appends_of(detail()), [])
        self.assertEqual(rc.appends_of({}), [])


if __name__ == "__main__":
    import unittest
    unittest.main()
