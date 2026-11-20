"""Documents on the Pond, the reading side: Client.docs, Client.doc and Client.release_docs, and
`relay docs <id>`, `relay docs <id> get <n> [-o FILE]` and `relay docs <id> release`, against a
fake Pond that replays conformance/wire/doc-wire-vectors.json. Stdlib only."""
from __future__ import annotations

import base64
import copy
import hashlib
import io
import json
import os
import urllib.error
import urllib.parse
from pathlib import Path

import relay_cli
import relay_client as rc
from test_docs_attach import WIRE, ClientDocsBase, DocsPond
from test_relay_client import ITEM_ID

UNKNOWN = "00000000-0000-4000-8000-000000000000"
PLAN_SHA = "89e032b48f654c6a542172e4396fbb6bd1cd37cfa66a5a59e987d0a3f398a4fd"
BOM_SHA = "aec9dacde4ea4958b2bf38914c0a77f15a61ff8df991f3a4cb402a59c764eb8c"
LIMIT = 262144


def recorded(name):
    """(status, exact body bytes) of a recorded response."""
    response = WIRE[name]["response"]
    if "bodyBase64" in response:
        return response["status"], base64.b64decode(response["bodyBase64"])
    return response["status"], json.dumps(response["body"]).encode("utf-8")


def served(name):
    """The instructable the Pond served back for a recorded post."""
    return copy.deepcopy(WIRE[name]["response"]["body"]["item"]["payload"]["instructable"])


def wire_path(name):
    return WIRE[name]["request"]["path"].replace("{ask1}", ITEM_ID).replace("{ask2}", ITEM_ID)


class Body:
    """A response body that counts what is read from it."""

    def __init__(self, data):
        self.stream = io.BytesIO(data)
        self.taken = 0
        self.whole_reads = 0

    def read(self, n=-1):
        if n is None or n < 0:
            self.whole_reads += 1
        chunk = self.stream.read(n)
        self.taken += len(chunk)
        return chunk

    def close(self):
        self.stream.close()


class RawResponse:
    def __init__(self, status, body):
        self.status = status
        self.body = body

    def read(self, n=-1):
        return self.body.read(n)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class ReadPond(DocsPond):
    """DocsPond that also answers document reads and releases. `docs` maps a request path to
    (status, exact bytes); the ask is served from `served`."""

    def __init__(self):
        super().__init__()
        self.docs = {}
        self.bodies = []

    def __call__(self, req, timeout=None):
        path = urllib.parse.urlsplit(req.full_url).path
        key = (req.get_method(), path)
        if key in self.docs:
            self.requests.append(req)
            status, data = self.docs[key]
            body = Body(data)
            self.bodies.append(body)
            if status >= 400:
                raise urllib.error.HTTPError(req.full_url, status, "error", {}, body)
            return RawResponse(status, body)
        return super().__call__(req, timeout)


class ReadBase(ClientDocsBase):
    def setUp(self):
        super().setUp()
        self.http = ReadPond()
        self.http.served = served("doc-post")

    def read_route(self, sha, status_body):
        self.http.docs[("GET", f"/asks/{ITEM_ID}/docs/{sha}")] = status_body

    def release_route(self, status_body, ask=ITEM_ID):
        self.http.docs[("POST", f"/asks/{ask}/docs/release")] = status_body

    def two_docs(self):
        """An ask with two documents (step 1 and a link) and a sub-step path without a `doc`."""
        plan = served("doc-post")["steps"][0]
        notes = served("doc-post-bom-crlf")["steps"][0]
        self.http.served = {
            "v": 1, "title": "Hand over", "steps": [
                plan,
                {"do": "Check", "id": "s2", "substeps": [{"do": "Open the log", "id": "s2.1",
                                                          "file": "~/notes/log.txt"}]}],
            "links": [{"label": "Notes", "path": "~/notes/handover.md", "doc": notes["doc"]}]}

    def doc_requests(self):
        return [r for r in self.http.requests if "/docs/" in urllib.parse.urlsplit(r.full_url).path]


