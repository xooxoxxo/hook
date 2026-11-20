"""Documents on the Pond, the client side: relay_docs.attach_docs, and post, amend and append
attaching the document a step's `file` or a link's `path` points at (Pond feature `docs`).
Every file lives in a temporary folder that stands in for the home folder. Stdlib only."""
from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import urllib.parse
from pathlib import Path
from unittest import mock

import relay_cli
import relay_client as rc
import relay_docs as rd
from test_relay_amend import H1, H2
from test_relay_append import AppendPond
from test_relay_client import ITEM_ID, Base, FakeHTTP

ROOT = Path(__file__).resolve().parent.parent
WIRE = {c["name"]: c for c in json.loads((ROOT / "conformance" / "wire" / "doc-wire-vectors.json")
                                        .read_text(encoding="utf-8"))["cases"]}
DOC_FEATURES = ["answers", "corrections", "requirements", "appendSteps", "docs"]
KEY = "K" * 43
PLAN = "# Plan\n\n1. Ship it.\n"

# What this client sent before documents, recorded at 927ce26 for BYTES_ASK (no `doc` keys)
# against a Pond 1.9.0 without `docs`, with the edit key fixed to KEY.
BYTES_ASK = {"v": 1, "title": "Prüfe den Plan – ok", "from": {"host": "mac", "cwd": "/w"},
             "steps": [{"do": "Lies den Plan", "file": "~/notes/plan.md"},
                       {"do": "Read the notes", "substeps": [{"do": "Open them", "file": "~/notes/n.txt"}]}],
             "links": [{"label": "Notizen", "path": "~/notes/more.md"}]}
BYTES_STEPS = [{"do": "Read the next part", "file": "~/notes/next.md"}]
_INSTRUCTABLE = ('{"v": 1, "title": "Pr\\u00fcfe den Plan \\u2013 ok", "from": {"host": "mac", "cwd": "/w"}, '
                 '"steps": [{"do": "Lies den Plan", "file": "~/notes/plan.md"}, {"do": "Read the notes", '
                 '"substeps": [{"do": "Open them", "file": "~/notes/n.txt"}]}], '
                 '"links": [{"label": "Notizen", "path": "~/notes/more.md"}]}')
RECORDED = {
    "post": ('{"project": "Example", "instructable": ' + _INSTRUCTABLE + ', "context": "work", '
             '"editKeyHash": "7a97835b001a7648b60ef502bc760f5ec329991efe0386300900d6cf99497e44"}'),
    "amend": ('{"editKey": "' + KEY + '", "baseRev": 1, "baseHash": "' + "a" * 64 + '", '
              '"reason": "Point at the notes", "instructable": ' + _INSTRUCTABLE + '}'),
    "append": ('{"editKey": "' + KEY + '", "baseRev": 1, "baseHash": "' + "a" * 64 + '", '
               '"note": "One more part", "steps": [{"do": "Read the next part", "file": "~/notes/next.md"}]}'),
    "local": '{"project": "Example", "instructable": ' + _INSTRUCTABLE + '}',
}


def fingerprint(data: bytes):
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def with_docs(instructable, value=None):
    """A copy with a `doc` on every step, sub-step and link that has a path (as a session might)."""
    out = copy.deepcopy(instructable)
    doc = value if value is not None else {"sha256": "f" * 64, "bytes": 1}
    for step in out.get("steps", []):
        nodes = [step] + step.get("substeps", [])
        for node in nodes:
            if "file" in node:
                node["doc"] = doc
    for link in out.get("links", []):
        if "path" in link:
            link["doc"] = doc
    return out


class HomeBase(Base):
    """A temporary home folder; the client and attach_docs read files only below it."""

    def setUp(self):
        super().setUp()
        self.home = Path(self.tmp.name) / "home"
        (self.home / "notes").mkdir(parents=True)
        self.env["HOME"] = str(self.home)

    def write(self, rel, data):
        path = self.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        return path

    def attach(self, instructable, **kw):
        return rd.attach_docs(instructable, home=str(self.home), **kw)


