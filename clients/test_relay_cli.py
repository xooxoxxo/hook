"""The `relay` command through a fake client: stdout, stderr and exit codes. Stdlib only."""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import relay_cli
import relay_client
from relay_client import ConfigMissing, NotFound, Refused, Unreachable

ITEM_ID = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"
OPEN_URL = "http://127.0.0.1:47823/i/" + ITEM_ID
BIN = Path(__file__).resolve().parent.parent / "bin" / "relay"
ITEM = {"id": ITEM_ID, "projectId": "Acme", "title": "Check Node", "status": "open",
        "payload": {"instructable": {"v": 1, "title": "Check Node", "urgency": "now"}}}


def event(seq, kind, actor, text=None):
    return {"seq": seq, "itemId": ITEM_ID, "kind": kind, "actor": actor, "text": text,
            "at": f"2026-10-11T09:0{seq}:00+00:00"}


class FakeClient:
    def __init__(self):
        self.calls = []
        self.error = None
        self.post_result = {"item": {"id": ITEM_ID}, "openUrl": OPEN_URL}
        self.detail = {"item": dict(ITEM), "events": [event(1, "posted", "session")]}
        self.items = [ITEM]

    def _record(self, *call):
        self.calls.append(call)
        if self.error is not None:
            raise self.error

    def post(self, project, instructable):
        self._record("post", project, instructable)
        return self.post_result

    def get(self, ask_id):
        self._record("get", ask_id)
        return self.detail

    def list(self, status="open", days=36500):
        self._record("list", status, days)
        return self.items

    def resolve(self, ask_id, verdict, note=None):
        self._record("resolve", ask_id, verdict, note)
        return {"item": dict(ITEM, status="done" if verdict == "done" else "dismissed")}


