"""The format-preserving config editors: JSON/JSONC splices, Hook-owned TOML and YAML blocks,
Markdown marker blocks, backups and atomic writes. Standard library only."""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

import relay_edits as ed

PATH = ["mcpServers", "relay"]
SERVER = {"command": "/Users/me/.local/bin/relay", "args": ["mcp"], "env": {}}

JSON_INPUTS = {
    "empty": "",
    "braces": "{}",
    "braces_nl": "{}\n",
    "members": '{\n  "a": 1,\n  "b": [1, 2]\n}\n',
    "trailing_comma": '{\n  "a": 1,\n}\n',
    "comments": '// top\n{\n  /* first */\n  "a": 1\n  // after a\n}\n// end\n',
    "inline_comment": '{\n  "a": 1 // the a\n}\n',
    "crlf": '{\r\n  "a": 1\r\n}\r\n',
    "bom": '﻿{\n    "a": true\n}',
    "nested_parent": '{\n\t"mcpServers": {\n\t\t"other": {"command": "x"}\n\t}\n}\n',
    "empty_parent": '{\n  "mcpServers": {}\n}\n',
    "one_line": '{"a": 1}',
    "url_string": '{\n  "url": "http://x/*y*/ // z",\n  "a": 1\n}\n',
    "crlf_comment_bom": '\ufeff{\r\n  "a": 1, // c\r\n  /* d */\r\n}\r\n',
    "zed_like": '// Zed settings\n{\n  "theme": "One Dark",\n  "context_servers": {\n    // mine\n  },\n}\n',
    "duplicate_elsewhere": '{\n  "x": 1,\n  "x": 2\n}\n',
}


def is_hook_replies(element):
    return isinstance(element, dict) and "hook replies" in str(element.get("command", ""))