class AttachTests(HomeBase):
    def test_wire_vectors_post_and_bom_crlf(self):
        for name, rel in (("doc-post", "notes/plan.md"), ("doc-post-bom-crlf", "notes/handover.md")):
            body = WIRE[name]["request"]["body"]
            (text,) = body["docs"].values()
            self.write(rel, text.encode("utf-8"))
            sent = copy.deepcopy(body["instructable"])
            for step in sent["steps"]:
                step.pop("doc", None)
            instructable, docs, notes = self.attach(sent)
            self.assertEqual((instructable, docs, notes), (body["instructable"], body["docs"], []), name)

    def test_the_exact_bytes_travel(self):
        raw = "﻿# Übergabe\r\n\r\nCafé\r\nno end".encode("utf-8")
        self.write("notes/h.md", raw)
        instructable, docs, notes = self.attach({"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/h.md"}]})
        self.assertEqual(instructable["steps"][0]["doc"], fingerprint(raw))
        self.assertEqual(docs, {fingerprint(raw)["sha256"]: raw.decode("utf-8")})
        self.assertEqual(notes, [])

    def test_doc_sits_after_the_path_in_document_order(self):
        for rel in ("notes/a.md", "notes/b.MARKDOWN", "notes/c.Txt", "notes/d.md"):
            self.write(rel, rel)
        ask = {"v": 1, "title": "t",
               "steps": [{"do": "A", "file": "~/notes/a.md", "id": "s1"},
                         {"do": "B", "substeps": [{"do": "B1", "file": "~/notes/b.MARKDOWN"}]}],
               "links": [{"label": "C", "path": "~/notes/c.Txt"}, {"label": "W", "url": "https://pond.example.test/"},
                         {"label": "D", "path": str(self.home / "notes" / "d.md")}]}
        instructable, docs, notes = self.attach(ask)
        self.assertEqual(notes, [])
        self.assertEqual(list(instructable["steps"][0]), ["do", "file", "doc", "id"])
        self.assertEqual(instructable["steps"][1]["substeps"][0]["doc"], fingerprint(b"notes/b.MARKDOWN"))
        self.assertEqual(instructable["links"][0]["doc"], fingerprint(b"notes/c.Txt"))
        self.assertNotIn("doc", instructable["links"][1])
        self.assertEqual(instructable["links"][2]["doc"], fingerprint(b"notes/d.md"))
        self.assertEqual(list(docs.values()), ["notes/a.md", "notes/b.MARKDOWN", "notes/c.Txt", "notes/d.md"])
        self.assertEqual(ask["steps"][0], {"do": "A", "file": "~/notes/a.md", "id": "s1"})   # the input is untouched

    def test_a_doc_the_caller_wrote_is_dropped_everywhere(self):
        ask = with_docs(BYTES_ASK)
        ask["steps"][0]["doc"] = None
        self.assertEqual(rd.strip_docs(ask), BYTES_ASK)
        self.assertEqual(json.dumps(rd.strip_docs(ask)), json.dumps(BYTES_ASK))
        # Nothing on disk: every doc goes, and none comes back.
        instructable, docs, notes = self.attach(ask)
        self.assertEqual((instructable, docs), (BYTES_ASK, {}))
        self.assertEqual(notes, ["steps[0].file not copied to the Pond: not on this machine",
                                 "steps[1].substeps[0].file not copied to the Pond: not on this machine",
                                 "links[0].path not copied to the Pond: not on this machine"])

    def test_a_doc_the_caller_wrote_is_replaced_by_the_real_one(self):
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md",
                                                "doc": {"sha256": "0" * 64, "bytes": 3}}]}
        instructable, docs, _ = self.attach(ask)
        self.assertEqual(instructable["steps"][0]["doc"], fingerprint(PLAN.encode()))

    def test_each_skip_gives_one_note_and_keeps_the_path(self):
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "secret.md").write_text("outside the home folder")
        (self.home / "notes" / "folder.md").mkdir()
        (self.home / "notes" / "out.md").symlink_to(outside / "secret.md")
        (self.home / "notes" / "gone.md").symlink_to(self.home / "notes" / "missing.md")
        self.write("notes/plan.pdf", "%PDF")
        self.write("notes/empty.md", b"")
        self.write("notes/big.md", b"a" * (rd.MAX_DOC_BYTES + 1))
        self.write("notes/latin1.md", "café".encode("latin-1"))
        self.write("notes/nul.txt", b"a\x00b")
        os.mkfifo(str(self.home / "notes" / "pipe.md"))
        cases = [("~/notes/nowhere.md", "not on this machine"), ("~/notes/folder.md", "not a file"),
                 ("~/notes/out.md", "not a file"), ("~/notes/gone.md", "not on this machine"),
                 ("~/notes/plan.pdf", "not a .md, .markdown or .txt file"), ("~/notes/empty.md", "empty"),
                 ("~/notes/big.md", "larger than 256 KB"), ("~/notes/latin1.md", "not UTF-8 text"),
                 ("~/notes/nul.txt", "not UTF-8 text"), ("/dev/null", "not a .md, .markdown or .txt file"),
                 ("~/notes/pipe.md", "not a file"), ("~/notes/plan.pdf/x.md", "not on this machine")]
        if os.geteuid() != 0:
            locked = self.write("notes/locked.md", "no access")
            os.chmod(locked, 0)
            cases.append(("~/notes/locked.md", "not a file"))
        for path, reason in cases:
            ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": path}]}
            instructable, docs, notes = self.attach(ask)
            self.assertEqual((instructable, docs), (ask, {}), path)
            self.assertEqual(notes, [f"steps[0].file not copied to the Pond: {reason}"], path)
        if os.geteuid() != 0:
            os.chmod(locked, 0o600)

    def test_the_largest_document_is_taken(self):
        self.write("notes/full.md", b"a" * rd.MAX_DOC_BYTES)
        instructable, docs, notes = self.attach({"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/notes/full.md"}]})
        self.assertEqual((instructable["steps"][0]["doc"]["bytes"], notes), (rd.MAX_DOC_BYTES, []))

    def test_a_symlink_inside_the_home_folder_is_followed(self):
        target = self.write("drafts/plan.md", PLAN)
        (self.home / "notes" / "plan.md").symlink_to(target)
        instructable, docs, notes = self.attach({"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/notes/plan.md"}]})
        self.assertEqual((instructable["steps"][0]["doc"], notes), (fingerprint(PLAN.encode()), []))

    def test_a_link_named_like_a_document_must_resolve_to_one(self):
        self.write("keys/deploy_key", "not a document")
        (self.home / "notes" / "plan.md").symlink_to(self.home / "keys" / "deploy_key")
        other = self.write("drafts/other.MARKDOWN", PLAN)
        (self.home / "notes" / "other.md").symlink_to(other)
        ask = {"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/notes/plan.md"},
                                               {"do": "S", "file": "~/notes/other.md"}]}
        instructable, docs, notes = self.attach(ask)
        self.assertNotIn("doc", instructable["steps"][0])
        self.assertEqual(instructable["steps"][1]["doc"], fingerprint(PLAN.encode()))
        self.assertEqual(notes, ["steps[0].file not copied to the Pond: not a .md, .markdown or .txt file"])

    def test_a_file_under_a_symlinked_folder_is_attached(self):
        shared = Path(self.tmp.name) / "shared"
        shared.mkdir()
        (shared / "plan.md").write_text(PLAN)
        (self.home / "linked").symlink_to(shared)
        instructable, docs, notes = self.attach({"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/linked/plan.md"}]})
        self.assertEqual((instructable["steps"][0]["doc"], notes), (fingerprint(PLAN.encode()), []))

    def test_tilde_expands_to_the_home_folder_given(self):
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/notes/plan.md"}]}
        self.assertEqual(self.attach(ask)[1], {fingerprint(PLAN.encode())["sha256"]: PLAN})
        other = Path(self.tmp.name) / "other-home"
        other.mkdir()
        self.assertEqual(rd.attach_docs(ask, home=str(other))[2],
                         ["steps[0].file not copied to the Pond: not on this machine"])
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}):
            self.assertEqual(rd.attach_docs(ask)[1], {fingerprint(PLAN.encode())["sha256"]: PLAN})

    def test_a_relative_path_is_left_to_the_validator(self):
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "R", "file": "notes/plan.md"}, {"do": "S", "file": "~"}]}
        self.assertEqual(self.attach(ask), (ask, {}, []))

    def test_the_same_file_twice_is_sent_once(self):
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "R", "file": "~/notes/plan.md"}],
               "links": [{"label": "Plan", "path": "~/notes/plan.md"},
                         {"label": "Same", "path": str(self.home / "notes" / "plan.md")}]}
        instructable, docs, notes = self.attach(ask)
        self.assertEqual(len(docs), 1)
        self.assertEqual([instructable["steps"][0]["doc"]] + [link["doc"] for link in instructable["links"]],
                         [fingerprint(PLAN.encode())] * 3)

    def test_768_kb_fill_in_document_order(self):
        sizes = {"a": rd.MAX_DOC_BYTES, "b": rd.MAX_DOC_BYTES, "c": 200000, "d": rd.MAX_DOC_BYTES, "e": 60000,
                 "f": 3000}
        for name, size in sizes.items():
            self.write(f"notes/{name}.md", name.encode() * size)
        ask = {"v": 1, "title": "t", "steps": [{"do": n.upper(), "file": f"~/notes/{n}.md"} for n in "abcd"],
               "links": [{"label": n.upper(), "path": f"~/notes/{n}.md"} for n in "ef"]}
        instructable, docs, notes = self.attach(ask)
        attached = [n for n in "abcd" if "doc" in instructable["steps"]["abcd".index(n)]]
        attached += [n for n in "ef" if "doc" in instructable["links"]["ef".index(n)]]
        self.assertEqual(attached, ["a", "b", "c", "e"])
        self.assertEqual(sum(len(t.encode()) for t in docs.values()), 784288)
        self.assertEqual(notes, ["steps[3].file not copied to the Pond: the request is full (768 KB)",
                                 "links[1].path not copied to the Pond: the request is full (768 KB)"])
        self.assertEqual(instructable["steps"][3], ask["steps"][3])

    def test_drop_and_retry_helpers(self):
        self.write("notes/a.md", "A")
        self.write("notes/b.md", "B")
        ask = {"v": 1, "title": "t", "steps": [{"do": "A", "file": "~/notes/a.md"},
                                               {"do": "B", "file": "~/notes/b.md"}],
               "links": [{"label": "A", "path": "~/notes/a.md"}]}
        instructable, docs, _ = self.attach(ask)
        a, b = fingerprint(b"A")["sha256"], fingerprint(b"B")["sha256"]
        secret = rc.Refused(400, "invalid documents", [f"docs.{a}: secret-like value"])
        again = rd.retry_without(secret, instructable, docs)
        self.assertEqual(again[1], {b: "B"})
        self.assertNotIn("doc", again[0]["steps"][0])
        self.assertNotIn("doc", again[0]["links"][0])
        self.assertEqual(again[0]["steps"][1]["doc"], fingerprint(b"B"))
        self.assertEqual(again[2], ["steps[0].file not copied to the Pond: it holds a secret-like value",
                                    "links[0].path not copied to the Pond: it holds a secret-like value"])
        off = rd.retry_without(rc.Refused(409, "documents not enabled"), instructable, docs)
        self.assertEqual((off[0], off[1]), (ask, {}))
        self.assertEqual(off[2][0], "steps[0].file not copied to the Pond: documents are turned off on the Pond")
        self.assertEqual(len(off[2]), 3)
        # A held document stays: the Pond refuses only texts and docs the ask doesn't hold.
        for error, reason in (("documents not enabled", "documents are turned off on the Pond"),
                              ("document store full", "the Pond's document store is full")):
            kept = rd.retry_without(rc.Refused(409, error), instructable, docs, held={a})
            self.assertEqual(kept[1], {})
            self.assertEqual(kept[0]["steps"][0]["doc"], fingerprint(b"A"))
            self.assertEqual(kept[0]["links"][0]["doc"], fingerprint(b"A"))
            self.assertNotIn("doc", kept[0]["steps"][1])
            self.assertEqual(kept[2], [f"steps[1].file not copied to the Pond: {reason}"])
        # Only held documents and no texts: nothing to drop, so the refusal stands.
        held_only = rd.drop_docs(instructable, docs, {b}, rd.OFF)[0]
        for error in ("documents not enabled", "document store full"):
            self.assertIsNone(rd.retry_without(rc.Refused(409, error), held_only, {}, held={a}))
        self.assertEqual(rd.held_hashes({"steps": [{"do": "A", "file": "~/a.md", "doc": fingerprint(b"A")},
                                                   {"do": "B", "file": "~/b.md", "doc": {"sha256": "X", "bytes": 1}}]}),
                         {a})
        for exc in (rc.Refused(400, "invalid documents", [f"docs.{a}: secret-like value",
                                                           "steps[1].doc: no document with this hash"]),
                    rc.Refused(400, "invalid documents", []),
                    rc.Refused(400, "invalid documents", [f"docs.{'c' * 64}: secret-like value"]),
                    rc.Refused(400, "invalid instructable", [f"docs.{a}: secret-like value"]),
                    rc.Refused(409, "stale revision")):
            self.assertIsNone(rd.retry_without(exc, instructable, docs), exc.details)
        self.assertIsNone(rd.retry_without(rc.Refused(409, "documents not enabled"), ask, {}))

    def test_the_body_cap_drops_documents_from_the_end(self):
        # Quotes take two bytes each in JSON, so three full documents make a body over 1 MiB.
        for name in "abc":
            self.write(f"notes/{name}.md", name.encode() + b'"' * (rd.MAX_DOC_BYTES - 1))
        ask = {"v": 1, "title": "t", "steps": [{"do": n, "file": f"~/notes/{n}.md"} for n in "abc"]}
        instructable, docs, notes = self.attach(ask)
        self.assertEqual((len(docs), notes), (3, []))

        def encode(ins, sent):
            return rc.encode_body({"instructable": ins, "docs": sent} if sent else {"instructable": ins})
        instructable, docs, notes = rd.fit_request(instructable, docs, encode)
        self.assertEqual([("doc" in s) for s in instructable["steps"]], [True, False, False])
        self.assertEqual(len(docs), 1)
        self.assertLessEqual(len(encode(instructable, docs)), rd.MAX_REQUEST_BYTES)
        self.assertEqual(notes, ["steps[1].file not copied to the Pond: the request is full (768 KB)",
                                 "steps[2].file not copied to the Pond: the request is full (768 KB)"])


