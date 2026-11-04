"""relay_lint against clients/lint-vectors.json (other clients test their copies against the same
file), and `relay post` / Client.post refusing a value left in a step's do. Stdlib only."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path

import relay_cli
import relay_client as rc
import relay_lint
from test_relay_client import ITEM_ID, MAILBOX_TOKEN, FakeHTTP

VECTORS = Path(__file__).resolve().with_name("lint-vectors.json")
FILE = json.loads(VECTORS.read_text("utf-8"))
CASES = FILE["cases"]

# A whole reader form crammed into do (step 4), and the same ask with one sub-step per field.
CRAMMED = {"v": 1, "title": "Set up the email reader", "steps": [
    {"do": "Open the app", "url": "https://app.example.com/app/"},
    {"do": "Sign in with your household account"},
    {"do": "Go to Settings"},
    {"do": "Settings page, Readers: tap Add reader. Kind Ollama, Name studio, URL http://100.64.0.7:11434, "
           "Model qwen2.5:14b-instruct; leave the rest. Tap Add, then Check now. Open the app at "
           "https://app.example.com/app/ from home or the tailnet"}]}
CRAMMED_DETAIL = ('steps[3].do: "http://100.64.0.7:11434", "qwen2.5:14b-instruct", "https://app.example.com/app/" '
                  "are values to copy: put each in a sub-step's code (or a URL in url)")
REWRITTEN = {"v": 1, "title": "Set up the email reader", "steps": [
    {"do": "Sign in with your household account"},
    {"do": "Add a reader: Settings › Readers › Add reader", "url": "https://app.example.com/app/",
     "substeps": [
         {"do": "Kind", "code": "Ollama", "lang": "text"},
         {"do": "Name", "code": "studio", "lang": "text"},
         {"do": "URL", "code": "http://100.64.0.7:11434", "lang": "text"},
         {"do": "Model", "code": "qwen2.5:14b-instruct", "lang": "text"},
         {"do": "Tap Add, then Check now", "expect": "The studio card shows Ready"}]}]}


class VectorTests(unittest.TestCase):
    def test_the_file_is_whole(self):
        self.assertEqual(FILE["version"], 1)
        self.assertGreaterEqual(len(CASES), 30)
        names = [c["name"] for c in CASES]
        self.assertEqual(len(set(names)), len(names))
        flagged = [c for c in CASES if c["expect"]]
        self.assertGreaterEqual(len(flagged), 10)
        self.assertGreaterEqual(len(CASES) - len(flagged), 10)

    def test_every_vector(self):
        for case in CASES:
            with self.subTest(case["name"]):
                got = [list(p) for p in relay_lint.lint_instructable(case["instructable"])]
                self.assertEqual(got, case["expect"])

    def test_requirement_vectors_hold_the_five_guidance_lines(self):
        cases = [c for c in CASES if c["name"].startswith(("required-", "done-"))]
        self.assertGreaterEqual(len(cases), 15)
        lines = {tuple(pair) for c in cases for pair in c["expect"]}
        self.assertLessEqual({
            ("steps[2].required", "has nothing to finish: every sub-step is optional. Drop required, "
                                  "or make a sub-step one the owner must do"),
            ("steps[2].required", "can't go with optional: drop one of them"),
            ("steps[2].substeps[0].required", "can't be required inside an optional step"),
            ("done", "\"reply\" needs a reply prompt: add reply, or drop it from done"),
            ("done", "\"steps\" has nothing to finish: every step is optional"),
        }, lines)
        for case in cases:
            with self.subTest(case["name"]):
                got = [list(p) for p in relay_lint.lint_requirements(case["instructable"])]
                self.assertEqual(got, [p for p in case["expect"] if not p[0].endswith(".do")])

    def test_lint_vectors(self):
        # Pond 1.4.0: a string choice that asks for words in its label ("Mix (reply what)").
        cases = {c["name"]: c for c in CASES if c["name"].startswith("choice-")}
        self.assertLessEqual({"choice-reply-label", "choice-reply-label-question", "choice-reply-word-plain",
                              "choice-object-ok"}, set(cases))
        self.assertEqual(cases["choice-reply-label"]["expect"], [[
            "reply.choices[1]",
            '"Mix (reply what)" asks for words: make it {"label": "Mix", "text": "…"} (Pond 1.4.0), '
            "or say what to write in the prompt"]])
        for name, case in cases.items():
            with self.subTest(name):
                got = [list(p) for p in relay_lint.lint_choice_labels(case["instructable"])]
                self.assertEqual(got, [p for p in case["expect"] if ".choices[" in p[0]])

    def test_choice_pairs_come_after_the_requirements(self):
        doc = {"v": 1, "title": "x", "done": ["reply"], "steps": [
            {"do": "Go", "question": {"prompt": "How?", "choices": ["Keep", "Changes (reply)"]}}]}
        self.assertEqual([p[0] for p in relay_lint.lint_instructable(doc)], ["done", "steps[0].question.choices[1]"])
        self.assertEqual(relay_lint.lint_choice_labels(doc)[0][1],
                         '"Changes (reply)" asks for words: make it {"label": "Changes", "text": "…"} (Pond 1.4.0), '
                         "or say what to write in the prompt")

    def test_requirement_pairs_come_after_the_values_to_copy(self):
        doc = {"v": 1, "title": "x", "done": ["reply"],
               "steps": [{"do": "Go", "required": True, "optional": True}, {"do": "Open https://example.com/a"}]}
        self.assertEqual([p[0] for p in relay_lint.lint_instructable(doc)], ["steps[1].do", "steps[0].required", "done"])

    def test_requirement_shapes_are_left_to_the_validator(self):
        for doc in ({"v": 1, "title": "x", "steps": [{"do": "a", "required": "yes", "optional": True}]},
                    {"v": 1, "title": "x", "steps": [{"do": "a"}], "done": "reply"},
                    {"v": 1, "title": "x", "steps": [{"do": "a"}], "done": [], },
                    {"v": 1, "title": "x", "steps": [{"do": "a"}], "done": ["later", 3, None]},
                    {"v": 1, "title": "x", "steps": [{"do": "a", "substeps": []}], "verify": {"do": "b", "required": True}},
                    {"v": 1, "title": "x", "steps": [{"do": "a", "required": True, "substeps": []}]}):
            with self.subTest(doc):
                self.assertEqual(relay_lint.lint_requirements(doc), [])

    def test_a_duplicate_done_entry_is_linted_once(self):
        doc = {"v": 1, "title": "x", "steps": [{"do": "a"}], "done": ["reply", "reply"]}
        self.assertEqual(relay_lint.lint_requirements(doc),
                         [("done", "\"reply\" needs a reply prompt: add reply, or drop it from done")])

    def test_the_messages_say_what_to_do(self):
        self.assertEqual(relay_lint.lint_details(CRAMMED), [CRAMMED_DETAIL])
        self.assertEqual(relay_lint.lint_details(REWRITTEN), [])

    def test_bad_shapes_are_left_to_the_validator(self):
        for doc in (None, [], {"steps": "x"}, {"steps": [5, {"do": 7}, {"do": "x", "substeps": "y"}]},
                    {"steps": [], "verify": "Open https://example.com"}):
            with self.subTest(doc):
                self.assertEqual(relay_lint.lint_instructable(doc), [])


class PostRefusalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "mailbox-token").write_text(MAILBOX_TOKEN + "\n")
        self.cfg = {"mailboxURL": "https://mailbox.example/", "tokenFile": str(root / "mailbox-token"),
                    "context": "work"}
        self.env = {"RELAY_CONFIG": str(root / "config.json"), "CLAUDE_SESSION_ID": "test-session",
                    "RELAY_EDIT_KEY_DIR": str(root / "edit-keys")}
        rc._ponds.clear()
        self.addCleanup(rc._ponds.clear)
        self.http = FakeHTTP()
        self.http.routes[("GET", "/version")] = (200, {"version": "1.1.0"})
        self.http.routes[("POST", "/asks")] = (201, {"item": {"id": ITEM_ID}})

    def client(self, **_kw):
        return rc.Client(self.cfg, env=self.env, urlopen=self.http)

    def test_a_crammed_step_is_refused_before_anything_is_sent(self):
        with self.assertRaises(rc.Refused) as ctx:
            self.client().post("Acme", CRAMMED)
        self.assertEqual((ctx.exception.status, ctx.exception.error), (400, "invalid instructable"))
        self.assertEqual(ctx.exception.details, [CRAMMED_DETAIL])
        self.assertEqual(self.http.requests, [])

    def test_its_sub_step_rewrite_posts(self):
        self.assertEqual(self.client().post("Acme", REWRITTEN)["item"]["id"], ITEM_ID)
        self.assertEqual(len(self.http.sent("/asks")), 1)

    def test_relay_post_prints_it_like_a_field_error(self):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(["post", "Acme", "--json", "-"], stdin=io.StringIO(json.dumps(CRAMMED)),
                              stdout=out, stderr=err, env=self.env, client_factory=self.client, prog="relay")
        self.assertEqual((code, out.getvalue(), err.getvalue()),
                         (1, "", f"refused: invalid instructable\n  {CRAMMED_DETAIL}\n"))
        self.assertEqual(self.http.requests, [])

    def test_relay_post_posts_the_rewrite(self):
        out, err = io.StringIO(), io.StringIO()
        code = relay_cli.main(["post", "Acme", "--json", "-"], stdin=io.StringIO(json.dumps(REWRITTEN)),
                              stdout=out, stderr=err, env=self.env, client_factory=self.client, prog="relay")
        self.assertEqual((code, out.getvalue(), err.getvalue()), (0, f"posted {ITEM_ID}\n", ""))


if __name__ == "__main__":
    unittest.main()