class JSONCTests(unittest.TestCase):
    def test_loads_jsonc_reads_comments_and_trailing_commas(self):
        text = '// c\n{ /* x */ "a": [1, 2,], "b": {"c": "//not a comment",}, }\n'
        self.assertEqual(ed.loads_jsonc(text), {"a": [1, 2], "b": {"c": "//not a comment"}})
        self.assertEqual(ed.loads_jsonc('﻿{"a": null}'), {"a": None})

    def test_set_exact_outputs(self):
        cases = [
            ("", '{\n  "k": 2\n}\n'),
            ("{}", '{\n  "k": 2\n}'),
            ('{\n  "a": 1,\n}\n', '{\n  "a": 1,\n  "k": 2,\n}\n'),
            ('{\n  "a": 1 // the a\n}\n', '{\n  "a": 1, // the a\n  "k": 2\n}\n'),
            ('{\r\n  "a": 1\r\n}\r\n', '{\r\n  "a": 1,\r\n  "k": 2\r\n}\r\n'),
            ('﻿{\n    "a": true\n}', '﻿{\n    "a": true,\n    "k": 2\n}'),
        ]
        for old, new in cases:
            with self.subTest(old=old):
                self.assertEqual(ed.json_set(old, ["k"], 2), new)

    def test_set_nested_value_is_indented_to_the_member(self):
        old = '{\n  "a": 1,\n  "b": [1, 2]\n}\n'
        new = ed.json_set(old, PATH, {"command": "x"})
        self.assertEqual(
            new,
            '{\n  "a": 1,\n  "b": [1, 2],\n  "mcpServers": {\n    "relay": {\n'
            '      "command": "x"\n    }\n  }\n}\n',
        )

    def test_set_into_an_existing_parent_uses_its_indent(self):
        new = ed.json_set(JSON_INPUTS["nested_parent"], PATH, {"command": "y"})
        self.assertIn('\t\t"other": {"command": "x"},\n\t\t"relay": {\n\t\t\t"command": "y"\n\t\t}\n\t}', new)

    def test_set_every_input_reads_back_and_keeps_the_rest(self):
        for name, old in JSON_INPUTS.items():
            with self.subTest(name):
                new = ed.json_set(old, PATH, SERVER)
                self.assertEqual(ed.json_get(new, PATH), (True, SERVER))
                if old.strip():
                    before = ed.loads_jsonc(old)
                    after = ed.loads_jsonc(new)
                    after["mcpServers"].pop("relay")
                    if not after["mcpServers"] and "mcpServers" not in before:
                        after.pop("mcpServers")
                    self.assertEqual(after, before)
                self.assertEqual(new.startswith("﻿"), old.startswith("﻿"))
                self.assertEqual(new.endswith("\n"), old.endswith("\n") or not old.strip())
                if "\r\n" in old:
                    self.assertNotIn("\n", new.replace("\r\n", ""))

    def test_set_then_delete_is_byte_identical(self):
        for name, old in JSON_INPUTS.items():
            with self.subTest(name):
                made = ed.json_missing_containers(old, PATH)
                new = ed.json_set(old, PATH, SERVER)
                self.assertEqual(ed.json_delete(new, PATH, prune=made), old)

    def test_missing_containers(self):
        self.assertEqual(ed.json_missing_containers("", PATH), 2)
        self.assertEqual(ed.json_missing_containers("{}", PATH), 1)
        self.assertEqual(ed.json_missing_containers('{"mcpServers": {}}', PATH), 0)
        self.assertEqual(ed.json_missing_containers('{"hooks": {}}', ["hooks", "Stop"], append=True), 1)

    def test_replace_an_existing_value_only(self):
        old = '{\n  "a": 1, // c\n  "b": {"x": [1]} /* keep */\n}'
        self.assertEqual(ed.json_set(old, ["a"], 5), '{\n  "a": 5, // c\n  "b": {"x": [1]} /* keep */\n}')
        self.assertEqual(ed.json_set(old, ["b", "x"], [2, 3]),
                         '{\n  "a": 1, // c\n  "b": {"x": [\n    2,\n    3\n  ]} /* keep */\n}')

    def test_strings_holding_comment_markers_survive(self):
        old = JSON_INPUTS["url_string"]
        new = ed.json_set(old, ["k"], "a // b /* c */")
        self.assertEqual(ed.loads_jsonc(new)["url"], "http://x/*y*/ // z")
        self.assertEqual(ed.json_get(new, ["k"]), (True, "a // b /* c */"))

    def test_duplicate_keys_on_the_path_are_refused(self):
        for text, path in [('{"a": 1, "a": 2}', ["a"]), ('{"m": {}, "m": {}}', ["m", "x"]),
                           ('{"m": {"x": 1, "x": 2}}', ["m", "x"])]:
            with self.subTest(text):
                with self.assertRaises(ed.EditError):
                    ed.json_set(text, path, 1)
                with self.assertRaises(ed.EditError):
                    ed.json_delete(text, path)

    def test_a_duplicate_off_the_path_is_left_alone(self):
        new = ed.json_set(JSON_INPUTS["duplicate_elsewhere"], ["k"], 1)
        self.assertEqual(new, '{\n  "x": 1,\n  "x": 2,\n  "k": 1\n}\n')

    def test_parse_errors(self):
        for text in ['{"a": "abc}', '{"a": 1}}', '{"a": [1, 2', '{"a" 1}', '{"a": 1', '{,}',
                     '{"a": tru}', '{"a": 01}', '{"a": "x\ny"}', '/* open {"a": 1}']:
            with self.subTest(text):
                with self.assertRaises(ed.ParseError):
                    ed.loads_jsonc(text)
                with self.assertRaises(ed.ParseError):
                    ed.json_set(text, ["k"], 1)

    def test_a_root_or_parent_that_is_not_an_object_is_refused(self):
        with self.assertRaises(ed.EditError):
            ed.json_set("[1]", ["k"], 1)
        with self.assertRaises(ed.EditError):
            ed.json_set('{"m": 1}', ["m", "x"], 1)

    def test_get_and_delete_of_a_missing_path(self):
        self.assertEqual(ed.json_get("", PATH), (False, None))
        self.assertEqual(ed.json_get('{"mcpServers": {}}', PATH), (False, None))
        old = '{"a": 1}\n'
        self.assertEqual(ed.json_delete(old, PATH), old)

    def test_delete_a_middle_member(self):
        old = '{\n  "a": 1,\n  "b": 2,\n  "c": 3\n}\n'
        self.assertEqual(ed.json_delete(old, ["b"]), '{\n  "a": 1,\n  "c": 3\n}\n')

    def test_append_is_idempotent_and_remove_matching_is_exact(self):
        old = ('{\n  "hooks": {\n    "UserPromptSubmit": [\n      {"command": "other"}\n'
               '    ]\n  }\n}\n')
        path = ["hooks", "UserPromptSubmit"]
        element = {"command": "relay hook replies --format claude"}
        once = ed.json_append(old, path, element, is_hook_replies)
        self.assertEqual(ed.json_get(once, path), (True, [{"command": "other"}, element]))
        self.assertEqual(ed.json_append(once, path, element, is_hook_replies), once)
        self.assertEqual(ed.json_remove_matching(once, path, is_hook_replies), old)

    def test_append_to_a_missing_array_round_trips(self):
        path = ["hooks", "UserPromptSubmit"]
        element = {"command": "relay hook replies"}
        for name, old in JSON_INPUTS.items():
            with self.subTest(name):
                made = ed.json_missing_containers(old, path, append=True)
                new = ed.json_append(old, path, element, is_hook_replies)
                self.assertEqual(ed.json_get(new, path), (True, [element]))
                self.assertEqual(ed.json_remove_matching(new, path, is_hook_replies, prune=made), old)

    def test_remove_matching_keeps_the_others(self):
        old = '[\n  {"command": "a"},\n  {"command": "relay hook replies"},\n  {"command": "b"}\n]'
        old = '{"x": ' + old + "}"
        new = ed.json_remove_matching(old, ["x"], is_hook_replies)
        self.assertEqual(ed.loads_jsonc(new), {"x": [{"command": "a"}, {"command": "b"}]})

    def test_remove_nested_drops_inner_matches_and_empty_groups(self):
        old = ('{\n  // mine\n  "hooks": {\n    "PreToolUse": [{"hooks": [{"command": "relay replies --new --hook"}]}],\n'
               '    "UserPromptSubmit": [\n'
               '      {"hooks": [{"type": "command", "command": "relay replies --new --hook", "timeout": 5}]},\n'
               '      {"matcher": "x", "hooks": [\n'
               '        {"command": "mine.sh"},\n'
               '        {"command": "hook replies --new --hook"}\n'
               '      ]},\n'
               '    ],\n  },\n  "model": "opus"\n}\n')
        legacy = lambda h: "replies --new" in str(h.get("command", ""))   # noqa: E731
        path = ["hooks", "UserPromptSubmit"]
        new = ed.json_remove_nested(old, path, "hooks", legacy)
        self.assertEqual(ed.json_get(new, path), (True, [{"matcher": "x", "hooks": [{"command": "mine.sh"}]}]))
        self.assertTrue(new.startswith('{\n  // mine\n  "hooks": {\n    "PreToolUse": [{"hooks": [{"command": "relay replies'))
        self.assertTrue(new.endswith('    ],\n  },\n  "model": "opus"\n}\n'))
        self.assertEqual(ed.json_remove_nested(new, path, "hooks", legacy), new)

    def test_remove_nested_drops_the_key_it_emptied_only(self):
        legacy = lambda h: "replies --new" in str(h.get("command", ""))   # noqa: E731
        path = ["hooks", "UserPromptSubmit"]
        old = '{\n  "hooks": {\n    "UserPromptSubmit": [\n      {"hooks": [{"command": "relay replies --new"}]}\n    ]\n  }\n}\n'
        self.assertEqual(ed.json_remove_nested(old, path, "hooks", legacy), '{\n  "hooks": {}\n}\n')
        empty = '{\n  "hooks": {\n    "UserPromptSubmit": []\n  }\n}\n'
        self.assertEqual(ed.json_remove_nested(empty, path, "hooks", legacy), empty)
        self.assertEqual(ed.json_remove_nested("", path, "hooks", legacy), "")
        self.assertEqual(ed.json_remove_nested('{"a": 1}', path, "hooks", legacy), '{"a": 1}')
        with self.assertRaises(ed.ParseError):
            ed.json_remove_nested('{"hooks": ', path, "hooks", legacy)

    def test_append_refuses_a_non_array(self):
        with self.assertRaises(ed.EditError):
            ed.json_append('{"x": {}}', ["x"], 1, lambda e: False)


