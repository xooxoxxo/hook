"""relay_client: config resolution, server proof, auto-launch, error mapping. Stdlib only."""
from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import socket
import stat
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import relay_client as rc

ITEM_ID = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"
LOCAL_TOKEN = "ab" * 32
MAILBOX_TOKEN = "mailbox-example"


def proof_for(token, port, nonce):
    message = "relay-proof-v1\n" + str(port) + "\n" + nonce
    return hmac.new(token.encode(), message.encode(), hashlib.sha256).hexdigest()


class FakeResponse:
    def __init__(self, status, raw):
        self.status = status
        self._raw = raw

    def read(self):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeHTTP:
    """urlopen stand-in. /health answers like Relay; other routes come from `routes`."""

    def __init__(self, token=LOCAL_TOKEN, app="relay", source="local", proof="good", proof_port=None):
        self.token, self.app, self.health_source, self.proof = token, app, source, proof
        self.proof_port = proof_port   # None: the port the request was sent to, like Relay
        self.routes = {}            # (method, path?query) -> (status, body)
        self.refuse = 0             # refuse this many calls first (-1: always)
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        if self.refuse:
            self.refuse -= 1 if self.refuse > 0 else 0
            raise urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))
        parts = urllib.parse.urlsplit(req.full_url)
        if parts.path == "/health":
            body = {"ok": True, "app": self.app, "source": self.health_source}
            nonce = req.get_header("X-relay-nonce")
            if self.proof == "good" and nonce:
                port = self.proof_port if self.proof_port is not None else parts.port
                body["proof"] = proof_for(self.token, port, nonce)
            elif self.proof == "bad":
                body["proof"] = "0" * 64
            return self._answer(req, 200, body)
        target = parts.path + ("?" + parts.query if parts.query else "")
        status, body = self.routes.get((req.get_method(), target), (404, {"error": "not found"}))
        return self._answer(req, status, body)

    @staticmethod
    def _answer(req, status, body):
        raw = json.dumps(body).encode()
        if status >= 400:
            raise urllib.error.HTTPError(req.full_url, status, "error", {}, io.BytesIO(raw))
        return FakeResponse(status, raw)

    def sent(self, path):
        return [r for r in self.requests if urllib.parse.urlsplit(r.full_url).path == path]