class ListTests(ReadBase):
    def test_two_documents_in_document_order_and_a_path_without_doc(self):
        self.two_docs()
        self.assertEqual(self.client().docs(ITEM_ID), [
            {"n": 1, "field": "steps[0].file", "path": "~/notes/plan.md", "sha256": PLAN_SHA, "bytes": 93},
            {"n": 2, "field": "links[0].path", "path": "~/notes/handover.md", "sha256": BOM_SHA, "bytes": 77}])
        self.assertEqual(self.doc_requests(), [])

    def test_sub_steps_come_after_their_step(self):
        doc = {"sha256": PLAN_SHA, "bytes": 93}
        self.http.served = {"v": 1, "title": "t", "steps": [
            {"do": "a", "substeps": [{"do": "b", "file": "~/b.md", "doc": doc}]},
            {"do": "c", "file": "~/c.md", "doc": doc}]}
        self.assertEqual([(e["n"], e["field"]) for e in self.client().docs(ITEM_ID)],
                         [(1, "steps[0].substeps[0].file"), (2, "steps[1].file")])

    def test_no_documents_is_an_empty_list(self):
        self.http.served = {"v": 1, "title": "t", "steps": [{"do": "a", "file": "~/a.md"}]}
        self.assertEqual(self.client().docs(ITEM_ID), [])

    def test_a_malformed_doc_is_skipped(self):
        good = {"sha256": PLAN_SHA, "bytes": 93}
        bad = [{"sha256": PLAN_SHA}, {"sha256": PLAN_SHA.upper(), "bytes": 93}, {"sha256": PLAN_SHA, "bytes": True},
               {"sha256": PLAN_SHA, "bytes": 0}, {"sha256": PLAN_SHA, "bytes": LIMIT + 1},
               dict(good, extra=1), "x", None]
        self.http.served = {"v": 1, "title": "t", "steps": [{"do": "a", "file": "~/a.md", "doc": d} for d in bad]
                            + [{"do": "z", "file": "~/z.md", "doc": good}]}
        self.assertEqual([(e["n"], e["field"]) for e in self.client().docs(ITEM_ID)],
                         [(1, f"steps[{len(bad)}].file")])

    def test_an_unknown_ask(self):
        with self.assertRaises(rc.NotFound) as caught:
            self.client().docs(UNKNOWN)
        self.assertEqual(str(caught.exception), f"no ask with id {UNKNOWN}")


