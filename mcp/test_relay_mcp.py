"""Scripted stdio sessions against relay_mcp.py with a stub mailbox and a stub local Relay.
Stdlib only; runs on Python 3.9."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import relay_mcp

SERVER_CMD = [sys.executable, str(Path(__file__).resolve().with_name("relay_mcp.py"))]
ITEM_ID = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"
OPEN_URL = "http://127.0.0.1:47823/i/" + ITEM_ID
LOCAL_TOKEN = "ab" * 32
POSTED = []      # request bodies of POST /asks
SEEN = []        # (method, path, X-Relay-Client) of every request

# Words that must never appear in a tool description.
FORBIDDEN = ["telegram", "14 days"]

DONE_DETAIL = {
    "item": {"id": ITEM_ID, "title": "Check Node", "status": "done",
             "completedAt": "2026-10-11T09:00:00+00:00"},
    "events": [
        {"seq": 1, "itemId": ITEM_ID, "kind": "posted", "actor": "session", "text": None,
         "at": "2026-10-11T08:00:00+00:00"},
        {"seq": 2, "itemId": ITEM_ID, "kind": "resolved", "actor": "owner", "text": None,
         "at": "2026-10-11T09:00:00+00:00"},
    ],
}
LISTED = {"id": ITEM_ID, "projectId": "Acme", "title": "Check Node", "status": "open",
          "created": "2025-01-02T03:04:05+00:00", "lane": "work"}


class StubQueue(BaseHTTPRequestHandler):
    """The mailbox routes relay_client uses. The local stub adds /health with a proof."""
    token = "stub-token"

    def log_message(self, *args):
        pass

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self):
        SEEN.append((self.command, self.path, self.headers.get("X-Relay-Client")))

    def _authorized(self):
        if self.headers.get("Authorization") == "Bearer " + self.token:
            return True
        self._send(401, {"error": "unauthorized"})
        return False

    def do_POST(self):
        self._record()
        if not self._authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        POSTED.append(body)
        if body["instructable"].get("title") == "bad":
            return self._send(400, {"error": "invalid instructable", "details": ["steps: required"]})
        self._send(201, {"item": {"id": ITEM_ID, "title": body["instructable"]["title"],
                                  "status": "open"}, "openUrl": OPEN_URL})

    def do_GET(self):
        self._record()
        if self.path.startswith("/health"):
            return self.health()
        if not self._authorized():
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/asks":
            query = dict(urllib.parse.parse_qsl(parsed.query))
            if query != {"status": "open", "days": "36500"}:
                return self._send(400, {"error": "invalid query"})
            return self._send(200, {"items": [LISTED]})
        if parsed.path != "/asks/" + ITEM_ID:
            return self._send(404, {"error": "not found"})
        self._send(200, DONE_DETAIL)

    def health(self):
        self._send(200, {"ok": True})


class StubLocalRelay(StubQueue):
    token = LOCAL_TOKEN

    def health(self):
        body = {"ok": True, "app": "relay", "source": "local"}
        nonce = self.headers.get("X-Relay-Nonce")
        if nonce:
            port = self.server.server_address[1]
            message = "relay-proof-v1\n" + str(port) + "\n" + nonce
            body["proof"] = hmac.new(LOCAL_TOKEN.encode(), message.encode(), hashlib.sha256).hexdigest()
        self._send(200, body)


class Session:
    """relay_mcp.py as a subprocess, with config.json (and its token files) in tmp."""

    def __init__(self, tmp, config, write_config=True):
        cfg = Path(tmp) / "config.json"
        if write_config:
            cfg.write_text(json.dumps(config))
        self.config_path = cfg
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR")}
        env.update(RELAY_CONFIG=str(cfg), CLAUDE_SESSION_ID="test-session")
        self.proc = subprocess.Popen(SERVER_CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     env=env, text=True)
        self.last_id = 0

    @classmethod
    def mailbox(cls, tmp, url):
        token = Path(tmp) / "token"
        token.write_text("stub-token\n")
        return cls(tmp, {"mailboxURL": url, "tokenFile": str(token), "context": "work",
                         "port": 47823, "pollSeconds": 15})

    def _write(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def notify(self, method):
        self._write({"jsonrpc": "2.0", "method": method})

    def request(self, method, params=None):
        self.last_id += 1
        self._write({"jsonrpc": "2.0", "id": self.last_id, "method": method, "params": params or {}})
        reply = json.loads(self.proc.stdout.readline())
        assert reply["id"] == self.last_id, reply   # a notification must never have been answered
        return reply

    def call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})["result"]

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()


class StubServerCase(unittest.TestCase):
    """Starts `handler` on a free port; tmp holds config.json and the token files."""
    handler = StubQueue

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self.handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        POSTED.clear()
        SEEN.clear()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()


class RelayMcpTest(StubServerCase):
    def test_post_then_status(self):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            init = s.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "test", "version": "0"}})
            self.assertEqual(init["result"]["protocolVersion"], "2025-06-18")
            self.assertEqual(init["result"]["serverInfo"], {"name": "relay", "version": relay_mcp.relay_client.VERSION})
            s.notify("notifications/initialized")
            tools = {t["name"]: t for t in s.request("tools/list")["result"]["tools"]}
            self.assertEqual(set(tools), {"relay_post", "relay_status", "relay_list"})
            self.assertIn("instructable", tools["relay_post"]["inputSchema"]["properties"])
            self.assertIn("step", tools["relay_post"]["inputSchema"]["$defs"])   # "#/$defs/step" resolves

            post = s.call("relay_post", {"project": "Acme", "instructable": {
                "v": 1, "title": "Check Node", "steps": [{"do": "Run it", "code": "node --version"}]}})
            self.assertFalse(post["isError"])
            self.assertEqual(post["structuredContent"], {"id": ITEM_ID, "openUrl": OPEN_URL, "deduped": False})
            self.assertEqual(POSTED[-1]["project"], "Acme")
            self.assertEqual(POSTED[-1]["context"], "work")
            self.assertEqual(POSTED[-1]["instructable"]["from"]["session"], "test-session")

            bad = s.call("relay_post", {"project": "Acme", "instructable": {"v": 1, "title": "bad"}})
            self.assertTrue(bad["isError"])
            self.assertIn("invalid instructable", bad["content"][0]["text"])
            self.assertIn("steps: required", bad["content"][0]["text"])

            status = s.call("relay_status", {"id": ITEM_ID})["structuredContent"]
            self.assertEqual(status["status"], "done")
            self.assertEqual(status["resolvedBy"], "owner")
            self.assertEqual(status["ownerEvents"],
                             [{"kind": "resolved", "text": None, "at": "2026-10-11T09:00:00+00:00"}])
            self.assertEqual(status["resolvedAt"], "2026-10-11T09:00:00+00:00")

            missing = s.call("relay_status", {"id": "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61"})
            self.assertTrue(missing["isError"])
            self.assertIn("no ask with id", missing["content"][0]["text"])

            self.assertTrue(SEEN)
            self.assertEqual({client for _, _, client in SEEN}, {"mcp/" + relay_mcp.relay_client.VERSION})
        finally:
            s.close()

    def test_list_returns_every_open_ask(self):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            listed = s.call("relay_list", {})
            self.assertFalse(listed["isError"], listed)
            self.assertEqual(listed["structuredContent"], {"items": [
                {"id": ITEM_ID, "project": "Acme", "title": "Check Node", "status": "open",
                 "created": "2025-01-02T03:04:05+00:00"}]})
        finally:
            s.close()

    def test_discover_and_unknown_method(self):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            meta = {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}
            disc = s.request("server/discover", meta)["result"]
            self.assertEqual(disc["resultType"], "complete")
            self.assertEqual(disc["supportedVersions"], ["2026-07-28", "2025-11-25"])
            listed = s.request("tools/list", meta)["result"]
            self.assertEqual(listed["resultType"], "complete")
            # 2026-07-28 clients reject a list result without caching hints.
            self.assertIsInstance(listed["ttlMs"], int)
            self.assertIn(listed["cacheScope"], ("public", "private"))
            self.assertEqual(s.request("nope")["error"]["code"], -32601)
            self.assertEqual(s.request("tools/call", {"name": "nope"})["error"]["code"], -32602)
        finally:
            s.close()

    def test_unreachable_mailbox_keeps_serving(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        closed_port = probe.getsockname()[1]
        probe.close()
        s = Session.mailbox(self.tmp.name, f"http://127.0.0.1:{closed_port}")
        try:
            res = s.call("relay_post", {"project": "Acme", "instructable": {
                "v": 1, "title": "Check Node", "steps": [{"do": "Run it"}]}})
            self.assertTrue(res["isError"])
            self.assertIn("mailbox unreachable", res["content"][0]["text"])
            self.assertNotIn("stub-token", res["content"][0]["text"])
            self.assertEqual(s.request("ping")["result"], {})
        finally:
            s.close()

    def test_missing_config_is_a_tool_error(self):
        s = Session(self.tmp.name, {}, write_config=False)
        try:
            res = s.call("relay_list", {})
            self.assertTrue(res["isError"])
            self.assertIn(str(s.config_path), res["content"][0]["text"])
            self.assertEqual(s.request("ping")["result"], {})
        finally:
            s.close()


class LocalModeTest(StubServerCase):
    """The same server against a stub local Relay: proof first, then the token."""
    handler = StubLocalRelay

    def test_post_in_local_mode(self):
        (Path(self.tmp.name) / "local-token").write_text(LOCAL_TOKEN + "\n")
        s = Session(self.tmp.name, {"source": "local", "port": self.httpd.server_port})
        try:
            post = s.call("relay_post", {"project": "Acme", "instructable": {
                "v": 1, "title": "Check Node", "steps": [{"do": "Run it"}]}})
            self.assertFalse(post["isError"], post)
            self.assertEqual(post["structuredContent"]["id"], ITEM_ID)
            self.assertNotIn("context", POSTED[-1])
            paths = [path for _, path, _ in SEEN]
            self.assertEqual(paths, ["/health", "/asks"])   # the proof comes before the token
        finally:
            s.close()


class DescriptionTest(unittest.TestCase):
    def test_descriptions_are_machine_neutral(self):
        tools = relay_mcp.tool_list()
        text = json.dumps(tools).lower()
        for word in FORBIDDEN:
            self.assertNotIn(word, text)
        project = tools[0]["inputSchema"]["properties"]["project"]
        self.assertEqual(project["description"],
                         "Short project name: what the repo's CLAUDE.md names, else the repo folder name.")
        for tool in tools:
            self.assertIn("Relay queue", tool["description"])


class FakeClient:
    source = {"kind": "local", "port": 47823}

    def __init__(self, detail):
        self.detail = detail

    def get(self, ask_id):
        return self.detail


def event(seq, kind, actor, text=None):
    return {"seq": seq, "itemId": ITEM_ID, "kind": kind, "actor": actor, "text": text,
            "at": "2026-10-11T09:00:0%d+00:00" % seq}


class ResolvedByTest(unittest.TestCase):
    def status(self, item_status, events):
        detail = {"item": {"id": ITEM_ID, "title": "Check Node", "status": item_status,
                           "completedAt": None}, "events": events}
        with mock.patch.object(relay_mcp, "make_client", lambda: FakeClient(detail)):
            return relay_mcp.relay_status({"id": ITEM_ID})

    def test_closed_by_session(self):
        result = self.status("done", [event(1, "posted", "session"), event(2, "resolved", "session")])
        self.assertEqual(result["resolvedBy"], "session")
        self.assertEqual(result["ownerEvents"], [])

    def test_declined_by_owner_with_reply(self):
        result = self.status("dismissed", [event(1, "posted", "session"), event(2, "reply", "owner", "later"),
                                           event(3, "declined", "owner")])
        self.assertEqual(result["resolvedBy"], "owner")
        self.assertEqual([e["kind"] for e in result["ownerEvents"]], ["reply", "declined"])

    def test_reopened_ask_is_open_with_no_resolver(self):
        result = self.status("open", [event(1, "posted", "session"), event(2, "declined", "owner"),
                                      event(3, "reopened", "owner")])
        self.assertIsNone(result["resolvedBy"])
        self.assertEqual([e["kind"] for e in result["ownerEvents"]], ["declined", "reopened"])
        # Even if the item status lags behind, a reopen after the close clears resolvedBy.
        stale = self.status("dismissed", [event(1, "posted", "session"), event(2, "declined", "owner"),
                                          event(3, "reopened", "owner")])
        self.assertIsNone(stale["resolvedBy"])

    def test_status_description_mentions_reopen(self):
        tool = next(t for t in relay_mcp.tool_list() if t["name"] == "relay_status")
        self.assertIn("reopened", tool["description"])
        self.assertIn("open again", tool["description"])

    def test_last_resolving_event_wins(self):
        result = self.status("done", [event(1, "posted", "session"), event(2, "declined", "owner"),
                                      event(3, "resolved", "session")])
        self.assertEqual(result["resolvedBy"], "session")

    def test_non_dict_events_are_skipped(self):
        result = self.status("done", ["junk", 7, None, event(1, "posted", "session"),
                                      event(2, "resolved", "owner")])
        self.assertEqual(result["resolvedBy"], "owner")
        self.assertEqual([e["kind"] for e in result["ownerEvents"]], ["resolved"])

    def test_non_dict_item_and_events(self):
        with mock.patch.object(relay_mcp, "make_client",
                               lambda: FakeClient({"item": "x", "events": "y"})):
            result = relay_mcp.relay_status({"id": ITEM_ID})
        self.assertIsNone(result["status"])
        self.assertEqual(result["ownerEvents"], [])

    def test_open_ask_has_no_resolver(self):
        result = self.status("open", [event(1, "posted", "session"), event(2, "reply", "owner", "ok")])
        self.assertIsNone(result["resolvedBy"])
        self.assertEqual(result["ownerEvents"], [{"kind": "reply", "text": "ok", "at": "2026-10-11T09:00:02+00:00"}])


if __name__ == "__main__":
    unittest.main()