class FakeClock:
    def __init__(self):
        self.now = 100.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "relay"
        self.dir.mkdir()
        self.cfg_path = self.dir / "config.json"
        self.env = {"RELAY_CONFIG": str(self.cfg_path), "CLAUDE_SESSION_ID": "test-session"}
        (self.dir / "local-token").write_text(LOCAL_TOKEN + "\n")
        (self.dir / "mailbox-token").write_text(MAILBOX_TOKEN + "\n")

    def tearDown(self):
        self.tmp.cleanup()

    def local(self, http, **kw):
        return rc.Client({"source": "local", "port": 47911}, env=self.env, urlopen=http, **kw)

    def mailbox(self, http, **kw):
        cfg = {"mailboxURL": "https://mailbox.example/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=self.env, urlopen=http, **kw)


class ConfigTests(Base):
    def test_config_without_source_resolves_to_mailbox(self):
        src = rc.resolve_source({"mailboxURL": "https://mailbox.example", "tokenFile": "~/t",
                                 "port": 47823, "pollSeconds": 15})
        self.assertEqual(src, {"kind": "mailbox", "url": "https://mailbox.example", "token_file": "~/t",
                               "context": "personal"})

    def test_local_and_port(self):
        self.assertEqual(rc.resolve_source({"source": "local"}), {"kind": "local", "port": 47823})
        self.assertEqual(rc.resolve_source({"source": "local", "port": 47911}), {"kind": "local", "port": 47911})
        self.assertEqual(rc.resolve_source({"source": "local", "mailboxURL": "https://m.example"})["kind"], "local")

    def test_incomplete(self):
        for cfg in ({}, {"source": "elsewhere"}, {"mailboxURL": 5}):
            with self.assertRaises(rc.ConfigMissing) as ctx:
                rc.resolve_source(cfg)
            self.assertEqual(str(ctx.exception), "No Relay config; run scripts/install.sh")
            self.assertEqual(ctx.exception.exit_code, 2)

    def test_invalid_mailbox(self):
        for cfg in ({"source": "mailbox"},
                    {"mailboxURL": "ftp://mailbox.example", "tokenFile": "t"},
                    {"mailboxURL": "https://", "tokenFile": "t"},
                    {"mailboxURL": "https://mailbox.example", "tokenFile": "  "},
                    {"mailboxURL": "https://mailbox.example"}):
            with self.assertRaises(rc.ConfigMissing) as ctx:
                rc.resolve_source(cfg)
            self.assertEqual(str(ctx.exception), "mailbox needs an http(s) mailboxURL and a tokenFile")

    def test_wrong_types_fall_back_and_bad_port_fails(self):
        src = rc.resolve_source({"source": 5, "mailboxURL": "HTTPS://mailbox.example", "tokenFile": "t",
                                 "context": 7, "port": None})
        self.assertEqual(src["kind"], "mailbox")
        self.assertEqual(src["context"], "personal")
        for port in (0, 65536, "47823", True):
            with self.assertRaises(rc.ConfigMissing):
                rc.resolve_source({"source": "local", "port": port})

    def test_paths_follow_relay_config(self):
        self.assertEqual(rc.config_path(self.env), self.cfg_path)
        self.assertEqual(rc.config_dir(self.env), self.dir)
        self.assertEqual(rc.config_path({}), Path("~/.config/relay/config.json").expanduser())

    def test_load_config_names_the_path(self):
        with self.assertRaises(rc.ConfigMissing) as ctx:
            rc.load_config(self.env)
        self.assertIn(str(self.cfg_path), str(ctx.exception))
        self.cfg_path.write_text("{nope")
        with self.assertRaises(rc.ConfigMissing) as ctx:
            rc.load_config(self.env)
        self.assertIn(str(self.cfg_path), str(ctx.exception))
        self.cfg_path.write_text('{"source":"local"}')
        self.assertEqual(rc.load_config(self.env), {"source": "local"})

    def test_client_reads_config_from_relay_config(self):
        self.cfg_path.write_text('{"source":"local","port":47912}')
        client = rc.Client(env=self.env, urlopen=FakeHTTP())
        self.assertEqual(client.base, "http://127.0.0.1:47912")

    def test_source_key(self):
        self.assertEqual(self.local(FakeHTTP()).source_key(), "local")
        digest = hashlib.sha1(b"https://mailbox.example/").hexdigest()[:12]
        self.assertEqual(self.mailbox(FakeHTTP()).source_key(), "mailbox:" + digest)


class ProofTests(Base):
    def setUp(self):
        super().setUp()
        self.http = FakeHTTP()
        self.http.routes[("POST", "/asks")] = (201, {"item": {"id": ITEM_ID}, "openUrl": "http://127.0.0.1:47911/i/" + ITEM_ID})

    def test_good_proof_sends_the_token(self):
        res = self.local(self.http).post("Acme", {"v": 1, "title": "Check Node", "steps": [{"do": "Run it"}]})
        self.assertEqual(res["item"]["id"], ITEM_ID)
        health, post = self.http.requests
        self.assertEqual(urllib.parse.urlsplit(health.full_url).path, "/health")
        self.assertIsNone(health.get_header("Authorization"))
        self.assertRegex(health.get_header("X-relay-nonce"), r"^[0-9a-f]{32}$")
        self.assertEqual(post.get_header("Authorization"), "Bearer " + LOCAL_TOKEN)
        self.assertEqual(post.get_header("X-relay-client"), "cli/" + rc.VERSION)
        body = json.loads(post.data)
        self.assertNotIn("context", body)
        self.assertEqual(body["instructable"]["from"]["session"], "test-session")

    def test_fresh_nonce_per_call(self):
        client = self.local(self.http)
        client.post("Acme", {"v": 1, "title": "a"})
        client.post("Acme", {"v": 1, "title": "b"})
        nonces = [r.get_header("X-relay-nonce") for r in self.http.sent("/health")]
        self.assertEqual(len(nonces), 2)
        self.assertNotEqual(nonces[0], nonces[1])

    def assert_not_sent(self, http, message):
        with self.assertRaises(rc.Unreachable) as ctx:
            self.local(http).post("Acme", {"v": 1, "title": "Check Node"})
        self.assertEqual(str(ctx.exception), message)
        self.assertEqual(ctx.exception.exit_code, 2)
        self.assertTrue(all(r.get_header("Authorization") is None for r in http.requests))
        self.assertEqual(http.sent("/asks"), [])

    def test_bad_proof(self):
        self.assert_not_sent(FakeHTTP(proof="bad"),
                             "Something else is answering on 127.0.0.1:47911; not sending.")

    def test_missing_proof(self):
        self.assert_not_sent(FakeHTTP(proof="missing"),
                             "Something else is answering on 127.0.0.1:47911; not sending.")

    def test_proof_from_another_token(self):
        self.assert_not_sent(FakeHTTP(token="cd" * 32),
                             "Something else is answering on 127.0.0.1:47911; not sending.")

    def test_proof_for_another_port(self):
        # Right token and nonce, but bound to a different listener's port.
        self.assert_not_sent(FakeHTTP(proof_port=47912),
                             "Something else is answering on 127.0.0.1:47911; not sending.")

    def test_something_else_answering(self):
        self.assert_not_sent(FakeHTTP(app="nginx"),
                             "Something else is answering on 127.0.0.1:47911; not sending.")

    def test_not_local(self):
        self.assert_not_sent(FakeHTTP(source="mailbox"), "Relay is running but not in This Mac mode.")

    def test_health_returns_the_verified_body(self):
        self.assertEqual(self.local(self.http).health()["source"], "local")

    def test_body_is_ascii_escaped(self):
        self.local(self.http).post("Acme", {"v": 1, "title": "café \ud800"})
        post = self.http.sent("/asks")[0]
        self.assertIn(b"caf\\u00e9 \\ud800", post.data)      # no UnicodeEncodeError; the server says invalid json


class LaunchTests(Base):
    def setUp(self):
        super().setUp()
        self.http = FakeHTTP()
        self.http.routes[("GET", "/asks?status=open&days=36500")] = (200, {"items": []})
        self.clock = FakeClock()
        self.launched = []

    def client(self, ok=True, **kw):
        def launcher(argv):
            self.launched.append(argv)
            return ok
        return self.local(self.http, launcher=launcher, sleep=self.clock.sleep,
                          monotonic=self.clock.monotonic, **kw)

    def test_launches_once_then_retries(self):
        self.http.refuse = 3
        self.assertEqual(self.client().list(), [])
        self.assertEqual(self.launched, [["open", "-g", "-a", "Relay"]])
        self.assertEqual(self.clock.sleeps, [0.25, 0.25, 0.25])

    def test_gives_up_after_five_seconds(self):
        self.http.refuse = -1
        with self.assertRaises(rc.Unreachable) as ctx:
            self.client().list()
        self.assertEqual(str(ctx.exception), "Relay isn't running")
        self.assertEqual(len(self.clock.sleeps), 20)
        self.assertEqual(len(self.launched), 1)

    def test_open_fails(self):
        self.http.refuse = -1
        with self.assertRaises(rc.Unreachable) as ctx:
            self.client(ok=False).list()
        self.assertEqual(str(ctx.exception), "Relay.app not found; run scripts/install.sh")

    def test_no_autolaunch(self):
        self.http.refuse = -1
        with self.assertRaises(rc.Unreachable) as ctx:
            self.client(autolaunch=False).list()
        self.assertEqual(str(ctx.exception), "Relay isn't running")
        self.assertEqual(self.launched, [])
        self.assertEqual(self.clock.sleeps, [])


class MailboxTests(Base):
    def setUp(self):
        super().setUp()
        self.http = FakeHTTP()

    def test_post_sends_context_and_mailbox_token(self):
        self.http.routes[("POST", "/asks")] = (200, {"item": {"id": ITEM_ID}, "deduped": True})
        res = self.mailbox(self.http, kind="mcp").post("Acme", {"v": 1, "title": "Check Node",
                                                                "from": {"host": "h"}})
        self.assertTrue(res["deduped"])
        (req,) = self.http.requests                      # no /health in mailbox mode
        self.assertEqual(req.full_url, "https://mailbox.example/asks")
        self.assertEqual(req.get_header("Authorization"), "Bearer " + MAILBOX_TOKEN)
        self.assertEqual(req.get_header("X-relay-client"), "mcp/" + rc.VERSION)
        body = json.loads(req.data)
        self.assertEqual(body["context"], "work")
        self.assertEqual(body["instructable"]["from"], {"host": "h"})

    def test_queries_and_bodies(self):
        self.http.routes[("GET", "/asks?status=all&days=3")] = (200, {"items": [{"id": ITEM_ID}]})
        self.http.routes[("POST", f"/asks/{ITEM_ID}/resolve")] = (200, {"item": {"id": ITEM_ID, "status": "dismissed"}})
        self.http.routes[("GET", "/events?after=7&limit=1000")] = (200, {"events": [], "next": 7})
        client = self.mailbox(self.http)
        self.assertEqual(client.list("all", 3), [{"id": ITEM_ID}])
        self.assertEqual(client.resolve(ITEM_ID, "declined", "not needed")["item"]["status"], "dismissed")
        self.assertEqual(json.loads(self.http.requests[-1].data),
                         {"verdict": "declined", "actor": "session", "note": "not needed"})
        self.assertEqual(client.events(after=7), {"events": [], "next": 7})

    def test_401(self):
        self.http.routes[("GET", "/asks?status=open&days=36500")] = (401, {"error": "unauthorized"})
        with self.assertRaises(rc.Refused) as ctx:
            self.mailbox(self.http).list()
        self.assertEqual((ctx.exception.status, ctx.exception.error, ctx.exception.exit_code),
                         (401, "unauthorized", 1))

    def test_404(self):
        with self.assertRaises(rc.NotFound) as ctx:
            self.mailbox(self.http).get("nope")
        self.assertEqual(str(ctx.exception), "no ask with id nope")
        self.assertEqual(ctx.exception.exit_code, 1)

    def test_400_with_details(self):
        self.http.routes[("POST", "/asks")] = (400, {"error": "invalid instructable",
                                                    "details": ["steps: required", "title: too long"]})
        with self.assertRaises(rc.Refused) as ctx:
            self.mailbox(self.http).post("Acme", {"v": 1, "title": "x"})
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(ctx.exception.error, "invalid instructable")
        self.assertEqual(ctx.exception.details, ["steps: required", "title: too long"])

    def test_connection_refused(self):
        self.http.refuse = -1
        with self.assertRaises(rc.Unreachable) as ctx:
            self.mailbox(self.http).list()
        self.assertIn("mailbox unreachable: https://mailbox.example", str(ctx.exception))
        self.assertNotIn(MAILBOX_TOKEN, str(ctx.exception))

    def test_unreadable_token(self):
        (self.dir / "mailbox-token").write_text("\n")
        with self.assertRaises(rc.ConfigMissing):
            self.mailbox(self.http).list()


class HelperTests(Base):
    def test_private_write_leaves_an_existing_parent_alone(self):
        shared = Path(self.tmp.name) / "shared"
        shared.mkdir()
        os.chmod(shared, 0o755)
        rc.private_write(shared / "replies-cursor.json", b"{}")
        self.assertEqual(stat.S_IMODE(shared.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((shared / "replies-cursor.json").stat().st_mode), 0o600)

    def test_proof_vector_matches_swift(self):
        # The same pinned vector as LocalTokenTests.proofMatchesHMACVector, so the two
        # sides can't drift together.
        pinned = "5b008b5ba39aee57aa562663270a99e856596c1a3c520a3142555cfbd54bd5c5"
        nonce = "0123456789abcdef" * 2
        self.assertEqual(proof_for("ab" * 32, 47823, nonce), pinned)

        def health(req, timeout=None):   # answers only the pinned proof, not a recomputed one
            body = {"ok": True, "app": "relay", "source": "local", "proof": pinned}
            return FakeResponse(200, json.dumps(body).encode())

        client = rc.Client({"source": "local", "port": 47823}, env=self.env, urlopen=health)
        with mock.patch.object(rc.secrets, "token_hex", lambda n: nonce):
            token, _ = client._verify_server()
        self.assertEqual(token, LOCAL_TOKEN)

    def test_private_write(self):
        target = Path(self.tmp.name) / "fresh" / "replies-cursor.json"
        rc.private_write(target, b"{}")
        rc.private_write(target, b'{"a":1}')
        self.assertEqual(target.read_bytes(), b'{"a":1}')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
        self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["replies-cursor.json"])

    def test_fill_from(self):
        original = {"v": 1, "title": "t"}
        filled = rc.fill_from(original, {"CLAUDE_SESSION_ID": "s1"})
        self.assertNotIn("from", original)
        self.assertEqual(filled["from"], {"host": socket.gethostname(), "cwd": os.getcwd(), "session": "s1"})
        self.assertNotIn("session", rc.fill_from(original, {})["from"])
        self.assertEqual(rc.fill_from({"from": {"host": "x"}}, {"CLAUDE_SESSION_ID": "s1"})["from"], {"host": "x"})

    def test_one_line(self):
        self.assertEqual(rc.one_line("a\nb\r\nc"), "a ⏎ b ⏎ c")


class StubRelay(BaseHTTPRequestHandler):
    """A real HTTP Relay in local mode, for one end-to-end round trip."""
    seen = []

    def log_message(self, *args):
        pass

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        StubRelay.seen.append(("GET", self.path, self.headers.get("Host"), self.headers.get("Authorization")))
        if self.path != "/health":
            return self._send(404, {"error": "not found"})
        nonce = self.headers.get("X-Relay-Nonce") or ""
        port = self.server.server_address[1]
        self._send(200, {"ok": True, "app": "relay", "source": "local", "proof": proof_for(LOCAL_TOKEN, port, nonce)})

    def do_POST(self):
        StubRelay.seen.append(("POST", self.path, self.headers.get("Host"), self.headers.get("Authorization")))
        if self.headers.get("Authorization") != "Bearer " + LOCAL_TOKEN:
            return self._send(401, {"error": "unauthorized"})
        self.rfile.read(int(self.headers["Content-Length"]))
        self._send(201, {"item": {"id": ITEM_ID}, "openUrl": "x"})


class RedirectTests(Base):
    def serve(self, handler_cls):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def test_redirect_is_not_followed_and_token_not_leaked(self):
        received = []

        class Sink(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            log_message = lambda *a, **k: None

        sink = self.serve(Sink)
        target = f"http://127.0.0.1:{sink.server_address[1]}/asks"

        class Redirector(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", target)
                self.send_header("Content-Length", "0")
                self.end_headers()

            log_message = lambda *a, **k: None

        origin = self.serve(Redirector)
        cfg = {"mailboxURL": f"http://127.0.0.1:{origin.server_address[1]}",
               "tokenFile": str(self.dir / "mailbox-token"), "context": "work"}
        (self.dir / "mailbox-token").write_text("tok-example\n")
        client = rc.Client(cfg, env=self.env)
        with self.assertRaises(rc.Unreachable) as ctx:
            client.list()
        self.assertIn("redirect", str(ctx.exception))
        self.assertNotIn("tok-example", str(ctx.exception))
        self.assertEqual(received, [])

    def test_default_openers_refuse_redirects(self):
        for cfg in ({"source": "local", "port": 47911},
                    {"mailboxURL": "https://mailbox.example", "tokenFile": "t"}):
            client = rc.Client(cfg, env=self.env)
            handlers = client._urlopen.__self__.handlers
            self.assertTrue(any(isinstance(h, rc._NoRedirect) for h in handlers), cfg)

    def test_any_3xx_status_maps_to_unreachable(self):
        http = FakeHTTP()
        http.routes[("GET", "/asks?status=open&days=36500")] = (307, {})
        client = self.mailbox(http)
        with self.assertRaises(rc.Unreachable) as ctx:
            client.list()
        self.assertIn("redirect (307)", str(ctx.exception))


class RoundTripTests(Base):
    def test_real_http(self):
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), StubRelay)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            StubRelay.seen = []
            port = httpd.server_port
            client = rc.Client({"source": "local", "port": port}, env=self.env)
            self.assertEqual(client.post("Acme", {"v": 1, "title": "t"})["item"]["id"], ITEM_ID)
            self.assertEqual(StubRelay.seen, [("GET", "/health", f"127.0.0.1:{port}", None),
                                              ("POST", "/asks", f"127.0.0.1:{port}", "Bearer " + LOCAL_TOKEN)])
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_real_http_ignores_proxy_settings(self):
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), StubRelay)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        dead_proxy = "http://127.0.0.1:9"
        try:
            StubRelay.seen = []
            with mock.patch.dict(os.environ, {"http_proxy": dead_proxy, "HTTP_PROXY": dead_proxy,
                                              "no_proxy": "", "NO_PROXY": ""}):
                client = rc.Client({"source": "local", "port": httpd.server_port}, env=self.env)
                self.assertEqual(client.post("Acme", {"v": 1, "title": "t"})["item"]["id"], ITEM_ID)
            self.assertEqual([s[0] for s in StubRelay.seen], ["GET", "POST"])
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_real_refused(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        client = rc.Client({"source": "local", "port": port}, env=self.env, autolaunch=False)
        with self.assertRaises(rc.Unreachable) as ctx:
            client.list()
        self.assertEqual(str(ctx.exception), "Relay isn't running")


class TrustTests(Base):
    def open_up(self):
        os.chmod(self.dir, 0o777)

    def test_dir_checks(self):
        os.chmod(self.dir, 0o755)
        rc.check_trusted_dir(self.dir)
        self.open_up()
        with self.assertRaisesRegex(rc.ConfigMissing, "writable by other users; refusing to use it"):
            rc.check_trusted_dir(self.dir)
        with self.assertRaisesRegex(rc.ConfigMissing, "belongs to another user"):
            rc.check_trusted_dir("/")

    def test_file_checks(self):
        real = self.dir / "real.json"
        real.write_text("{}")
        link = self.dir / "link.json"
        link.symlink_to(real)
        rc.check_trusted_file(link)
        rc.check_trusted_file(self.dir / "missing.json")
        folder = self.dir / "folder.json"
        folder.mkdir()
        with self.assertRaisesRegex(rc.ConfigMissing, "not a regular file owned by you; refusing to use it"):
            rc.check_trusted_file(folder)

    def test_load_config_refuses_untrusted(self):
        self.cfg_path.write_text("{}")
        self.assertEqual(rc.load_config(self.env), {})
        self.open_up()
        with self.assertRaisesRegex(rc.ConfigMissing, "writable by other users"):
            rc.load_config(self.env)
        os.chmod(self.dir, 0o700)
        self.cfg_path.unlink()
        self.cfg_path.mkdir()
        with self.assertRaisesRegex(rc.ConfigMissing, "not a regular file owned by you"):
            rc.load_config(self.env)

    def test_missing_config_folder_is_still_just_missing(self):
        env = {"RELAY_CONFIG": str(Path(self.tmp.name) / "nope" / "config.json")}
        with self.assertRaisesRegex(rc.ConfigMissing, "No Relay config"):
            rc.load_config(env)

    def test_local_token_refuses_untrusted_folder(self):
        client = self.local(FakeHTTP())
        self.assertEqual(client._local_token(), LOCAL_TOKEN)
        self.open_up()
        with self.assertRaisesRegex(rc.ConfigMissing, "writable by other users"):
            client._local_token()

    def test_private_write_refuses_untrusted_folder_and_writes_nothing(self):
        self.open_up()
        target = self.dir / "replies-cursor.json"
        with self.assertRaisesRegex(rc.ConfigMissing, "writable by other users"):
            rc.private_write(target, b"{}")
        self.assertFalse(target.exists())
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["local-token", "mailbox-token"])

    def test_private_write_refuses_a_directory_target(self):
        target = self.dir / "replies-cursor.json"
        target.mkdir()
        with self.assertRaisesRegex(rc.ConfigMissing, "not a regular file owned by you"):
            rc.private_write(target, b"{}")


if __name__ == "__main__":
    unittest.main()