CODEX = '# my config\nmodel = "o3"\n\n[profiles.fast]\nmodel = "mini"\n\n[[profiles.list]]\nname = "a"\n'
TOML_VALUES = {
    "command": "/Users/me/.local/bin/relay",
    "args": ["mcp", "--quiet"],
    "enabled": True,
    "startup_timeout_sec": 20,
    "env": {"RELAY_NOTE": 'a"b\\c\né'},
}
TABLE = ["mcp_servers", "relay"]


class TOMLTests(unittest.TestCase):
    def set(self, text, values=TOML_VALUES):
        return ed.toml_set_table(text, TABLE, values, "mcp", "0123456789abcdef")

    def test_append_after_an_array_of_tables(self):
        new = self.set(CODEX)
        self.assertTrue(new.startswith(CODEX + "\n# hook:begin id=mcp sha=0123456789abcdef\n[mcp_servers.relay]\n"))
        self.assertTrue(new.endswith("# hook:end\n"))
        self.assertEqual(ed.toml_get_owned(new, "mcp"), TOML_VALUES)
        if ed._tomllib is not None:
            parsed = ed._tomllib.loads(new)
            self.assertEqual(parsed["mcp_servers"]["relay"], TOML_VALUES)
            self.assertEqual(parsed["profiles"]["list"], [{"name": "a"}])

    def test_a_file_without_a_final_newline(self):
        new = self.set('model = "o3"')
        self.assertTrue(new.startswith('model = "o3"\n\n# hook:begin id=mcp sha=0123456789abcdef nonl=1\n'))
        self.assertEqual(ed.toml_get_owned(new, "mcp"), TOML_VALUES)
        self.assertEqual(ed.toml_remove_table(new, "mcp"), 'model = "o3"')       # byte for byte
        again = self.set(new)
        self.assertIn("nonl=1", again)
        self.assertEqual(ed.toml_remove_table(again, "mcp"), 'model = "o3"')

    def test_an_empty_file(self):
        new = self.set("")
        self.assertTrue(new.startswith("# hook:begin id=mcp "))
        self.assertEqual(ed.toml_remove_table(new, "mcp"), "")

    def test_refusals(self):
        for text in [
            '[mcp_servers.relay]\ncommand = "x"\n',
            '[ mcp_servers . "relay" . env ]\nA = "1"\n',
            'mcp_servers = { relay = { command = "x" } }\n',
            'mcp_servers.relay.command = "x"\n',
            '[mcp_servers]\nrelay = { command = "x" }\n',
            'notes = """\n[x]\n',
            "notes = '''\n[x]\n",
        ]:
            with self.subTest(text):
                with self.assertRaises(ed.EditError):
                    self.set(text)

    def test_other_servers_are_fine(self):
        text = '[mcp_servers.other]\ncommand = "x"\n# [mcp_servers.relay] in a comment\n'
        self.assertEqual(ed.toml_get_owned(self.set(text), "mcp"), TOML_VALUES)

    def test_a_second_set_is_idempotent_and_replaces_in_place(self):
        once = self.set(CODEX)
        self.assertEqual(self.set(once), once)
        changed = self.set(once, {"command": "/opt/relay", "args": []})
        self.assertTrue(changed.startswith(CODEX))
        self.assertEqual(ed.toml_get_owned(changed, "mcp"), {"command": "/opt/relay", "args": []})
        self.assertEqual(changed.count("# hook:begin"), 1)

    def test_remove_is_byte_identical(self):
        for text in [CODEX, "", '[a]\nb = 1\n\n']:
            with self.subTest(text):
                self.assertEqual(ed.toml_remove_table(self.set(text), "mcp"), text)
        self.assertEqual(ed.toml_remove_table(CODEX, "mcp"), CODEX)
        self.assertIsNone(ed.toml_get_owned(CODEX, "mcp"))

    def test_block_with_user_lines_after_it(self):
        new = self.set(CODEX) + "\n[later]\nx = 1\n"
        self.assertEqual(ed.toml_remove_table(new, "mcp"), CODEX + "\n[later]\nx = 1\n")

    def test_unsupported_values_are_refused(self):
        with self.assertRaises(ed.EditError):
            self.set("", {"x": 1.5})
        with self.assertRaises(ed.EditError):
            self.set("", {"x": [1]})

    def test_tomllib_cross_check_is_skipped_below_3_11(self):
        self.assertEqual(ed._tomllib is None, sys.version_info < (3, 11))
        with mock.patch.object(ed, "_tomllib", None):
            self.assertEqual(ed.toml_get_owned(self.set('a = = 1\n'), "mcp"), TOML_VALUES)
        if ed._tomllib is not None:
            with self.assertRaises(ed.ParseError):
                self.set('a = = 1\n')

    def test_duplicate_or_open_markers_are_refused(self):
        once = self.set(CODEX)
        with self.assertRaises(ed.EditError):
            self.set(once + once)
        with self.assertRaises(ed.EditError):
            self.set(CODEX + "# hook:begin id=mcp sha=x\n")