class CliTest(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        self.factory_kwargs = []

    def factory(self, **kw):
        self.factory_kwargs.append(kw)
        return self.client

    def run_cli(self, *argv, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(list(argv), stdin=stdin if stdin is not None else io.StringIO(""),
                              stdout=out, stderr=err, env={}, client_factory=self.factory)
        return code, out.getvalue(), err.getvalue()

    def test_version(self):
        self.assertEqual(self.run_cli("--version"), (0, "relay " + relay_client.VERSION + "\n", ""))

    def test_no_command_is_a_usage_error(self):
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertIn("usage: relay", err)

    def test_post_from_stdin_with_bom(self):
        raw = "\ufeff" + json.dumps({"v": 1, "title": "Check Node"})
        stdin = io.TextIOWrapper(io.BytesIO(raw.encode("utf-8")), encoding="utf-8")
        self.assertEqual(self.run_cli("post", "Acme", "--json", "-", stdin=stdin),
                         (0, f"posted {ITEM_ID}\nopen {OPEN_URL}\n", ""))
        self.assertEqual(self.client.calls, [("post", "Acme", {"v": 1, "title": "Check Node"})])

    def test_post_from_file_with_bom(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ask.json"
            path.write_bytes(b"\xef\xbb\xbf" + json.dumps({"v": 1, "title": "Check Node"}).encode())
            code, out, _ = self.run_cli("post", "Acme", "--json", str(path))
        self.assertEqual((code, out), (0, f"posted {ITEM_ID}\nopen {OPEN_URL}\n"))

    def test_post_deduped_without_open_url(self):
        self.client.post_result = {"item": {"id": ITEM_ID}, "deduped": True}
        self.assertEqual(self.run_cli("post", "Acme", "--json", "-", stdin=io.StringIO('{"v":1}')),
                         (0, f"deduped {ITEM_ID}\n", ""))

    def test_post_refused(self):
        self.client.error = Refused(400, "invalid instructable", ["steps: required", "title: too long"])
        self.assertEqual(self.run_cli("post", "Acme", "--json", "-", stdin=io.StringIO('{"v":1}')),
                         (1, "", "refused: invalid instructable\n  steps: required\n  title: too long\n"))

    def test_post_help_explains_substeps(self):
        # argparse wraps help at the terminal width and breaks after the hyphen in "sub-steps"
        # at some widths; pin the width so the joined text compares the same everywhere.
        with mock.patch.dict(os.environ, {"COLUMNS": "80"}):
            code, out, err = self.run_cli("post", "--help")
        self.assertEqual((code, err), (0, ""))
        self.assertIn(" ".join(relay_cli.SUBSTEPS_SENTENCE.split()), " ".join(out.split()))

    def test_post_help_explains_questions(self):
        with mock.patch.dict(os.environ, {"COLUMNS": "80"}):
            code, out, err = self.run_cli("post", "--help")
        self.assertEqual((code, err), (0, ""))
        self.assertIn(" ".join(relay_cli.QUESTIONS_SENTENCE.split()), " ".join(out.split()))

    def test_post_bad_input(self):
        code, out, err = self.run_cli("post", "Acme", "--json", "-", stdin=io.StringIO("{nope"))
        self.assertEqual((code, out), (1, ""))
        self.assertIn("relay: --json input isn't valid JSON", err)
        code, _, err = self.run_cli("post", "Acme", "--json", "-", stdin=io.StringIO("[1]"))
        self.assertEqual((code, err), (1, "relay: --json input must be a JSON object\n"))
        self.assertEqual(self.client.calls, [])

    def test_post_unreachable_and_no_config(self):
        self.client.error = Unreachable("Relay isn't running")
        self.assertEqual(self.run_cli("post", "Acme", "--json", "-", stdin=io.StringIO("{}")),
                         (2, "", "relay: Relay isn't running\n"))

        def no_config(**kw):
            raise ConfigMissing("No Relay config; run scripts/install.sh")
        err = io.StringIO()
        code = relay_cli.main(["list"], stdout=io.StringIO(), stderr=err, client_factory=no_config)
        self.assertEqual((code, err.getvalue()), (2, "relay: No Relay config; run scripts/install.sh\n"))

    def test_status_open(self):
        self.assertEqual(self.run_cli("status", ITEM_ID), (0, "open · Acme · Check Node\n", ""))

    def test_status_done_by_session(self):
        self.client.detail = {"item": dict(ITEM, status="done"),
                              "events": [event(1, "posted", "session"), event(2, "resolved", "session", "fixed")]}
        self.assertEqual(self.run_cli("status", ITEM_ID), (0, "done (by session) · Acme · Check Node\n", ""))

    def test_status_with_owner_events(self):
        self.client.detail = {"item": dict(ITEM, status="dismissed"), "events": [
            event(1, "posted", "session"), event(2, "reply", "owner", "line one\nline two"),
            event(3, "declined", "owner")]}
        self.assertEqual(self.run_cli("status", ITEM_ID)[1],
                         "dismissed (by owner) · Acme · Check Node\n"
                         "2026-10-11T09:02:00+00:00 reply: line one ⏎ line two\n"
                         "2026-10-11T09:03:00+00:00 skipped\n")

    def test_status_json(self):
        self.client.detail = {"item": dict(ITEM, status="done"),
                              "events": [event(1, "posted", "session"), event(2, "resolved", "owner", "ok")]}
        code, out, _ = self.run_cli("status", ITEM_ID, "--json")
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual((data["status"], data["resolvedBy"]), ("done", "owner"))
        self.assertEqual(data["ownerEvents"], [{"kind": "resolved", "text": "ok", "at": "2026-10-11T09:02:00+00:00"}])

    def test_status_lists_a_reopen(self):
        self.client.detail = {"item": dict(ITEM, status="open"), "events": [
            event(1, "posted", "session"), event(2, "resolved", "owner"), event(3, "reopened", "owner")]}
        self.assertEqual(self.run_cli("status", ITEM_ID)[1],
                         "open · Acme · Check Node\n"
                         "2026-10-11T09:02:00+00:00 done\n"
                         "2026-10-11T09:03:00+00:00 reopened\n")
        data = json.loads(self.run_cli("status", ITEM_ID, "--json")[1])
        self.assertIsNone(data["resolvedBy"])
        self.assertEqual([e["kind"] for e in data["ownerEvents"]], ["resolved", "reopened"])

    def test_status_not_found(self):
        self.client.error = NotFound(f"no ask with id {ITEM_ID}")
        self.assertEqual(self.run_cli("status", ITEM_ID), (1, "", f"relay: no ask with id {ITEM_ID}\n"))

    def test_list(self):
        legacy = {"id": "1d0e", "projectId": "Acme", "title": "Old ask", "status": "open",
                  "payload": {"why": "w", "cmd": "ls"}}
        self.client.items = [ITEM, legacy]
        self.assertEqual(self.run_cli("list"),
                         (0, f"{ITEM_ID} now Acme · Check Node\n1d0e today Acme · Old ask\n", ""))
        self.assertEqual(self.client.calls, [("list", "open", 36500)])
        self.assertEqual(json.loads(self.run_cli("list", "--json")[1])[0]["id"], ITEM_ID)

    def test_done_and_skip(self):
        self.assertEqual(self.run_cli("done", ITEM_ID, "it works"), (0, f"done {ITEM_ID}\n", ""))
        self.assertEqual(self.client.calls[-1], ("resolve", ITEM_ID, "done", "it works"))
        self.assertEqual(self.run_cli("skip", ITEM_ID), (0, f"skipped {ITEM_ID}\n", ""))
        self.assertEqual(self.client.calls[-1], ("resolve", ITEM_ID, "declined", None))

    def test_already_dismissed_by_owner(self):
        self.client.detail = {"item": dict(ITEM, status="dismissed"),
                              "events": [event(1, "posted", "session"), event(2, "declined", "owner")]}
        self.assertEqual(self.run_cli("done", ITEM_ID),
                         (0, f"already dismissed (by owner) {ITEM_ID}\n", ""))
        self.assertNotIn("resolve", [c[0] for c in self.client.calls])

    def test_done_not_found(self):
        self.client.error = NotFound("no ask with id nope")
        self.assertEqual(self.run_cli("done", "nope"), (1, "", "relay: no ask with id nope\n"))

    def test_resolved_by(self):
        self.assertIsNone(relay_cli.resolved_by([]))
        self.assertIsNone(relay_cli.resolved_by([event(1, "posted", "session")]))
        self.assertEqual(relay_cli.resolved_by([event(1, "resolved", "session"), event(2, "reply", "owner"),
                                                event(3, "declined", "owner")]), "owner")

    def test_resolved_by_after_a_reopen(self):
        self.assertIsNone(relay_cli.resolved_by([event(1, "resolved", "owner"), event(2, "reopened", "owner")]))
        self.assertEqual(relay_cli.resolved_by([event(1, "declined", "owner"), event(2, "reopened", "owner"),
                                                event(3, "resolved", "session")]), "session")

    def test_format_status_with_missing_fields(self):
        self.assertEqual(relay_cli.format_status({}), ["? · ? · ?"])


class NoAutolaunchTest(unittest.TestCase):
    """RELAY_NO_AUTOLAUNCH=1 (test-only) keeps the default factory from opening Relay."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        cfg = Path(self.tmp.name) / "config.json"
        import socket
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()                                  # nothing listens: connection refused
        cfg.write_text(json.dumps({"source": "local", "port": port}))
        (Path(self.tmp.name) / "local-token").write_text("ab" * 32 + "\n")
        self.env = {"RELAY_CONFIG": str(cfg)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_list(self, env):
        launches = []
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("relay_client._launch", lambda argv: launches.append(argv) or False):
            code = relay_cli.main(["list"], stdout=out, stderr=err, env=env)
        return code, launches, err.getvalue()

    def test_switch_disables_autolaunch(self):
        code, launches, err = self.run_list(dict(self.env, RELAY_NO_AUTOLAUNCH="1"))
        self.assertEqual(code, 2)
        self.assertEqual(launches, [])
        self.assertIn("Relay isn't running", err)

    def test_without_the_switch_it_tries_to_launch(self):
        code, launches, _ = self.run_list(self.env)
        self.assertEqual(code, 2)
        self.assertEqual(len(launches), 1)


class ShimTest(unittest.TestCase):
    def test_bin_relay_through_a_symlink(self):
        self.assertTrue(os.access(BIN, os.X_OK))
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "relay"
            link.symlink_to(BIN)
            done = subprocess.run([sys.executable, str(link), "--version"], capture_output=True, text=True,
                                  timeout=10)
        self.assertEqual((done.returncode, done.stdout), (0, "relay " + relay_client.VERSION + "\n"))


if __name__ == "__main__":
    unittest.main()
