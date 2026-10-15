"""`relay replies`: cursors, epochs, peek vs --new, pruning, and the hook's failure modes. Stdlib only."""
from __future__ import annotations

import datetime
import io
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import relay_cli
import relay_replies as rr
from relay_client import NotFound, RelayError, Unreachable

A = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"
B = "5c2d9e41-8a7b-4c3d-9e0f-1a2b3c4d5e6f"
BIN = Path(__file__).resolve().parent.parent / "bin" / "relay"


class FakeQueue:
    """Client stand-in with an in-memory event log."""

    def __init__(self, env, source_key="local", epoch="e1"):
        self.env = env
        self.timeout = 10.0
        self._source_key = source_key
        self.epoch = epoch
        self.log = []
        self.items = {A: {"id": A, "projectId": "Acme", "title": "Check Node", "status": "open"}}
        self.gets = []
        self.error = None

    def source_key(self):
        return self._source_key

    def add(self, item_id, kind, actor, text=None):
        self.log.append({"seq": len(self.log) + 1, "itemId": item_id, "kind": kind, "actor": actor,
                         "text": text, "at": "2026-10-11T09:00:00+00:00"})

    def new_epoch(self, epoch):
        self.epoch = epoch
        self.log = []

    def events(self, after=0, limit=1000):
        if self.error is not None:
            raise self.error
        page = [e for e in self.log if e["seq"] > after][:limit]
        body = {"events": page, "next": page[-1]["seq"] if page else after}
        if self.epoch is not None:
            body["epoch"] = self.epoch
        return body

    def get(self, ask_id):
        self.gets.append(ask_id)
        if ask_id not in self.items:
            raise NotFound(f"no ask with id {ask_id}")
        return {"item": self.items[ask_id], "events": []}


class RepliesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "relay"
        self.env = {"RELAY_CONFIG": str(self.dir / "config.json")}
        self.queue = FakeQueue(self.env)

    def tearDown(self):
        self.tmp.cleanup()

    def replies(self, new=True, hook=False, session_id=None):
        out, err = io.StringIO(), io.StringIO()
        code = rr.run(self.queue, new=new, hook=hook, session_id=session_id, out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def test_first_run_is_silent_then_new_owner_event_prints_once(self):
        self.queue.add(A, "posted", "session")
        self.queue.add(A, "reply", "owner", "from before")
        self.assertEqual(self.replies(), (0, "", ""))
        self.queue.add(A, "resolved", "owner", "ok")
        self.assertEqual(self.replies(), (0, f"Relay: [{A}] Acme · Check Node — done: ok\n", ""))
        self.assertEqual(self.replies(), (0, "", ""))

    def test_reopen_prints_like_a_close(self):
        self.replies()
        self.queue.add(A, "resolved", "owner")
        self.queue.add(A, "reopened", "owner")
        self.assertEqual(self.replies()[1], f"Relay: [{A}] Acme · Check Node — done\n"
                                            f"Relay: [{A}] Acme · Check Node — reopened\n")
        self.assertEqual(self.replies(), (0, "", ""))

    def test_only_owner_events(self):
        self.replies()
        self.queue.add(A, "posted", "session")
        self.queue.add(A, "resolved", "session", "closed it myself")
        self.queue.add(A, "declined", "owner")
        self.assertEqual(self.replies()[1], f"Relay: [{A}] Acme · Check Node — skipped\n")

    def test_two_session_keys_each_see_it(self):
        self.replies(hook=True, session_id="s1")
        self.replies(hook=True, session_id="s2")
        self.queue.add(A, "reply", "owner", "yes")
        line = f"Relay: [{A}] Acme · Check Node — reply: yes\n"
        self.assertEqual(self.replies(hook=True, session_id="s1")[1], line)
        self.assertEqual(self.replies(hook=True, session_id="s2")[1], line)
        self.assertEqual(self.replies(hook=True, session_id="s1")[1], "")
        self.assertEqual(self.replies()[1], "")          # "cli" is a third key: its first run is silent

    def test_epoch_change_resets_the_source(self):
        for _ in range(3):
            self.queue.add(A, "posted", "session")
        self.replies()
        self.queue.new_epoch("e2")
        self.queue.add(A, "reply", "owner", "after the reset")   # seq 1, below the old cursor
        self.assertEqual(self.replies()[1], f"Relay: [{A}] Acme · Check Node — reply: after the reset\n")
        data = json.loads((self.dir / "replies-cursor.json").read_text())
        self.assertEqual(data["local"]["epoch"], "e2")
        self.assertEqual(data["local"]["head"], 1)

    def test_peek_does_not_advance(self):
        self.replies()
        self.queue.add(A, "reply", "owner", "hello")
        line = f"Relay: [{A}] Acme · Check Node — reply: hello\n"
        self.assertEqual(self.replies(new=False)[1], line)
        self.assertEqual(self.replies(new=False)[1], line)
        self.assertEqual(self.replies(new=True)[1], line)
        self.assertEqual(self.replies(new=True)[1], "")

    def test_newlines_removed_ask_and_one_title_fetch(self):
        self.replies()
        self.queue.add(A, "reply", "owner", "one")
        self.queue.add(A, "resolved", "owner", "two")
        self.queue.add(B, "reply", "owner", "a\nb")
        self.assertEqual(self.replies()[1],
                         f"Relay: [{A}] Acme · Check Node — reply: one\n"
                         f"Relay: [{A}] Acme · Check Node — done: two\n"
                         f"Relay: [{B}] (removed) — reply: a ⏎ b\n")
        self.assertEqual(self.queue.gets, [A, B])

    def test_mailbox_source_without_epoch(self):
        self.queue = FakeQueue(self.env, source_key="mailbox:0123456789ab", epoch=None)
        self.replies()
        self.queue.add(A, "resolved", "owner")
        self.assertEqual(self.replies()[1], f"Relay: [{A}] Acme · Check Node — done\n")
        data = json.loads((self.dir / "replies-cursor.json").read_text())
        self.assertEqual(set(data), {"mailbox:0123456789ab"})
        self.assertNotIn("epoch", data["mailbox:0123456789ab"])

    def test_many_pages(self):
        for _ in range(2500):
            self.queue.add(A, "posted", "session")
        self.replies()
        data = json.loads((self.dir / "replies-cursor.json").read_text())
        self.assertEqual(data["local"]["cursors"]["cli"]["after"], 2500)
        self.assertEqual(data["local"]["head"], 2500)

    def test_files_lock_and_modes(self):
        self.replies()
        cursor = self.dir / "replies-cursor.json"
        lock = self.dir / "replies-cursor.json.lock"
        self.assertTrue(lock.exists())
        self.assertEqual(stat.S_IMODE(cursor.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(lock.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.dir.stat().st_mode), 0o700)

    def test_lock_is_exclusive(self):
        path = self.dir / "replies-cursor.json"
        with rr.CursorStore(path):
            with self.assertRaises(RelayError) as ctx:
                with rr.CursorStore(path, lock_timeout=0.1):
                    pass
            self.assertIn("busy", str(ctx.exception))

    def test_prune_after_seven_days(self):
        path = self.dir / "replies-cursor.json"
        with rr.CursorStore(path, today=datetime.date(2026, 10, 1)) as store:
            store.set_cursor("local", "cli", 5)
            store.set_cursor("local", "session:old", 5)
            store.save()
        with rr.CursorStore(path, today=datetime.date(2026, 10, 7)) as store:
            store.set_cursor("local", "cli", 6)            # used again on day 6
            store.save()
        with rr.CursorStore(path, today=datetime.date(2026, 10, 8)) as store:
            store.prune()
            self.assertIsNone(store.cursor("local", "session:old"))   # 7 days unused
            self.assertEqual(store.cursor("local", "cli"), 6)         # 1 day unused

    def test_reset_epoch_zeroes_every_cursor(self):
        with rr.CursorStore(self.dir / "replies-cursor.json") as store:
            store.set_head("local", 9)
            store.set_cursor("local", "cli", 9)
            store.set_cursor("local", "session:s1", 7)
            store.reset_epoch("local", "e9")
            self.assertEqual((store.head("local"), store.epoch("local")), (0, "e9"))
            self.assertEqual((store.cursor("local", "cli"), store.cursor("local", "session:s1")), (0, 0))

    def test_cli_mode_reports_errors_with_exit_codes(self):
        self.queue.error = Unreachable("Relay isn't running")
        self.assertEqual(self.replies(), (2, "", "relay replies: Relay isn't running\n"))
        self.assertEqual(self.replies(hook=True, session_id="s1"), (0, "", "relay replies: Relay isn't running\n"))


class HookSessionTest(unittest.TestCase):
    def test_reads_only_the_session_id(self):
        stdin = io.TextIOWrapper(io.BytesIO(json.dumps({"session_id": "s1", "prompt": "hi"}).encode()))
        self.assertEqual(rr.read_hook_session(stdin), "s1")

    def test_rejects_bad_input(self):
        for raw in (b"", b"not json", b"[1]", b'{"prompt":"x"}', b'{"session_id":7}',
                    b'{"session_id":"' + b"x" * (1024 * 1024) + b'"}'):
            self.assertIsNone(rr.read_hook_session(io.BytesIO(raw)), raw[:20])

    def test_tty_is_never_read(self):
        master, slave = os.openpty()
        try:
            with open(slave, "rb", buffering=0, closefd=False) as tty:
                self.assertIsNone(rr.read_hook_session(tty))
        finally:
            os.close(master)
            os.close(slave)


class HookBudgetTest(unittest.TestCase):
    """The 2 s hook budget is a total: a slow /health leaves only the rest for /events."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "relay"
        self.dir.mkdir()
        (self.dir / "local-token").write_text("ab" * 32 + "\n")
        self.env = {"RELAY_CONFIG": str(self.dir / "config.json")}
        self.now = 100.0
        self.timeouts = []

    def tearDown(self):
        self.tmp.cleanup()

    def clock(self):
        return self.now

    def urlopen(self, req, timeout=None):
        import hashlib
        import hmac
        import urllib.error
        import urllib.parse
        from test_relay_client import FakeResponse
        self.timeouts.append(timeout)
        path = urllib.parse.urlsplit(req.full_url).path
        if path == "/health":
            self.now += 1.9                     # slow, but answers within its timeout
            nonce = req.get_header("X-relay-nonce")
            proof = hmac.new(("ab" * 32).encode(), ("relay-proof-v1\n47911\n" + nonce).encode(),
                             hashlib.sha256).hexdigest()
            body = {"ok": True, "app": "relay", "source": "local", "proof": proof}
            return FakeResponse(200, json.dumps(body).encode())
        self.now += timeout                      # hangs until its timeout
        raise urllib.error.URLError(socket.timeout("timed out"))

    def test_hook_returns_within_the_budget(self):
        import relay_client as rc
        client = rc.Client({"source": "local", "port": 47911}, env=self.env, autolaunch=False,
                           timeout=rr.HOOK_BUDGET_S, urlopen=self.urlopen, monotonic=self.clock)
        out, err = io.StringIO(), io.StringIO()
        start = self.now
        code = rr.run(client, new=True, hook=True, session_id="s1", out=out, err=err,
                      budget_s=rr.HOOK_BUDGET_S, monotonic=self.clock)
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), "")
        self.assertLessEqual(self.now - start, rr.HOOK_BUDGET_S + 1e-9)
        self.assertEqual(len(self.timeouts), 2)
        self.assertAlmostEqual(self.timeouts[1], 0.1)   # only what was left after /health

    def test_no_exchange_starts_after_the_deadline(self):
        import relay_client as rc
        client = rc.Client({"source": "local", "port": 47911}, env=self.env, autolaunch=False,
                           urlopen=self.urlopen, monotonic=self.clock)
        client.deadline = self.now - 0.01
        with self.assertRaises(Unreachable):
            client.health()
        self.assertEqual(self.timeouts, [])


class HookFailureTest(unittest.TestCase):
    """Review Focus 2: `relay replies --new --hook` exits 0 within 2.5 s with nothing on stdout."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "relay"
        self.dir.mkdir()
        self.cfg = self.dir / "config.json"
        self.env = {"RELAY_CONFIG": str(self.cfg)}
        self.socks = []

    def tearDown(self):
        for sock in self.socks:
            sock.close()
        self.tmp.cleanup()

    def closed_port(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        return port

    def silent_port(self):
        """Accepts connections (backlog) and never answers."""
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sock.listen(8)
        self.socks.append(sock)
        return sock.getsockname()[1]

    def hook(self, stdin, factory=None):
        out, err = io.StringIO(), io.StringIO()
        start = time.monotonic()
        code = relay_cli.main(["replies", "--new", "--hook"], stdin=stdin, stdout=out, stderr=err,
                              env=self.env, client_factory=factory)
        elapsed = time.monotonic() - start
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), "")
        self.assertLess(elapsed, 2.5)
        self.assertEqual(err.getvalue().count("\n"), 1, err.getvalue())
        return err.getvalue()

    def session_stdin(self):
        return io.BytesIO(b'{"session_id":"s1","prompt":"do the thing"}')

    def test_relay_quit(self):
        self.cfg.write_text(json.dumps({"source": "local", "port": self.closed_port()}))
        self.assertIn("Relay isn't running", self.hook(self.session_stdin()))

    def test_relay_hangs(self):
        self.cfg.write_text(json.dumps({"source": "local", "port": self.silent_port()}))
        self.hook(self.session_stdin())

    def test_mailbox_down(self):
        (self.dir / "mailbox-token").write_text("mailbox-example\n")
        self.cfg.write_text(json.dumps({"mailboxURL": f"http://127.0.0.1:{self.closed_port()}",
                                        "tokenFile": str(self.dir / "mailbox-token")}))
        self.assertIn("mailbox unreachable", self.hook(self.session_stdin()))

    def test_no_config(self):
        self.hook(self.session_stdin())

    def test_tty_empty_and_non_json_stdin(self):
        self.cfg.write_text(json.dumps({"source": "local", "port": self.closed_port()}))
        master, slave = os.openpty()
        try:
            with open(slave, "rb", buffering=0, closefd=False) as tty:
                self.hook(tty)
        finally:
            os.close(master)
            os.close(slave)
        self.hook(io.BytesIO(b""))
        self.hook(io.BytesIO(b"not json"))

    def test_hook_never_autolaunches(self):
        seen = []

        def factory(**kw):
            seen.append(kw)
            raise Unreachable("Relay isn't running")
        self.hook(self.session_stdin(), factory)
        self.assertEqual(seen, [{"autolaunch": False, "timeout": 2.0}])

    def test_bad_arguments_still_exit_0(self):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(["replies", "--hook", "--bogus"], stdin=io.BytesIO(b""), stdout=out, stderr=err)
        self.assertEqual((code, out.getvalue()), (0, ""))

    def test_bin_relay_as_a_hook(self):
        self.cfg.write_text(json.dumps({"source": "local", "port": self.closed_port()}))
        start = time.monotonic()
        done = subprocess.run([sys.executable, str(BIN), "replies", "--new", "--hook"], input=b"not json",
                              capture_output=True, timeout=10, env=dict(os.environ, RELAY_CONFIG=str(self.cfg)))
        self.assertLess(time.monotonic() - start, 2.5)
        self.assertEqual((done.returncode, done.stdout), (0, b""))


if __name__ == "__main__":
    unittest.main()