GOOSE = (
    "# Goose config\n"
    "GOOSE_PROVIDER: openai\n"
    "extensions:\n"
    "  developer:\n"
    "    bundled: true\n"
    "    enabled: true\n"
    "    name: developer\n"
    "    timeout: 300\n"
    "    type: builtin\n"
    "\n"
    "# model settings\n"
    "GOOSE_MODEL: gpt-4o\n"
)
YAML_VALUE = {
    "type": "stdio",
    "name": "relay",
    "cmd": "/Users/me/.local/bin/relay",
    "args": ["mcp"],
    "envs": {},
    "enabled": True,
    "timeout": 300,
}
GOOSE_BLOCK = (
    "  # hook:begin id=mcp sha=0123456789abcdef\n"
    "  relay:\n"
    '    type: "stdio"\n'
    '    name: "relay"\n'
    '    cmd: "/Users/me/.local/bin/relay"\n'
    "    args:\n"
    '      - "mcp"\n'
    "    envs: {}\n"
    "    enabled: true\n"
    "    timeout: 300\n"
    "  # hook:end\n"
)


class YAMLTests(unittest.TestCase):
    def set(self, text, value=YAML_VALUE):
        return ed.yaml_set_child(text, "extensions", "relay", value, "mcp", "0123456789abcdef")

    def assertRoundTrip(self, text):
        new = self.set(text)
        self.assertEqual(ed.yaml_get_owned(new, "mcp"), YAML_VALUE)
        self.assertEqual(ed.yaml_remove_child(new, "mcp"), text)
        self.assertEqual(self.set(new), new)
        return new

    def test_goose_config_with_comments_and_other_keys(self):
        new = self.assertRoundTrip(GOOSE)
        self.assertEqual(new, GOOSE.replace("    type: builtin\n", "    type: builtin\n" + GOOSE_BLOCK))

    def test_four_space_indent(self):
        text = "extensions:\n    developer:\n        enabled: true\nother: 1\n"
        new = self.assertRoundTrip(text)
        self.assertIn("        enabled: true\n    # hook:begin id=mcp", new)
        self.assertIn('    relay:\n        type: "stdio"\n', new)
        self.assertIn('        args:\n            - "mcp"\n', new)

    def test_extensions_last_without_final_lines(self):
        self.assertRoundTrip("GOOSE_PROVIDER: x\nextensions:\n  developer:\n    enabled: true\n")

    def test_empty_flow_mapping(self):
        text = "a: 1\nextensions: {}  # none yet\nb: 2\n"
        new = self.assertRoundTrip(text)
        self.assertTrue(new.startswith("a: 1\nextensions:  # none yet\n  # hook:begin id=mcp"))

    def test_bare_parent_without_children(self):
        self.assertRoundTrip("extensions:\nb: 2\n")

    def test_no_extensions_key(self):
        for text in ["GOOSE_MODEL: x\n", "GOOSE_MODEL: x", ""]:
            with self.subTest(text):
                new = self.set(text)
                marker = "# hook:begin id=mcp sha=0123456789abcdef" + ("" if text.endswith("\n") or not text else " nonl=1")
                self.assertIn(marker + "\nextensions:\n  relay:\n", new)
                self.assertEqual(ed.yaml_get_owned(new, "mcp"), YAML_VALUE)
                self.assertEqual(ed.yaml_remove_child(new, "mcp"), text)      # the missing newline too

    def test_no_final_newline_round_trips(self):
        for text in ["extensions:\n  developer:\n    enabled: true", "a: 1\nextensions:\n  developer: {}"]:
            with self.subTest(text):
                new = self.set(text)
                self.assertIn("nonl=1", new)
                self.assertEqual(ed.yaml_remove_child(new, "mcp"), text)
                again = ed.yaml_set_child(new, "extensions", "relay", {"type": "stdio"}, "mcp", "0" * 16)
                self.assertEqual(ed.yaml_remove_child(again, "mcp"), text)

    def test_refusals(self):
        for text in [
            "extensions:\n\tdeveloper:\n\t\tenabled: true\n",
            "extensions:\n  developer: &dev\n    enabled: true\n",
            "base: &b {}\nextensions:\n  developer: *b\n",
            "extensions:\n  developer:\n    <<: {}\n",
            "extensions:\n  developer: {enabled: true}\n",
            "extensions:\n  relay:\n    cmd: x\n",
            "extensions:\n- a\n",
            "extensions: [a]\n",
            "extensions:\n  a: 1\nextensions:\n  b: 1\n",
        ]:
            with self.subTest(text):
                with self.assertRaises(ed.EditError):
                    self.set(text)

    def test_empty_flow_values_are_allowed(self):
        self.assertRoundTrip("extensions:\n  developer:\n    envs: {}\n    args: []\n")

    def test_a_changed_value_replaces_the_block(self):
        once = self.set(GOOSE)
        twice = self.set(once, {"cmd": "/opt/relay", "enabled": False})
        self.assertEqual(ed.yaml_get_owned(twice, "mcp"), {"cmd": "/opt/relay", "enabled": False})
        self.assertEqual(ed.yaml_remove_child(twice, "mcp"), GOOSE)

    def test_no_block(self):
        self.assertIsNone(ed.yaml_get_owned(GOOSE, "mcp"))
        self.assertEqual(ed.yaml_remove_child(GOOSE, "mcp"), GOOSE)