class ReadTests(ReadBase):
    def test_the_recorded_read(self):
        self.read_route(PLAN_SHA, recorded("doc-read"))
        text = self.client().doc(ITEM_ID, 1)
        self.assertEqual(text, WIRE["doc-read"]["response"]["body"])
        self.assertEqual([urllib.parse.urlsplit(r.full_url).path for r in self.doc_requests()],
                         [wire_path("doc-read")])
        request = self.doc_requests()[0]
        self.assertEqual((request.get_method(), request.data), ("GET", None))
        self.assertEqual(request.unredirected_hdrs.get("Authorization"), "Bearer mailbox-example")

    def test_bom_crlf_and_non_ascii_come_back_byte_for_byte(self):
        self.http.served = served("doc-post-bom-crlf")
        status, data = recorded("doc-read-bom-crlf")
        self.read_route(BOM_SHA, (status, data))
        text = self.client().doc(ITEM_ID, 1)
        self.assertTrue(text.startswith("﻿"))
        self.assertIn("\r\n", text)
        self.assertEqual(text.encode("utf-8"), data)

    def test_read_doc_gives_the_entry_too(self):
        self.read_route(PLAN_SHA, recorded("doc-read"))
        self.assertEqual(self.client().read_doc(ITEM_ID, 1),
                         {"n": 1, "field": "steps[0].file", "path": "~/notes/plan.md", "sha256": PLAN_SHA,
                          "bytes": 93, "text": WIRE["doc-read"]["response"]["body"]})

    def mismatch(self, data):
        self.read_route(PLAN_SHA, (200, data))
        with self.assertRaises(rc.RelayError) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "document does not match its fingerprint")
        self.assertEqual(caught.exception.exit_code, 1)

    def test_one_byte_off_raises(self):
        data = bytearray(recorded("doc-read")[1])
        data[0] ^= 0x01
        self.mismatch(bytes(data))

    def test_one_byte_more_or_less_raises(self):
        data = recorded("doc-read")[1]
        self.mismatch(data + b"x")
        self.mismatch(data[:-1])

    def test_the_right_hash_with_wrong_bytes_raises(self):
        data = recorded("doc-read")[1]
        self.http.served["steps"][0]["doc"]["bytes"] = 94
        self.mismatch(data)

    def test_bytes_that_are_not_utf8_raise_the_same(self):
        data = b"\xff\xfe plan"
        self.http.served["steps"][0]["doc"] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.read_route(hashlib.sha256(data).hexdigest(), (200, data))
        with self.assertRaises(rc.RelayError) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "document does not match its fingerprint")

    def test_a_body_past_the_limit_is_refused_without_reading_it_whole(self):
        self.read_route(PLAN_SHA, (200, b"a" * (4 * LIMIT)))
        with self.assertRaises(rc.RelayError) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "document does not match its fingerprint")
        body = self.http.bodies[-1]
        self.assertEqual((body.taken, body.whole_reads), (LIMIT + 1, 0))

    def test_released_410(self):
        self.read_route(PLAN_SHA, recorded("doc-read-released"))
        with self.assertRaises(rc.RelayError) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "document no longer kept on the Pond")
        self.assertEqual(caught.exception.exit_code, 1)

    def test_not_linked_404(self):
        self.read_route(PLAN_SHA, recorded("doc-read-not-linked"))
        with self.assertRaises(rc.NotFound) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "the Pond has no copy of this document")

    def test_an_old_pond_without_the_route_404(self):
        # No route at all: the fake answers 404 not found, as a Pond older than 1.10.0 does.
        with self.assertRaises(rc.NotFound) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), "the Pond has no copy of this document")

    def test_no_token_401_is_reported_like_other_reads(self):
        self.read_route(PLAN_SHA, recorded("doc-read-no-token"))
        with self.assertRaises(rc.Refused) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual((caught.exception.status, caught.exception.error), (401, "unauthorized"))

    def test_n_out_of_range(self):
        self.two_docs()
        for n in (0, 3, -1):
            with self.assertRaises(rc.RelayError) as caught:
                self.client().doc(ITEM_ID, n)
            self.assertEqual(str(caught.exception), f"no document {n}: ask {ITEM_ID} has documents 1 to 2")
        self.http.served = {"v": 1, "title": "t", "steps": [{"do": "a"}]}
        with self.assertRaises(rc.RelayError) as caught:
            self.client().doc(ITEM_ID, 1)
        self.assertEqual(str(caught.exception), f"no document 1: ask {ITEM_ID} has no documents")
        self.assertEqual(self.doc_requests(), [])

    def test_the_switch_off_still_reads(self):
        self.http.routes[("GET", "/version")] = (200, WIRE["doc-version-off"]["response"]["body"])
        self.read_route(PLAN_SHA, recorded("doc-read"))
        self.assertEqual(self.client().doc(ITEM_ID, 1), WIRE["doc-read"]["response"]["body"])


class ReleaseTests(ReadBase):
    def test_release_on_a_closed_ask_returns_the_count(self):
        self.release_route(recorded("doc-release"))
        self.assertEqual(self.client().release_docs(ITEM_ID), 1)
        self.release_route(recorded("doc-release-again"))
        self.assertEqual(self.client().release_docs(ITEM_ID), 0)
        request = self.doc_requests()[0]
        self.assertEqual((request.get_method(), request.data), ("POST", None))
        self.assertEqual(urllib.parse.urlsplit(request.full_url).path, wire_path("doc-release"))

    def test_release_on_an_open_ask(self):
        self.release_route(recorded("doc-release-open"))
        with self.assertRaises(rc.RelayError) as caught:
            self.client().release_docs(ITEM_ID)
        self.assertEqual(str(caught.exception), rc.DOCS_ASK_OPEN)
        self.assertEqual(caught.exception.exit_code, 1)

    def test_release_on_an_unknown_ask(self):
        self.release_route(recorded("doc-release-unknown-ask"), ask=UNKNOWN)
        with self.assertRaises(rc.NotFound) as caught:
            self.client().release_docs(UNKNOWN)
        self.assertEqual(str(caught.exception), f"no ask with id {UNKNOWN}")


