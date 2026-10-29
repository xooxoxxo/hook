"""Edit keys, relay_client.amend, the X-Hook-Protocol header and session-facing text. Stdlib only."""
from __future__ import annotations

import hashlib
import io
import json
import os
import stat
import urllib.error
import urllib.parse
from pathlib import Path

import relay_cli
import relay_client as rc
from test_relay_client import ITEM_ID, MAILBOX_TOKEN, Base, FakeHTTP

H1, H2, H3 = "a" * 64, "b" * 64, "c" * 64
ASK = {"v": 1, "title": "Check Node", "steps": [{"do": "Run it"}]}
FIXED = {"v": 1, "title": "Check Node", "steps": [{"do": "Run it", "id": "s1", "code": "node -v"}]}


def detail(rev=1, hash_=H1, accepted=1, status="open"):
    return {"item": {"id": ITEM_ID, "projectId": "Acme", "title": "Check Node", "status": status,
                     "payload": {"instructable": FIXED},
                     "revision": {"rev": rev, "hash": hash_, "acceptedRev": accepted}},
            "events": []}


class Pond(FakeHTTP):
    """A Pond at `version` that stores the posted editKeyHash and dedupes by title."""

    def __init__(self, version="1.1.0", protocol=5):
        super().__init__()
        self.routes[("GET", "/version")] = (200, {"service": "pond", "version": version, "protocol": protocol})
        self.routes[("GET", f"/asks/{ITEM_ID}")] = (200, detail())
        self.routes[("POST", f"/asks/{ITEM_ID}/amend")] = (
            200, {"item": {"id": ITEM_ID}, "revision": {"rev": 2, "hash": H2, "changed": [
                {"id": "s1", "path": "1", "fields": ["code"]}], "added": [], "removed": [], "moved": [], "top": []}})
        self.stored_hash = None
        self.fail_next_post = False

    def __call__(self, req, timeout=None):
        parts = urllib.parse.urlsplit(req.full_url)
        if req.get_method() == "POST" and parts.path == "/asks":
            self.requests.append(req)
            body = json.loads(req.data)
            sent = body.get("editKeyHash")
            if self.stored_hash is None:
                self.stored_hash = sent
                status, res = 201, {"item": {"id": ITEM_ID}, "revision": {"rev": 1, "hash": H1},
                                    "editable": sent is not None}
            else:
                status, res = 200, {"item": {"id": ITEM_ID}, "deduped": True, "revision": {"rev": 1, "hash": H1},
                                    "editable": sent is not None and sent == self.stored_hash}
            if self.fail_next_post:
                self.fail_next_post = False
                raise urllib.error.URLError("timed out")
            return self._answer(req, status, res)
        return super().__call__(req, timeout)