class MarkdownTests(unittest.TestCase):
    USER = "# My rules\n\nBe brief.\n"

    def test_insert_replace_remove(self):
        new = ed.md_set_block(self.USER, "instructions", "Use Hook.\n", 1)
        sha = ed.sha256(b"Use Hook.\n")[:16]
        self.assertEqual(
            new, self.USER + f"\n<!-- hook:begin id=instructions v=1 sha={sha} -->\nUse Hook.\n<!-- hook:end -->\n")
        self.assertEqual(ed.md_get_block(new, "instructions"), ("Use Hook.\n", sha))
        replaced = ed.md_set_block(new, "instructions", "Use Hook twice.", 1)
        self.assertEqual(ed.md_get_block(replaced, "instructions")[0], "Use Hook twice.\n")
        self.assertTrue(replaced.startswith(self.USER + "\n<!-- hook:begin"))
        self.assertEqual(ed.md_remove_block(replaced, "instructions"), self.USER)
        self.assertEqual(ed.md_set_block(new, "instructions", "Use Hook.\n", 1), new)

    def test_user_text_above_and_below_is_untouched(self):
        new = ed.md_set_block(self.USER, "instructions", "A\n", 1) + "\nMore of mine.\n"
        replaced = ed.md_set_block(new, "instructions", "B\n", 1)
        self.assertTrue(replaced.startswith(self.USER + "\n"))
        self.assertTrue(replaced.endswith("<!-- hook:end -->\n\nMore of mine.\n"))
        self.assertEqual(ed.md_remove_block(replaced, "instructions"), self.USER + "\nMore of mine.\n")

    def test_a_file_without_a_final_newline(self):
        for text in ["Be brief.", "Be brief.\r\nNo newline."]:
            with self.subTest(text):
                new = ed.md_set_block(text, "x", "A\n", 1)
                self.assertIn("nonl=1 -->", new)
                self.assertEqual(ed.md_get_block(new, "x")[0].replace("\r\n", "\n"), "A\n")
                self.assertEqual(ed.md_remove_block(new, "x"), text)
                replaced = ed.md_set_block(new, "x", "B\n", 1)
                self.assertEqual(ed.md_remove_block(replaced, "x"), text)

    def test_empty_file_and_absent_block(self):
        new = ed.md_set_block("", "x", "body", 2)
        self.assertTrue(new.startswith("<!-- hook:begin id=x v=2 sha="))
        self.assertEqual(ed.md_remove_block(new, "x"), "")
        self.assertIsNone(ed.md_get_block(self.USER, "x"))
        self.assertEqual(ed.md_remove_block(self.USER, "x"), self.USER)

    def test_duplicate_id_and_missing_end_are_refused(self):
        one = ed.md_set_block(self.USER, "x", "A\n", 1)
        for bad in [one + one, self.USER + "<!-- hook:begin id=x v=1 sha=0 -->\nA\n"]:
            with self.subTest(bad):
                for call in (lambda: ed.md_set_block(bad, "x", "B", 1), lambda: ed.md_get_block(bad, "x"),
                             lambda: ed.md_remove_block(bad, "x")):
                    with self.assertRaises(ed.EditError):
                        call()

    def test_a_body_holding_an_end_marker_is_refused(self):
        with self.assertRaises(ed.EditError):
            ed.md_set_block(self.USER, "x", "a\n<!-- hook:end -->\nb\n", 1)


class FileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_backup_keeps_mode_and_never_overwrites(self):
        path = self.dir / "config.json"
        path.write_bytes(b"one")
        os.chmod(path, 0o600)
        now = datetime(2026, 11, 3, 12, 30, 5)
        first = ed.make_backup(path, now)
        self.assertEqual(first.name, "config.json.bak")
        self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)
        path.write_bytes(b"two")
        second = ed.make_backup(path, now)
        self.assertEqual(second.name, "config.json.bak-20261103-123005")
        third = ed.make_backup(path, now)
        self.assertEqual(third.name, "config.json.bak-20261103-123005-2")
        self.assertEqual(ed.make_backup(path, now).name, "config.json.bak-20261103-123005-3")
        self.assertEqual(first.read_bytes(), b"one")
        self.assertEqual(second.read_bytes(), b"two")

    def test_atomic_write_keeps_mode_and_follows_a_symlink(self):
        target = self.dir / "real" / "settings.json"
        target.parent.mkdir()
        target.write_bytes(b"{}")
        os.chmod(target, 0o600)
        link = self.dir / "settings.json"
        link.symlink_to(target)
        ed.atomic_write(link, b'{"a": 1}')
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_bytes(), b'{"a": 1}')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["settings.json"])

    def test_atomic_write_new_file_with_mode(self):
        path = self.dir / "new.toml"
        ed.atomic_write(path, b"x = 1\n", mode=0o640)
        self.assertEqual(path.read_bytes(), b"x = 1\n")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)

    def test_sha256(self):
        self.assertEqual(ed.sha256(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")


if __name__ == "__main__":
    unittest.main()
