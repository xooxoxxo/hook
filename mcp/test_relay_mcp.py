"""Scripted stdio sessions against relay_mcp.py with a stub mailbox and a stub local Hook.
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
        env.update(RELAY_CONFIG=str(cfg), CLAUDE_SESSION_ID="test-session",
                   RELAY_EDIT_KEY_DIR=str(Path(tmp) / "edit-keys"))
        self.keys_dir = Path(tmp) / "edit-keys"
        self.proc = subprocess.Popen(SERVER_CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, text=True)
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
            self.assertEqual(set(tools), {"relay_post", "relay_status", "relay_list", "relay_amend"})
            self.assertIn("instructable", tools["relay_post"]["inputSchema"]["properties"])
            self.assertIn("step", tools["relay_post"]["inputSchema"]["$defs"])   # "#/$defs/step" resolves
            detail = tools["relay_post"]["inputSchema"]["$defs"]["step"]["properties"]["detail"]
            self.assertEqual((detail["type"], detail["maxLength"]), ("string", 1500))
            self.assertIn("never in code", detail["description"])

            post = s.call("relay_post", {"project": "Acme", "instructable": {
                "v": 1, "title": "Check Node", "steps": [{"do": "Run it", "code": "node --version"}]}})
            self.assertFalse(post["isError"])
            self.assertEqual(post["structuredContent"], {"id": ITEM_ID, "openUrl": OPEN_URL, "deduped": False,
                                                         "editable": False})
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
            self.assertIn("Pond unreachable", res["content"][0]["text"])
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
    """The same server against a stub local Hook: proof first, then the token."""
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


class StubVersioned(StubQueue):
    """A Pond that answers GET /version with VERSION (None: no such route, 404)."""
    version = None

    def do_GET(self):
        if self.path == "/version" and self.version is not None:
            self._record()
            if self._authorized():
                self._send(200, self.version)
            return
        super().do_GET()


class OldPond3(StubVersioned):
    version = {"service": "mailbox", "version": "2026.10.20.1", "protocol": 3}


class OldPond4(StubVersioned):
    version = {"service": "mailbox", "version": "2026.10.27.1", "protocol": 4}


class Pond100(StubVersioned):
    version = {"service": "pond", "version": "1.0.0", "protocol": 4}


TOO_OLD = ("Your Pond ({m}) is older than `{key}` needs (Pond {n} or newer). "
           "Update the Pond, or leave the key out.")
BLOCKING = {"v": 1, "title": "Gate", "steps": [{"do": "Run it", "blocking": True, "warning": "Later steps fail"}]}
ASKING = {"v": 1, "title": "Pick", "steps": [{"do": "Choose", "substeps": [
    {"do": "Env", "question": {"prompt": "Which?", "choices": ["a", "b"]}}]}]}
PLAIN = {"v": 1, "title": "Plain", "steps": [{"do": "Run it"}]}
OPTIONAL = {"v": 1, "title": "Feedback", "steps": [{"do": "Tell us", "optional": True, "question": {"prompt": "Any?"}}]}
WITH_IDS = {"v": 1, "title": "Ids", "steps": [{"do": "Run it", "id": "run"}]}


class PondGateTest(StubServerCase):
    def post(self, instructable):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            return s.call("relay_post", {"project": "Acme", "instructable": instructable})
        finally:
            s.close()

    def test_blocking_is_refused_by_an_old_level_3_pond_without_posting(self):
        self.httpd.RequestHandlerClass = OldPond3
        res = self.post(BLOCKING)
        self.assertTrue(res["isError"])
        self.assertEqual(res["structuredContent"]["error"], TOO_OLD.format(m="protocol 3", key="blocking", n="1.0.0"))
        self.assertEqual(POSTED, [])

    def test_a_pond_without_version_is_protocol_1(self):
        res = self.post(ASKING)
        self.assertTrue(res["isError"])
        self.assertEqual(res["structuredContent"]["error"], TOO_OLD.format(m="protocol 1", key="question", n="1.0.0"))
        self.assertEqual(POSTED, [])
        self.assertIn("/version", [path for _, path, _ in SEEN])

    def test_an_old_level_4_pond_and_pond_1_0_0_take_every_older_key(self):
        for handler in (OldPond4, Pond100):
            self.httpd.RequestHandlerClass = handler
            for ask in (BLOCKING, ASKING, OPTIONAL):
                res = self.post(ask)
                self.assertFalse(res["isError"], res)
        self.assertEqual(len(POSTED), 6)
        self.assertTrue(all("editKeyHash" not in body for body in POSTED))

    def test_step_ids_need_pond_1_1_0(self):
        self.httpd.RequestHandlerClass = Pond100
        res = self.post(WITH_IDS)
        self.assertEqual(res["structuredContent"]["error"], TOO_OLD.format(m="1.0.0", key="id", n="1.1.0"))
        self.assertEqual(POSTED, [])

    def test_a_plain_instructable_still_posts_on_a_pond_without_version(self):
        res = self.post(PLAIN)
        self.assertFalse(res["isError"], res)
        self.assertEqual(len(POSTED), 1)


H1, H2 = "a" * 64, "b" * 64


class StubPond(StubVersioned):
    """A Pond at 1.1.0: keeps the posted editKeyHash, serves a revision, takes amend with the key."""
    version = {"service": "pond", "version": "1.1.0", "protocol": 5}
    key_hash = None

    def do_POST(self):
        self._record()
        if not self._authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        POSTED.append(body)
        if self.path == "/asks":
            StubPond.key_hash = body.get("editKeyHash")
            return self._send(201, {"item": {"id": ITEM_ID}, "openUrl": OPEN_URL,
                                    "revision": {"rev": 1, "hash": H1}, "editable": True})
        if self.path == f"/asks/{ITEM_ID}/amend":
            if hashlib.sha256(body["editKey"].encode()).hexdigest() != StubPond.key_hash:
                return self._send(403, {"error": "wrong edit key"})
            return self._send(200, {"item": {"id": ITEM_ID}, "revision": {
                "rev": 2, "hash": H2, "changed": [{"id": "s1", "path": "1", "fields": ["code"]}],
                "added": [], "removed": [], "moved": [], "top": []}})
        self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == f"/asks/{ITEM_ID}":
            self._record()
            if self._authorized():
                self._send(200, {"item": {"id": ITEM_ID, "title": "Fix", "status": "open",
                                          "revision": {"rev": 1, "hash": H1, "acceptedRev": 1}},
                                 "events": []})
            return
        super().do_GET()


FIX = {"v": 1, "title": "Fix", "steps": [{"do": "Run it", "id": "s1"}]}


class AmendToolTest(StubServerCase):
    handler = StubPond

    def test_tools_list_has_relay_amend_with_its_schema(self):
        tool = next(t for t in relay_mcp.tool_list() if t["name"] == "relay_amend")
        schema = tool["inputSchema"]
        self.assertEqual(schema["required"], ["id", "reason", "instructable"])
        self.assertIs(schema["additionalProperties"], False)
        self.assertEqual(schema["properties"]["reason"]["maxLength"], 200)
        self.assertEqual(schema["properties"]["baseRev"]["type"], "integer")
        self.assertEqual(schema["$defs"]["step"]["properties"]["id"]["pattern"], "^[a-z0-9][a-z0-9.-]{0,23}$")
        self.assertNotIn("id", schema["$defs"]["verify"]["properties"])
        self.assertIn("keep every step's `id`", tool["description"])

    def test_post_then_amend_through_the_server(self):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            post = s.call("relay_post", {"project": "Acme", "instructable": {"v": 1, "title": "Fix",
                                                                             "steps": [{"do": "Run it"}]}})
            self.assertFalse(post["isError"], post)
            self.assertIs(post["structuredContent"]["editable"], True)
            self.assertNotIn("relay wait", post["content"][0]["text"])   # the session id reaches the server
            record = json.loads((s.keys_dir / f"{ITEM_ID}.json").read_text())
            self.assertEqual(hashlib.sha256(record["key"].encode()).hexdigest(), POSTED[0]["editKeyHash"])
            amended = s.call("relay_amend", {"id": ITEM_ID, "reason": "the code was missing", "instructable": FIX})
            self.assertFalse(amended["isError"], amended)
            self.assertEqual(amended["structuredContent"],
                             {"id": ITEM_ID, "rev": 2, "hash": H2, "changed": [{"id": "s1", "path": "1",
                                                                                "fields": ["code"]}],
                              "added": [], "removed": [], "moved": [], "top": [], "openUrl": None})
            self.assertNotIn(record["key"], json.dumps(amended))
            status = s.call("relay_status", {"id": ITEM_ID})["structuredContent"]
            self.assertEqual((status["rev"], status["acceptedRev"], status["editable"]), (1, 1, True))
            self.assertEqual(status["problems"], [])
        finally:
            s.close()

    def test_no_edit_key_is_a_tool_error(self):
        s = Session.mailbox(self.tmp.name, self.url)
        try:
            res = s.call("relay_amend", {"id": ITEM_ID, "reason": "why", "instructable": FIX})
            self.assertTrue(res["isError"])
            self.assertEqual(res["structuredContent"]["error"],
                             f"No edit key for ask {ITEM_ID} on this Mac: only the process that posted it can "
                             f"correct it. Close it (relay done {ITEM_ID}) and post a new one.")
        finally:
            s.close()

    def test_bad_arguments(self):
        for args, message in (({"reason": "x", "instructable": FIX}, "id must be a non-empty string"),
                              ({"id": ITEM_ID, "reason": " ", "instructable": FIX},
                               "reason must be a non-empty string"),
                              ({"id": ITEM_ID, "reason": "x", "instructable": []},
                               "instructable must be a JSON object"),
                              ({"id": ITEM_ID, "reason": "x", "instructable": FIX, "baseRev": 0},
                               "baseRev must be a whole number from 1")):
            res = relay_mcp.call_tool({"name": "relay_amend", "arguments": args})
            self.assertEqual(res["structuredContent"], {"error": message})


class SessionIdLogTest(unittest.TestCase):
    def start(self, env):
        proc = subprocess.run(SERVER_CMD, input="", capture_output=True, text=True, env=env, timeout=10)
        return proc.stderr

    def test_logs_whether_the_session_id_is_there_never_the_value(self):
        base = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
        self.assertEqual(self.start(base), "session id: absent\n")
        err = self.start(dict(base, CLAUDE_CODE_SESSION_ID="sess-1234-abcd"))
        self.assertEqual(err, "session id: present\n")
        self.assertNotIn("sess-1234-abcd", err)


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
            self.assertIn("Hook queue", tool["description"])

    def test_post_describes_substeps_and_ships_both_defs(self):
        import relay_cli
        post = relay_mcp.tool_list()[0]
        self.assertEqual(relay_mcp.SUBSTEPS_SENTENCE, relay_cli.SUBSTEPS_SENTENCE)
        self.assertIn(relay_mcp.SUBSTEPS_SENTENCE, post["description"])
        defs = post["inputSchema"]["$defs"]
        self.assertIn("leaf", defs)
        self.assertIn("substeps", defs["step"]["properties"])
        self.assertEqual(post["inputSchema"]["properties"]["instructable"]["properties"]["verify"],
                         {"$ref": "#/$defs/verify"})

    def test_post_and_status_describe_step_questions(self):
        import relay_cli
        post, status = relay_mcp.tool_list()[0], relay_mcp.tool_list()[1]
        self.assertEqual(relay_mcp.QUESTIONS_SENTENCE, relay_cli.QUESTIONS_SENTENCE)
        self.assertIn(relay_mcp.QUESTIONS_SENTENCE, post["description"])
        self.assertIn(relay_mcp.BLOCKING_SENTENCE, post["description"])
        self.assertIn(relay_mcp.OPTIONAL_SENTENCE, post["description"])
        self.assertTrue(post["description"].endswith(relay_mcp.FILES_SENTENCE))
        self.assertEqual(relay_mcp.FILES_SENTENCE, relay_cli.FILES_SENTENCE)
        self.assertEqual(relay_mcp.BLOCKING_SENTENCE, relay_cli.BLOCKING_SENTENCE)
        self.assertEqual(relay_mcp.OPTIONAL_SENTENCE, relay_cli.OPTIONAL_SENTENCE)
        defs = post["inputSchema"]["$defs"]
        self.assertEqual(defs["step"]["properties"]["optional"]["type"], "boolean")
        self.assertEqual(defs["leaf"]["properties"]["optional"]["type"], "boolean")
        self.assertEqual(defs["step"]["properties"]["file"]["$ref"], "#/$defs/localPath")
        self.assertEqual(defs["leaf"]["properties"]["file"]["$ref"], "#/$defs/localPath")
        self.assertNotIn("file", defs["verify"]["properties"])
        link = post["inputSchema"]["properties"]["instructable"]["properties"]["links"]["items"]
        self.assertEqual(link["properties"]["path"], {"$ref": "#/$defs/localPath"})
        self.assertEqual(link["oneOf"], [{"required": ["url"]}, {"required": ["path"]}])
        self.assertNotIn("optional", defs["verify"]["properties"])
        defs = post["inputSchema"]["$defs"]
        self.assertEqual(defs["step"]["properties"]["question"], {"$ref": "#/$defs/question"})
        self.assertEqual(defs["leaf"]["properties"]["question"], {"$ref": "#/$defs/question"})
        self.assertNotIn("question", defs["verify"]["properties"])
        self.assertEqual(status["name"], "relay_status")
        for word in ("answer", "answers", "unanswered"):
            self.assertIn(word, status["description"])


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
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"RELAY_EDIT_KEY_DIR": str(Path(self.tmp.name) / "edit-keys")})
        patcher.start()
        self.addCleanup(patcher.stop)

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

    def test_answers_and_unanswered(self):
        from answers_fixture import answer, detail
        events = [event(1, "posted", "session"), answer(2, "3.2", ["Staging"]), answer(3, "4", text="EU"),
                  answer(4, "4", text="US"), answer(5, "1", ["Prod"], actor="session")]
        with mock.patch.object(relay_mcp, "make_client", lambda: FakeClient(detail(*events))):
            result = relay_mcp.relay_status({"id": ITEM_ID})
        plain = {"rev": 1, "stale": False, "verified": False}
        self.assertEqual(result["answers"], {"3.2": {"picked": ["Staging"], "at": "2026-10-11T09:02:00+00:00", **plain},
                                             "4": {"text": "US", "at": "2026-10-11T09:04:00+00:00", **plain}})
        self.assertEqual(result["unanswered"], ["1", "2", "3", "4.2"])
        self.assertEqual([e["kind"] for e in result["ownerEvents"]], ["answer", "answer", "answer"])

    def test_ask_without_questions_has_empty_answers(self):
        result = self.status("open", [event(1, "posted", "session")])
        self.assertEqual((result["answers"], result["unanswered"]), ({}, []))

    def test_status_carries_the_version_fields(self):
        problem = dict(event(2, "problem", "owner", json.dumps({"id": "s1", "step": "1", "note": "nope"})), rev=1)
        result = self.status("open", [event(1, "posted", "session"), problem])
        self.assertEqual((result["rev"], result["hash"], result["acceptedRev"], result["editable"]),
                         (1, None, 1, False))
        self.assertEqual(result["problems"], [{"id": "s1", "step": "1", "note": "nope", "rev": 1,
                                               "at": "2026-10-11T09:00:02+00:00"}])


if __name__ == "__main__":
    unittest.main()