class CurrentTests(HomeBase):
    """A correction or an append keeps the `doc` the ask already holds for an untouched path."""

    def setUp(self):
        super().setUp()
        self.plan = self.write("notes/plan.md", PLAN)
        self.old = fingerprint(PLAN.encode())
        self.current = {"v": 1, "title": "t", "steps": [
            {"do": "Read", "file": "~/notes/plan.md", "doc": self.old, "id": "s1"},
            {"do": "Check", "file": "~/notes/check.md", "id": "s2"}]}

    def test_an_untouched_path_keeps_its_doc_and_is_not_read(self):
        self.plan.write_text("# Plan\n\nChanged on disk.\n")
        ask = rd.strip_docs(self.current)
        with mock.patch.object(rd, "_read", side_effect=AssertionError("read")) as reader:
            instructable, docs, notes = self.attach({"v": 1, "title": "t", "steps": [ask["steps"][0]]},
                                                    current=self.current)
        reader.assert_not_called()
        self.assertEqual((instructable["steps"][0]["doc"], docs, notes), (self.old, {}, []))
        os.unlink(self.plan)    # gone from disk: the ask still keeps what the owner reviewed
        instructable, docs, notes = self.attach(ask, current=self.current)
        self.assertEqual((instructable["steps"][0]["doc"], docs), (self.old, {}))
        self.assertEqual(notes, ["steps[1].file not copied to the Pond: not on this machine"])

    def test_refresh_reads_every_document_again(self):
        changed = "# Plan\n\nChanged on disk.\n"
        self.plan.write_text(changed)
        instructable, docs, notes = self.attach(rd.strip_docs(self.current), current=self.current, refresh=True)
        self.assertEqual(instructable["steps"][0]["doc"], fingerprint(changed.encode()))
        self.assertEqual(docs, {fingerprint(changed.encode())["sha256"]: changed})
        # Unchanged text is sent again too, so a copy the Pond released comes back.
        self.plan.write_text(PLAN)
        _, docs, _ = self.attach(rd.strip_docs(self.current), current=self.current, refresh=True)
        self.assertEqual(docs, {self.old["sha256"]: PLAN})

    def test_a_new_path_and_a_path_without_doc_are_read(self):
        self.write("notes/check.md", "check")
        self.write("notes/new.md", "new")
        ask = rd.strip_docs(self.current)
        ask["steps"].append({"do": "New", "file": "~/notes/new.md"})
        instructable, docs, notes = self.attach(ask, current=self.current)
        self.assertEqual([s["doc"] for s in instructable["steps"]],
                         [self.old, fingerprint(b"check"), fingerprint(b"new")])
        self.assertEqual(sorted(docs.values()), ["check", "new"])

    def test_matching_by_id_then_by_path(self):
        other = fingerprint(b"an older copy")
        current = {"v": 1, "title": "t", "steps": [
            {"do": "A", "file": "~/notes/plan.md", "doc": other, "id": "s1"},
            {"do": "B", "file": "~/notes/plan.md", "doc": self.old, "id": "s2"}],
            "links": [{"label": "L", "path": "~/notes/plan.md", "doc": self.old}]}
        ask = {"v": 1, "title": "t", "steps": [
            {"do": "B", "file": "~/notes/plan.md", "id": "s2"},     # its own id: its own doc
            {"do": "A", "file": "~/notes/plan.md", "id": "s1"},
            {"do": "C", "file": "~/notes/plan.md", "id": "s3"},     # a new id: the first doc for the path
            {"do": "D", "file": "~/notes/plan.md"}],
            "links": [{"label": "L", "path": "~/notes/plan.md"}]}
        with mock.patch.object(rd, "_read", side_effect=AssertionError("read")):
            instructable, docs, notes = self.attach(ask, current=current)
        self.assertEqual([s["doc"] for s in instructable["steps"]], [self.old, other, other, other])
        self.assertEqual(instructable["links"][0]["doc"], other)
        self.assertEqual((docs, notes), ({}, []))

    def test_a_step_that_moved_to_another_file_is_read(self):
        self.write("notes/other.md", "other")
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/other.md", "id": "s1"}]}
        instructable, docs, _ = self.attach(ask, current=self.current)
        self.assertEqual(instructable["steps"][0]["doc"], fingerprint(b"other"))

    def test_a_malformed_served_doc_is_not_reused(self):
        current = {"steps": [{"do": "Read", "file": "~/notes/plan.md", "doc": {"sha256": "A" * 64, "bytes": 3}}]}
        instructable, docs, _ = self.attach(rd.strip_docs(current), current=current)
        self.assertEqual((instructable["steps"][0]["doc"], len(docs)), (self.old, 1))