class EditKeyTests(Base):
    def setUp(self):
        super().setUp()
        self.http = Pond()
        self.keys = rc.EditKeys(self.env)

    def client(self, **kw):
        return self.mailbox(self.http, **kw)

    def key_file(self):
        return self.keys_dir / f"{ITEM_ID}.json"

    def test_a_post_on_1_1_0_sends_only_the_hash_and_keeps_the_key(self):
        res = self.client().post("Acme", ASK)
        self.assertTrue(res["editable"])
        record = json.loads(self.key_file().read_text())
        self.assertEqual(len(record["key"]), 43)
        sent = json.loads(self.http.sent("/asks")[0].data)
        self.assertEqual(sent["editKeyHash"], hashlib.sha256(record["key"].encode()).hexdigest())
        self.assertNotIn(record["key"], self.http.sent("/asks")[0].data.decode())
        self.assertEqual({k: record[k] for k in ("session", "lastRev", "lastHash", "hashes")},
                         {"session": "test-session", "lastRev": 1, "lastHash": H1, "hashes": [H1]})
        self.assertEqual(record["source"], self.client().source_key())
        self.assertEqual([p.name for p in self.keys_dir.iterdir()], [f"{ITEM_ID}.json"])   # no pending left

    def test_modes_are_0600_and_0700(self):
        self.client().post("Acme", ASK)
        self.assertEqual(stat.S_IMODE(os.stat(self.keys_dir).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.key_file()).st_mode), 0o600)

    def test_a_group_writable_folder_is_refused(self):
        self.client().post("Acme", ASK)
        os.chmod(self.keys_dir, 0o770)
        with self.assertRaises(rc.ConfigMissing) as ctx:
            self.keys.load(ITEM_ID)
        self.assertIn("writable by other users", str(ctx.exception))

    def test_an_older_pond_gets_no_key(self):
        for version, protocol in (("1.0.0", 4), ("2026.10.27.1", 4)):
            rc._ponds.clear()
            self.http = Pond(version, protocol)
            self.client().post("Acme", ASK)
            self.assertNotIn("editKeyHash", json.loads(self.http.sent("/asks")[0].data))
        self.assertFalse(self.keys_dir.exists())

    def test_a_retry_after_a_timeout_reuses_the_pending_key(self):
        self.http.fail_next_post = True
        with self.assertRaises(rc.Unreachable):
            self.client().post("Acme", ASK)
        self.assertFalse(self.key_file().exists())
        res = self.client().post("Acme", ASK)
        self.assertEqual((res["deduped"], res["editable"]), (True, True))
        first, second = (json.loads(r.data)["editKeyHash"] for r in self.http.sent("/asks"))
        self.assertEqual(first, second)
        self.assertTrue(self.key_file().exists())

    def test_a_dedupe_with_another_key_drops_the_pending_key(self):
        self.http.stored_hash = "f" * 64                 # posted by someone else
        res = self.client().post("Acme", ASK)
        self.assertFalse(res["editable"])
        self.assertFalse(self.key_file().exists())
        self.assertEqual(list(self.keys_dir.iterdir()), [])

    def test_owners_and_record_write(self):
        self.client().post("Acme", ASK)
        self.assertEqual(self.keys.owners(), {ITEM_ID: "test-session"})
        self.keys.record_write(ITEM_ID, 2, H2)
        record = self.keys.load(ITEM_ID)
        self.assertEqual((record["lastRev"], record["lastHash"], record["hashes"]), (2, H2, [H1, H2]))

    def test_prune_drops_old_files(self):
        self.client().post("Acme", ASK)
        old = self.key_file().stat().st_mtime - 31 * 86400
        os.utime(self.key_file(), (old, old))
        self.keys.prune()
        self.assertFalse(self.key_file().exists())

    def test_a_bad_ask_id_is_never_a_path(self):
        self.assertIsNone(self.keys.load("../config"))
        self.assertIsNone(self.keys.load(""))

    def test_the_key_never_reaches_argv_stdout_or_stderr(self):
        out, err = io.StringIO(), io.StringIO()
        argv = ["post", "Acme", "--json", "-"]
        code = relay_cli.main(argv, stdin=io.StringIO(json.dumps(ASK)), stdout=out, stderr=err, env=self.env,
                              client_factory=lambda **kw: self.client())
        self.assertEqual(code, 0)
        key = json.loads(self.key_file().read_text())["key"]
        for text in (" ".join(argv), out.getvalue(), err.getvalue()):
            self.assertNotIn(key, text)