class ThisMacTests(ReadBase):
    def test_every_call_raises_without_a_request(self):
        http = ReadPond()
        client = rc.Client({"source": "local", "port": 47911}, env=self.env, urlopen=http)
        for call in (lambda: client.docs(ITEM_ID), lambda: client.doc(ITEM_ID, 1),
                     lambda: client.read_doc(ITEM_ID, 1), lambda: client.release_docs(ITEM_ID)):
            with self.assertRaises(rc.RelayError) as caught:
                call()
            self.assertEqual(str(caught.exception), rc.LOCAL_NO_DOCS)
        self.assertEqual(http.requests, [])


class TTY(io.StringIO):
    def isatty(self):
        return True


class CliTests(ReadBase):
    def run_cli(self, *argv, stdout=None):
        out = stdout if stdout is not None else io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
        err = io.StringIO()
        code = relay_cli.main(list(argv), stdin=io.StringIO(""), stdout=out, stderr=err, env=self.env,
                              client_factory=lambda **kw: self.client())
        out.flush()
        raw = out.buffer.getvalue() if hasattr(out, "buffer") else out.getvalue().encode("utf-8")
        return code, raw, err.getvalue()

    def test_list_lines(self):
        self.two_docs()
        self.assertEqual(self.run_cli("docs", ITEM_ID), (0, (
            '1  steps[0].file  "~/notes/plan.md"  93 bytes  89e032b48f65\n'
            '2  links[0].path  "~/notes/handover.md"  77 bytes  aec9dacde4ea\n').encode("utf-8"), ""))

    def test_list_json(self):
        self.two_docs()
        code, out, err = self.run_cli("docs", ITEM_ID, "--json")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), self.client().docs(ITEM_ID))

    def test_list_without_documents(self):
        self.http.served = {"v": 1, "title": "t", "steps": [{"do": "a"}]}
        self.assertEqual(self.run_cli("docs", ITEM_ID), (0, f"no documents in ask {ITEM_ID}\n".encode(), ""))

    def test_get_writes_the_exact_bytes(self):
        self.http.served = served("doc-post-bom-crlf")
        status, data = recorded("doc-read-bom-crlf")
        self.read_route(BOM_SHA, (status, data))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "get", "1"), (0, data, ""))

    def test_get_on_a_terminal_shows_control_characters(self):
        data = "# Plan\r\n\tstep\x1b[2J\rover\n".encode("utf-8")
        self.http.served["steps"][0]["doc"] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.read_route(hashlib.sha256(data).hexdigest(), (200, data))
        tty = TTY()
        code, out, err = self.run_cli("docs", ITEM_ID, "get", "1", stdout=tty)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out.decode("utf-8"), "# Plan\r\n\tstep⟨U+001B⟩[2J⟨U+000D⟩over\n")

    def test_get_to_a_file(self):
        self.http.served = served("doc-post-bom-crlf")
        status, data = recorded("doc-read-bom-crlf")
        self.read_route(BOM_SHA, (status, data))
        target = Path(self.tmp.name) / "out.md"
        code, out, err = self.run_cli("docs", ITEM_ID, "get", "1", "-o", str(target))
        self.assertEqual((code, out, err), (0, b"", ""))
        self.assertEqual(target.read_bytes(), data)

    def test_get_one_byte_off_writes_no_file(self):
        data = bytearray(recorded("doc-read")[1])
        data[-1] ^= 0x01
        self.read_route(PLAN_SHA, (200, bytes(data)))
        target = Path(self.tmp.name) / "out.md"
        code, out, err = self.run_cli("docs", ITEM_ID, "get", "1", "-o", str(target))
        self.assertEqual((code, out, err), (1, b"", "relay: document does not match its fingerprint\n"))
        self.assertFalse(os.path.lexists(target))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "get", "1"),
                         (1, b"", "relay: document does not match its fingerprint\n"))

    def test_get_never_overwrites_a_file_or_follows_a_symlink(self):
        self.read_route(PLAN_SHA, recorded("doc-read"))
        existing = Path(self.tmp.name) / "mine.md"
        existing.write_bytes(b"mine")
        victim = Path(self.tmp.name) / "victim.md"
        victim.write_bytes(b"victim")
        link = Path(self.tmp.name) / "link.md"
        link.symlink_to(victim)
        dangling = Path(self.tmp.name) / "dangling.md"
        dangling.symlink_to(Path(self.tmp.name) / "nowhere.md")
        for target in (existing, link, dangling):
            code, out, err = self.run_cli("docs", ITEM_ID, "get", "1", "-o", str(target))
            self.assertEqual((code, out), (1, b""))
            self.assertEqual(err, f"relay: {target} already exists; nothing was written\n")
        self.assertEqual((existing.read_bytes(), victim.read_bytes()), (b"mine", b"victim"))
        self.assertFalse(os.path.exists(Path(self.tmp.name) / "nowhere.md"))

    def test_get_errors(self):
        self.read_route(PLAN_SHA, recorded("doc-read-released"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "get", "1"),
                         (1, b"", "relay: document no longer kept on the Pond\n"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "get", "2"),
                         (1, b"", f"relay: no document 2: ask {ITEM_ID} has documents 1 to 1\n"))
        self.read_route(PLAN_SHA, recorded("doc-read-no-token"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "get", "1"), (1, b"", "refused: unauthorized\n"))
        code, out, err = self.run_cli("docs", ITEM_ID, "get", "one")
        self.assertEqual((code, out), (2, b""))
        self.assertIn("invalid int value", err)

    def test_release(self):
        self.release_route(recorded("doc-release"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "release"), (0, f"released 1 document of {ITEM_ID}\n".encode(), ""))
        self.release_route(recorded("doc-release-again"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "release"), (0, f"released 0 documents of {ITEM_ID}\n".encode(), ""))

    def test_release_on_an_open_ask_prints_the_refusal(self):
        self.release_route(recorded("doc-release-open"))
        self.assertEqual(self.run_cli("docs", ITEM_ID, "release"), (1, b"", f"relay: {rc.DOCS_ASK_OPEN}\n"))

    def test_release_on_an_unknown_ask(self):
        self.release_route(recorded("doc-release-unknown-ask"), ask=UNKNOWN)
        self.assertEqual(self.run_cli("docs", UNKNOWN, "release"), (1, b"", f"relay: no ask with id {UNKNOWN}\n"))

    def test_this_mac(self):
        local = rc.Client({"source": "local", "port": 47911}, env=self.env, urlopen=ReadPond())
        err = io.StringIO()
        code = relay_cli.main(["docs", ITEM_ID], stdin=io.StringIO(""), stdout=io.StringIO(), stderr=err,
                              env=self.env, client_factory=lambda **kw: local)
        self.assertEqual((code, err.getvalue()), (1, f"relay: {rc.LOCAL_NO_DOCS}\n"))

    def test_json_goes_with_the_list_only(self):
        code, out, err = self.run_cli("docs", ITEM_ID, "--json", "release")
        self.assertEqual((code, out), (2, b""))
        self.assertIn("--json", err)

    def test_help_names_the_three_commands(self):
        out = io.StringIO()
        relay_cli.main(["docs", "--help"], stdin=io.StringIO(""), stdout=out, stderr=io.StringIO(), env=self.env)
        text = " ".join(out.getvalue().split())
        for words in ("get", "release", "--json", "7 days"):
            self.assertIn(words, text)