class DocsPond(AppendPond):
    """A Pond 1.10.0 that takes documents: GET /asks/{id} serves what was last posted or corrected.
    `post_queue` and `amend_queue` answer those routes first, one entry per request."""

    def __init__(self, features=DOC_FEATURES):
        super().__init__(version="1.10.0", features=features)
        self.post_queue = []
        self.amend_queue = []
        self.served = None
        self.rev = (1, H1)

    def __call__(self, req, timeout=None):
        path = urllib.parse.urlsplit(req.full_url).path
        method = req.get_method()
        if method == "POST" and path == "/asks" and self.post_queue:
            self.requests.append(req)
            return self._answer(req, *self.post_queue.pop(0))
        if method == "POST" and path == f"/asks/{ITEM_ID}/amend" and self.amend_queue:
            self.requests.append(req)
            return self._answer(req, *self.amend_queue.pop(0))
        if method == "GET" and path == f"/asks/{ITEM_ID}" and self.served is not None:
            self.requests.append(req)
            return self._answer(req, 200, {"item": {"id": ITEM_ID, "status": "open", "title": "t",
                                                    "payload": {"instructable": self.served},
                                                    "revision": {"rev": self.rev[0], "hash": self.rev[1],
                                                                 "acceptedRev": 1}}, "events": []})
        resp = super().__call__(req, timeout)
        if method == "POST" and path in ("/asks", f"/asks/{ITEM_ID}/amend"):
            self.served = json.loads(req.data)["instructable"]
            if path != "/asks":
                self.rev = (2, H2)
        return resp