class AmendTests(Base):
    def setUp(self):
        super().setUp()
        self.http = Pond()
        self.keys = rc.EditKeys(self.env)
        self.client().post("Acme", ASK)

    def client(self, env=None):
        cfg = {"mailboxURL": "https://mailbox.example/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=env or self.env, urlopen=self.http)

    def amend(self, **kw):
        return self.client(kw.pop("env", None)).amend(ITEM_ID, "node -v was missing", FIXED, **kw)

    def test_amend_sends_the_key_and_the_base_and_records_the_write(self):
        res = self.amend()
        self.assertEqual(res["revision"]["rev"], 2)
        self.assertNotIn("warning", res)
        sent = json.loads(self.http.sent(f"/asks/{ITEM_ID}/amend")[0].data)
        record = self.keys.load(ITEM_ID)
        self.assertEqual(sent, {"editKey": record["key"], "baseRev": 1, "baseHash": H1,
                                "reason": "node -v was missing", "instructable": FIXED})
        self.assertEqual((record["lastRev"], record["lastHash"], record["hashes"]), (2, H2, [H1, H2]))

    def test_older_ponds_are_refused_naming_amend(self):
        for version, protocol, shown in (("1.0.0", 4, "1.0.0"), ("2026.10.27.1", 4, "protocol 4")):
            rc._ponds.clear()
            self.http.routes[("GET", "/version")] = (200, {"version": version, "protocol": protocol})
            with self.assertRaises(rc.PondTooOld) as ctx:
                self.amend()
            self.assertEqual(ctx.exception.key, "amend")
            self.assertEqual(ctx.exception.error,
                             f"Your Pond ({shown}) is older than `amend` needs (Pond 1.1.0 or newer). "
                             "Update the Pond, or close this ask and post a new one.")
        self.assertEqual(self.http.sent(f"/asks/{ITEM_ID}/amend"), [])

    def test_a_minor_pond_bump_never_blocks_amend(self):
        for version in ("1.1.0", "1.3.2"):
            rc._ponds.clear()
            self.http.routes[("GET", "/version")] = (200, {"version": version, "protocol": 5})
            self.assertEqual(self.amend()["revision"]["rev"], 2)
            self.keys.record_write(ITEM_ID, 1, H1)   # back to what the fake Pond serves

    def test_local_mode_cant_amend(self):
        client = self.local(FakeHTTP())
        with self.assertRaises(rc.LocalCantAmend) as ctx:
            client.amend(ITEM_ID, "why", FIXED)
        self.assertEqual(str(ctx.exception), "This Mac mode can't correct asks yet: close this one "
                                             f"(relay done {ITEM_ID}) and post a new one.")

    def test_no_key_file(self):
        os.unlink(self.keys_dir / f"{ITEM_ID}.json")
        with self.assertRaises(rc.NoEditKey) as ctx:
            self.amend()
        self.assertEqual(str(ctx.exception), f"No edit key for ask {ITEM_ID} on this Mac: only the process that "
                                             f"posted it can correct it. Close it (relay done {ITEM_ID}) and post "
                                             "a new one.")

    def test_corrections_not_enabled(self):
        self.http.routes[("POST", f"/asks/{ITEM_ID}/amend")] = (409, {"error": "corrections not enabled"})
        with self.assertRaises(rc.CorrectionsOff) as ctx:
            self.amend()
        self.assertEqual(str(ctx.exception), "The Pond doesn't take corrections yet. Close this ask "
                                             f"(relay done {ITEM_ID}) and post a new one.")
        self.assertEqual(ctx.exception.exit_code, 1)

    def test_other_refusals_pass_through(self):
        self.http.routes[("POST", f"/asks/{ITEM_ID}/amend")] = (
            400, {"error": "invalid amendment", "details": ["title: cannot change"]})
        with self.assertRaises(rc.Refused) as ctx:
            self.amend()
        self.assertEqual((ctx.exception.error, ctx.exception.details), ("invalid amendment", ["title: cannot change"]))

    def test_changed_underneath(self):
        self.http.routes[("GET", f"/asks/{ITEM_ID}")] = (200, detail(rev=3, hash_=H3))
        with self.assertRaises(rc.ChangedUnderneath) as ctx:
            self.amend()
        self.assertEqual(str(ctx.exception), f"Ask {ITEM_ID} changed since you last wrote it (version 3). "
                                             f"Run `relay status {ITEM_ID} --json` and correct from that.")
        self.assertEqual(self.http.sent(f"/asks/{ITEM_ID}/amend"), [])

    def test_an_explicit_base_skips_the_check(self):
        served = detail(rev=3, hash_=H3)
        served["revisions"] = [{"rev": 1, "hash": H1}, {"rev": 2, "hash": H2}, {"rev": 3, "hash": H3}]
        self.http.routes[("GET", f"/asks/{ITEM_ID}")] = (200, served)
        self.amend(base_rev=2)
        sent = json.loads(self.http.sent(f"/asks/{ITEM_ID}/amend")[0].data)
        self.assertEqual((sent["baseRev"], sent["baseHash"]), (2, H2))

    def test_another_session_gets_a_warning_not_a_refusal(self):
        res = self.amend(env=dict(self.env, CLAUDE_SESSION_ID="other-session"))
        self.assertEqual(res["revision"]["rev"], 2)
        self.assertIn("another session", res["warning"])


class HeaderTests(Base):
    def test_every_request_carries_x_hook_protocol_5(self):
        http = Pond()
        client = self.mailbox(http)
        client.post("Acme", ASK)
        client.get(ITEM_ID)
        client.amend(ITEM_ID, "why", FIXED)
        local = FakeHTTP()
        local.routes[("GET", "/asks?status=open&days=36500")] = (200, {"items": []})
        self.local(local).list()
        requests = http.requests + local.requests
        self.assertGreaterEqual(len(requests), 6)
        for req in requests:
            self.assertEqual(req.get_header("X-hook-protocol"), "5", req.full_url)
        self.assertEqual(http.requests[0].get_header("Authorization"), "Bearer " + MAILBOX_TOKEN)


class SessionTextTests(Base):
    def test_quoted_one_line_with_hidden_characters_shown(self):
        self.assertEqual(rc.session_text('a\n"b"‮', 40), '"a ⏎ \\"b\\"⟨U+202E⟩"')

    def test_cut_includes_the_ellipsis(self):
        self.assertEqual(rc.session_text("x" * 50, 10), '"xxxxxxxxx…"')
        self.assertEqual(rc.session_text("x" * 10, 10), '"xxxxxxxxxx"')

    def test_a_revealed_scalar_is_never_split(self):
        self.assertEqual(rc.session_text("abcd‮efgh", 8), '"abcd…"')

    def test_controls_tabs_and_separators(self):
        self.assertEqual(rc.session_text("a\tb\x1bc d‍e", 80),
                         '"a⟨U+0009⟩b⟨U+001B⟩c⟨U+2028⟩d⟨U+200D⟩e"')

    def test_none_and_numbers(self):
        self.assertEqual(rc.session_text(None, 10), '""')
        self.assertEqual(rc.session_text(42, 10), '"42"')

    def test_label(self):
        self.assertEqual(rc.session_label("[Liner]\n x", 60), "(Liner) ⏎  x")
        self.assertEqual(rc.session_label("Acme" * 20, 10), "AcmeAcmeA…")


if __name__ == "__main__":
    import unittest
    unittest.main()