class ClientDocsBase(HomeBase):
    def setUp(self):
        super().setUp()
        self.http = DocsPond()
        self.keys_patch = mock.patch.object(rc.secrets, "token_urlsafe", lambda n: KEY)
        self.keys_patch.start()
        self.addCleanup(self.keys_patch.stop)

    def client(self, http=None):
        cfg = {"mailboxURL": "https://pond.example.test/", "tokenFile": str(self.dir / "mailbox-token"),
               "context": "work"}
        return rc.Client(cfg, env=self.env, urlopen=http or self.http)

    def bodies(self, path, http=None):
        return [json.loads(r.data) for r in (http or self.http).sent(path)]

    def raw(self, path, http=None):
        return [r.data for r in (http or self.http).sent(path)]

    def posted(self):
        """Posts an ask whose step 1 carries the document PLAN; the Pond then serves it with ids."""
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md"}, {"do": "Say"}]}
        self.client().post("Example", ask)
        served = copy.deepcopy(self.http.served)
        for i, step in enumerate(served["steps"]):
            step["id"] = f"s{i + 1}"
        self.http.served = served
        return ask


class ClientDocsTests(ClientDocsBase):
    def write_bytes_ask_files(self):
        for rel in ("notes/plan.md", "notes/n.txt", "notes/more.md", "notes/next.md"):
            self.write(rel, "caf\u00e9 " + rel)

    # --- the feature absent, or This Mac: the request is what it was ---

    def test_without_the_feature_the_requests_are_byte_identical(self):
        self.write_bytes_ask_files()
        # The same fake Pond the bodies were recorded against: Pond 1.9.0, no `docs` in features.
        http = AppendPond(version="1.9.0", features=["corrections", "appendSteps"])
        client = self.client(http)
        for ask in (BYTES_ASK, with_docs(BYTES_ASK)):
            res = client.post("Example", ask)
            self.assertEqual(self.raw("/asks", http)[-1].decode("ascii"), RECORDED["post"])
            self.assertNotIn("notes", res)
            res = client.amend(ITEM_ID, "Point at the notes", ask, base_rev=1)
            self.assertEqual(self.raw(f"/asks/{ITEM_ID}/amend", http)[-1].decode("ascii"), RECORDED["amend"])
            self.assertNotIn("notes", res)
        for steps in (BYTES_STEPS, with_docs({"steps": BYTES_STEPS})["steps"]):
            res = client.append(ITEM_ID, "One more part", steps)
            self.assertEqual(self.raw(f"/asks/{ITEM_ID}/append", http)[-1].decode("ascii"), RECORDED["append"])
            self.assertNotIn("notes", res)
        # A Pond with no `features` list at all.
        rc._ponds.clear()
        bare = AppendPond(version="1.9.0", features=None)
        res = self.client(bare).post("Example", with_docs(BYTES_ASK))
        self.assertEqual(self.raw("/asks", bare)[-1].decode("ascii"), RECORDED["post"])
        self.assertNotIn("notes", res)

    def test_this_mac_never_attaches(self):
        self.write_bytes_ask_files()
        local = FakeHTTP()
        local.routes[("GET", "/version")] = (200, {"service": "hook", "version": "1.0.0", "protocol": 4,
                                                   "features": ["docs"]})
        local.routes[("POST", "/asks")] = (201, {"item": {"id": ITEM_ID}})
        client = rc.Client({"source": "local", "port": 47911}, env=self.env, urlopen=local)
        for ask in (BYTES_ASK, with_docs(BYTES_ASK)):
            res = client.post("Example", ask)
            self.assertEqual(local.sent("/asks")[-1].data.decode("ascii"), RECORDED["local"])
            self.assertNotIn("notes", res)

    # --- the feature listed ---

    def test_post_attaches_and_sends_utf8(self):
        text = "# Pläne – 日本\n"
        self.write("notes/plan.md", text)
        ask = {"v": 1, "title": "Review the plan", "from": {"host": "mac", "cwd": "/w"},
               "steps": [{"do": "Read the plan", "file": "~/notes/plan.md"}]}
        res = self.client().post("Example", ask)
        self.assertNotIn("notes", res)
        (body,) = self.bodies("/asks")
        fp = fingerprint(text.encode("utf-8"))
        self.assertEqual(body["instructable"]["steps"][0]["doc"], fp)
        self.assertEqual(body["docs"], {fp["sha256"]: text})
        self.assertEqual(list(body), ["project", "instructable", "context", "editKeyHash", "docs"])
        raw = self.raw("/asks")[0]
        self.assertIn(text.encode("utf-8").replace(b"\n", b"\\n"), raw)
        self.assertNotIn(b"\\u00e4", raw)
        self.assertEqual(len(self.http.sent("/version")), 1)

    def test_post_without_any_path_is_unchanged(self):
        ask = {"v": 1, "title": "Prüfe", "from": {"host": "mac", "cwd": "/w"}, "steps": [{"do": "Run it"}]}
        self.client().post("Example", ask)
        self.assertEqual(self.raw("/asks")[0], json.dumps(json.loads(self.raw("/asks")[0])).encode())
        self.assertNotIn("docs", self.bodies("/asks")[0])

    def test_skipped_documents_still_post_with_notes(self):
        (self.home / "notes" / "folder.md").mkdir()
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/folder.md"},
                                               {"do": "Plan", "file": "~/notes/plan.md"}],
               "links": [{"label": "Gone", "path": "~/notes/gone.md"}]}
        res = self.client().post("Example", ask)
        self.assertEqual(res["notes"], ["steps[0].file not copied to the Pond: not a file",
                                        "links[0].path not copied to the Pond: not on this machine"])
        (body,) = self.bodies("/asks")
        self.assertNotIn("doc", body["instructable"]["steps"][0])
        self.assertNotIn("doc", body["instructable"]["links"][0])
        self.assertEqual(body["instructable"]["steps"][1]["doc"], fingerprint(PLAN.encode()))

    def test_nothing_attached_sends_no_docs_member(self):
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/gone.md"}]}
        res = self.client().post("Example", ask)
        self.assertEqual(len(res["notes"]), 1)
        self.assertNotIn("docs", self.bodies("/asks")[0])

    def test_secret_like_text_is_dropped_and_sent_once_more(self):
        self.write("notes/a.md", "A")
        self.write("notes/b.md", "B")
        a = fingerprint(b"A")["sha256"]
        self.http.post_queue.append((400, {"error": "invalid documents", "details": [f"docs.{a}: secret-like value"]}))
        ask = {"v": 1, "title": "t", "steps": [{"do": "A", "file": "~/notes/a.md"}, {"do": "B", "file": "~/notes/b.md"}]}
        res = self.client().post("Example", ask)
        first, second = self.bodies("/asks")
        self.assertEqual(set(first["docs"]), {a, fingerprint(b"B")["sha256"]})
        self.assertEqual(second["docs"], {fingerprint(b"B")["sha256"]: "B"})
        self.assertNotIn("doc", second["instructable"]["steps"][0])
        self.assertEqual(res["notes"], ["steps[0].file not copied to the Pond: it holds a secret-like value"])
        self.assertEqual(res["item"]["id"], ITEM_ID)

    def test_never_a_third_time(self):
        self.write("notes/a.md", "A")
        self.write("notes/b.md", "B")
        a, b = fingerprint(b"A")["sha256"], fingerprint(b"B")["sha256"]
        self.http.post_queue += [(400, {"error": "invalid documents", "details": [f"docs.{a}: secret-like value"]}),
                                 (400, {"error": "invalid documents", "details": [f"docs.{b}: secret-like value"]})]
        ask = {"v": 1, "title": "t", "steps": [{"do": "A", "file": "~/notes/a.md"}, {"do": "B", "file": "~/notes/b.md"}]}
        with self.assertRaises(rc.Refused) as ctx:
            self.client().post("Example", ask)
        self.assertEqual(ctx.exception.details, [f"docs.{b}: secret-like value"])
        self.assertEqual(len(self.http.sent("/asks")), 2)

    def test_another_400_is_reported_and_not_retried(self):
        self.write("notes/a.md", "A")
        a = fingerprint(b"A")["sha256"]
        details = [f"docs.{a}: secret-like value", "steps[0].doc.bytes: does not match the document"]
        self.http.post_queue.append((400, {"error": "invalid documents", "details": details}))
        with self.assertRaises(rc.Refused) as ctx:
            self.client().post("Example", {"v": 1, "title": "t", "steps": [{"do": "A", "file": "~/notes/a.md"}]})
        self.assertEqual((ctx.exception.status, ctx.exception.error, ctx.exception.details),
                         (400, "invalid documents", details))
        self.assertEqual(len(self.http.sent("/asks")), 1)

    def test_documents_turned_off_sends_once_more_without_any(self):
        self.write("notes/a.md", "A")
        self.http.post_queue.append((409, {"error": "documents not enabled"}))
        ask = {"v": 1, "title": "t", "from": {"host": "mac", "cwd": "/w"},
               "steps": [{"do": "A", "file": "~/notes/a.md"}], "links": [{"label": "A", "path": "~/notes/a.md"}]}
        res = self.client().post("Example", ask)
        first, second = self.bodies("/asks")
        self.assertIn("docs", first)
        self.assertEqual(second["instructable"], ask)
        self.assertNotIn("docs", second)
        self.assertEqual(res["notes"], ["steps[0].file not copied to the Pond: documents are turned off on the Pond",
                                        "links[0].path not copied to the Pond: documents are turned off on the Pond"])
        self.http.post_queue += [(409, {"error": "documents not enabled"}), (409, {"error": "documents not enabled"})]
        with self.assertRaises(rc.Refused):
            self.client().post("Example", dict(ask, title="u"))
        self.assertEqual(len(self.http.sent("/asks")), 4)

    def test_the_request_cap_holds(self):
        for name in "abc":
            self.write(f"notes/{name}.md", name.encode() + b'"' * (rd.MAX_DOC_BYTES - 1))
        ask = {"v": 1, "title": "t", "steps": [{"do": n, "file": f"~/notes/{n}.md"} for n in "abc"]}
        res = self.client().post("Example", ask)
        (raw,) = self.raw("/asks")
        self.assertLessEqual(len(raw), rd.MAX_REQUEST_BYTES)
        self.assertEqual(len(json.loads(raw)["docs"]), 1)
        self.assertEqual(res["notes"], ["steps[1].file not copied to the Pond: the request is full (768 KB)",
                                        "steps[2].file not copied to the Pond: the request is full (768 KB)"])

    # --- corrections and appends ---

    def test_a_correction_keeps_the_doc_of_a_document_edited_on_disk(self):
        ask = self.posted()
        self.write("notes/plan.md", "# Plan\n\nEdited after the post.\n")
        fixed = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md", "id": "s1"},
                                                 {"do": "Say it", "id": "s2"}]}
        res = self.client().amend(ITEM_ID, "Say it plainly", fixed)
        self.assertNotIn("notes", res)
        (body,) = self.bodies(f"/asks/{ITEM_ID}/amend")
        self.assertEqual(body["instructable"]["steps"][0]["doc"], fingerprint(PLAN.encode()))
        self.assertNotIn("docs", body)
        self.assertTrue(ask)

    def test_a_correction_with_refresh_sends_the_new_text(self):
        self.posted()
        edited = "# Plan\n\nEdited after the post.\n"
        self.write("notes/plan.md", edited)
        fixed = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md", "id": "s1"},
                                                 {"do": "Say", "id": "s2"}]}
        self.client().amend(ITEM_ID, "The plan changed", fixed, refresh_docs=True)
        (body,) = self.bodies(f"/asks/{ITEM_ID}/amend")
        self.assertEqual(body["instructable"]["steps"][0]["doc"], fingerprint(edited.encode()))
        self.assertEqual(body["docs"], {fingerprint(edited.encode())["sha256"]: edited})

    def test_a_correction_sent_back_from_status_keeps_its_doc(self):
        self.posted()
        self.write("notes/plan.md", "edited")
        served = copy.deepcopy(self.http.served)
        served["steps"][0]["doc"] = {"sha256": "e" * 64, "bytes": 9}    # whatever the session sends back
        self.client().amend(ITEM_ID, "Same plan", served)
        (body,) = self.bodies(f"/asks/{ITEM_ID}/amend")
        self.assertEqual(body["instructable"]["steps"][0]["doc"], fingerprint(PLAN.encode()))

    def test_a_correction_retries_on_documents_turned_off(self):
        self.posted()
        self.write("notes/new.md", "new")
        self.http.amend_queue.append((409, {"error": "documents not enabled"}))
        fixed = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md", "id": "s1"},
                                                 {"do": "New", "file": "~/notes/new.md"}]}
        res = self.client().amend(ITEM_ID, "One more", fixed)
        first, second = self.bodies(f"/asks/{ITEM_ID}/amend")
        self.assertEqual(first["docs"], {fingerprint(b"new")["sha256"]: "new"})
        self.assertEqual(second["instructable"]["steps"][0]["doc"], fingerprint(PLAN.encode()))
        self.assertEqual(second["instructable"]["steps"][1], fixed["steps"][1])
        self.assertNotIn("docs", second)
        self.assertEqual(res["notes"], ["steps[1].file not copied to the Pond: documents are turned off on the Pond"])

    def test_a_full_document_store_keeps_held_documents_once_more(self):
        self.posted()
        self.write("notes/new.md", "new")
        full = (409, {"error": "document store full"})
        self.http.amend_queue.append(full)
        fixed = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md", "id": "s1"},
                                                 {"do": "New", "file": "~/notes/new.md"}]}
        res = self.client().amend(ITEM_ID, "One more", fixed)
        first, second = self.bodies(f"/asks/{ITEM_ID}/amend")
        self.assertIn("docs", first)
        self.assertEqual(second["instructable"]["steps"][0]["doc"], fingerprint(PLAN.encode()))
        self.assertNotIn("doc", second["instructable"]["steps"][1])
        self.assertNotIn("docs", second)
        self.assertEqual(res["notes"], ["steps[1].file not copied to the Pond: the Pond's document store is full"])
        # A new ask holds nothing: every doc goes. Never a third request.
        self.write("notes/a.md", "A")
        self.http.post_queue += [full, full]
        with self.assertRaises(rc.Refused) as ctx:
            self.client().post("Example", {"v": 1, "title": "u", "steps": [{"do": "A", "file": "~/notes/a.md"}]})
        self.assertEqual(ctx.exception.error, "document store full")
        posts = self.bodies("/asks")
        self.assertEqual(len(posts), 3)    # the setUp post, then exactly two
        self.assertNotIn("doc", posts[-1]["instructable"]["steps"][0])
        self.assertNotIn("docs", posts[-1])

    def test_an_append_keeps_held_documents_when_documents_are_off(self):
        self.posted()
        self.write("notes/next.md", "next")
        self.http.queue.append((409, {"error": "documents not enabled"}))
        steps = [{"do": "Reread", "file": "~/notes/plan.md"}, {"do": "Next", "file": "~/notes/next.md"}]
        res = self.client().append(ITEM_ID, "Two more", steps)
        first, second = self.bodies(f"/asks/{ITEM_ID}/append")
        self.assertIn("docs", first)
        self.assertEqual([s.get("doc") for s in second["steps"]], [fingerprint(PLAN.encode()), None])
        self.assertNotIn("docs", second)
        self.assertEqual(res["notes"], ["steps[1].file not copied to the Pond: documents are turned off on the Pond"])

    def test_an_append_reuses_a_held_doc_and_reads_a_new_one(self):
        self.posted()
        self.write("notes/plan.md", "edited")
        self.write("notes/next.md", "next")
        steps = [{"do": "Reread", "file": "~/notes/plan.md"}, {"do": "Next", "file": "~/notes/next.md"},
                 {"do": "Gone", "file": "~/notes/gone.md"}]
        res = self.client().append(ITEM_ID, "Two more", steps)
        (body,) = self.bodies(f"/asks/{ITEM_ID}/append")
        self.assertEqual([s.get("doc") for s in body["steps"]],
                         [fingerprint(PLAN.encode()), fingerprint(b"next"), None])
        self.assertEqual(body["docs"], {fingerprint(b"next")["sha256"]: "next"})
        self.assertEqual(res["notes"], ["steps[2].file not copied to the Pond: not on this machine"])
        self.client().append(ITEM_ID, "Again", steps[:1], refresh_docs=True)
        self.assertEqual(self.bodies(f"/asks/{ITEM_ID}/append")[-1]["docs"], {fingerprint(b"edited")["sha256"]: "edited"})


class CliDocsTests(ClientDocsBase):
    def run_cli(self, *argv, stdin):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(list(argv), stdin=io.StringIO(json.dumps(stdin)), stdout=out, stderr=err,
                              env=self.env, client_factory=lambda **kw: self.client())
        return code, out.getvalue(), err.getvalue()

    def test_notes_go_to_stderr_one_line_each(self):
        self.write("notes/plan.md", PLAN)
        ask = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md"},
                                               {"do": "B", "substeps": [{"do": "B1", "file": "~/notes/x.pdf"}]}],
               "links": [{"label": "Gone", "path": "~/notes/gone.md"}]}
        code, out, err = self.run_cli("post", "Example", "--json", "-", stdin=ask)
        self.assertEqual((code, out), (0, f"posted {ITEM_ID}\n"))
        self.assertEqual(err, "note: steps[1].substeps[0].file not copied to the Pond: not a .md, .markdown or .txt file\n"
                              "note: links[0].path not copied to the Pond: not on this machine\n")

    def test_amend_and_append_take_refresh_docs(self):
        self.posted()
        self.write("notes/plan.md", "edited")
        fixed = {"v": 1, "title": "t", "steps": [{"do": "Read", "file": "~/notes/plan.md", "id": "s1"},
                                                 {"do": "Say", "id": "s2"}]}
        code, _, err = self.run_cli("amend", ITEM_ID, "--reason", "The plan changed", "--refresh-docs", stdin=fixed)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.bodies(f"/asks/{ITEM_ID}/amend")[-1]["docs"], {fingerprint(b"edited")["sha256"]: "edited"})
        steps = [{"do": "Reread", "file": "~/notes/plan.md"}, {"do": "Gone", "file": "~/notes/gone.md"}]
        code, _, err = self.run_cli("append", ITEM_ID, "--note", "More", "--refresh-docs", stdin=steps)
        self.assertEqual((code, err), (0, "note: steps[1].file not copied to the Pond: not on this machine\n"))
        self.assertIn("docs", self.bodies(f"/asks/{ITEM_ID}/append")[-1])
        code, _, _ = self.run_cli("append", ITEM_ID, "--note", "More", stdin=steps[:1])
        self.assertNotIn("docs", self.bodies(f"/asks/{ITEM_ID}/append")[-1])
