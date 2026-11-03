"""Format-preserving editors for harness config files. Standard library only, Python 3.9+.

Hook changes only its own key or its own marked block, and every byte outside that edit stays
as it was. Each editor re-reads its result before returning it, so a caller never writes an
edit that fails to parse or reads back wrong.

    ParseError   the file is not valid <format>; the caller marks the target blocked
    EditError    the file is valid, but Hook won't edit it (ambiguous, defined elsewhere,
                 or the edit failed its own check)

JSON and JSONC (one tokenizer: strings, numbers, literals, // and /* */ comments, trailing
commas). Edits splice text into the file and never re-dump it:

    loads_jsonc(text) -> value
    json_get(text, path) -> (found, value)
    json_set(text, path, value) -> text
    json_delete(text, path, *, prune=0) -> text
    json_append(text, path, element, match) -> text           # unchanged if an element matches
    json_remove_matching(text, path, match, *, prune=0) -> text
    json_missing_containers(text, path, *, append=False) -> int

A splice can't tell on its own whether an empty object it leaves behind was the user's or
Hook's. `prune` says how many containers, from the innermost outward (the object holding the
deleted key, or the array itself), Hook created and should remove again once they are empty;
the root counts, and removing it leaves an empty file. `json_missing_containers` tells the
caller that number before it sets or appends, so set-then-delete gives the original bytes.

TOML (one Hook-owned table), YAML (one Hook-owned child of a top-level mapping) and Markdown
(one marked block) live between Hook's markers:

    # hook:begin id=<id> sha=<sha16>        ...   # hook:end
    <!-- hook:begin id=<id> v=<schema> sha=<sha16> -->   ...   <!-- hook:end -->

Files: atomic_write (temp file, fsync, rename, at a symlink's target), make_backup, sha256.
"""
from __future__ import annotations

import copy
import hashlib
import itertools
import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

if sys.version_info >= (3, 11):
    import tomllib as _tomllib
else:
    _tomllib = None


class ParseError(Exception):
    """The text is not valid in its format."""


class EditError(Exception):
    """The text is valid, but Hook won't make this edit."""


BOM = "﻿"


def _newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _split_bom(text: str) -> Tuple[str, str]:
    return (BOM, text[1:]) if text.startswith(BOM) else ("", text)


def _canon(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------------------------------------
# JSON and JSONC


class _Node:
    """A parsed value with its span. `end` is exclusive (just past the closing bracket)."""

    __slots__ = ("kind", "start", "end", "items", "value")

    def __init__(self, kind: str, start: int) -> None:
        self.kind = kind  # "object", "array" or "scalar"
        self.start = start
        self.end = start
        self.items: List[_Item] = []
        self.value: Any = None


class _Item:
    """An object member or an array element. `start` is the key's start (members) or the
    value's start (elements); `comma` is the index of the comma after it, if any."""

    __slots__ = ("key", "start", "node", "comma")

    def __init__(self, key: Optional[str], start: int, node: _Node, comma: Optional[int]) -> None:
        self.key = key
        self.start = start
        self.node = node
        self.comma = comma


_NUMBER = re.compile(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?")
_LITERALS = {"true": True, "false": False, "null": None}
_WORD = re.compile(r"[A-Za-z0-9_.+-]+")
_WS = " \t\r\n"


class _Parser:
    def __init__(self, text: str) -> None:
        self.t = text
        self.i = 0

    def fail(self, message: str) -> ParseError:
        line = self.t.count("\n", 0, self.i) + 1
        return ParseError(f"line {line}: {message}")

    def skip(self) -> None:
        t, n = self.t, len(self.t)
        while self.i < n:
            c = t[self.i]
            if c in _WS:
                self.i += 1
            elif t.startswith("//", self.i):
                j = t.find("\n", self.i)
                self.i = n if j < 0 else j
            elif t.startswith("/*", self.i):
                j = t.find("*/", self.i + 2)
                if j < 0:
                    raise self.fail("unterminated comment")
                self.i = j + 2
            else:
                break

    def peek(self) -> str:
        self.skip()
        if self.i >= len(self.t):
            raise self.fail("unexpected end of file")
        return self.t[self.i]

    def string(self) -> Tuple[str, int]:
        t, start = self.t, self.i
        j = start + 1
        while True:
            if j >= len(t) or t[j] == "\n":
                raise self.fail("unterminated string")
            if t[j] == "\\":
                j += 2
            elif t[j] == '"':
                break
            else:
                j += 1
        try:
            value = json.loads(t[start:j + 1])
        except ValueError as exc:
            raise self.fail(f"bad string: {exc}") from None
        self.i = j + 1
        return value, start

    def value(self) -> _Node:
        c = self.peek()
        if c == "{":
            return self.container("object", "}")
        if c == "[":
            return self.container("array", "]")
        node = _Node("scalar", self.i)
        if c == '"':
            node.value, _ = self.string()
        else:
            m = _NUMBER.match(self.t, self.i)
            word = _WORD.match(self.t, self.i)
            if word and word.group(0) in _LITERALS:
                node.value = _LITERALS[word.group(0)]
                self.i += len(word.group(0))
            elif m and (not word or len(word.group(0)) == len(m.group(0))):
                node.value = json.loads(m.group(0))
                self.i = m.end()
            else:
                raise self.fail("unexpected character")
        node.end = self.i
        return node

    def container(self, kind: str, close: str) -> _Node:
        node = _Node(kind, self.i)
        self.i += 1
        while True:
            c = self.peek()
            if c == close:
                break
            start = self.i
            key = None
            if kind == "object":
                if c != '"':
                    raise self.fail("expected a key")
                key, start = self.string()
                if self.peek() != ":":
                    raise self.fail("expected ':'")
                self.i += 1
            child = self.value()
            c = self.peek()
            if c == ",":
                node.items.append(_Item(key, start, child, self.i))
                self.i += 1
            elif c == close:
                node.items.append(_Item(key, start, child, None))
                break
            else:
                raise self.fail(f"expected ',' or '{close}'")
        self.i += 1
        node.end = self.i
        return node


def _parse(body: str) -> _Node:
    p = _Parser(body)
    root = p.value()
    p.skip()
    if p.i != len(body):
        raise p.fail("unexpected text after the value")
    return root


def _py(node: _Node) -> Any:
    if node.kind == "object":
        return {it.key: _py(it.node) for it in node.items}
    if node.kind == "array":
        return [_py(it.node) for it in node.items]
    return node.value


def loads_jsonc(text: str) -> Any:
    _, body = _split_bom(text)
    if not body.strip():
        raise ParseError("empty file")
    return _py(_parse(body))


def _member(node: _Node, key: str) -> Optional[_Item]:
    hits = [it for it in node.items if it.key == key]
    if len(hits) > 1:
        raise EditError(f"duplicate key {key!r}")
    return hits[0] if hits else None


def _walk(root: _Node, path: Sequence[str]) -> Tuple[List[_Node], Optional[_Item]]:
    """Follow path as far as it exists. Returns the objects passed through (root first) and
    the item at the full path, or None when the walk stopped early."""
    nodes = [root]
    node = root
    for k, key in enumerate(path):
        if node.kind != "object":
            raise EditError(f"{'.'.join(path[:k]) or 'the root'} is not an object")
        it = _member(node, key)
        if it is None:
            return nodes, None
        if k == len(path) - 1:
            return nodes, it
        node = it.node
        nodes.append(node)
    return nodes, None


def _line_start(body: str, pos: int) -> int:
    return body.rfind("\n", 0, pos) + 1


def _line_indent(body: str, pos: int) -> str:
    start = _line_start(body, pos)
    end = start
    while end < len(body) and body[end] in " \t":
        end += 1
    return body[start:end]


def _unit(body: str) -> str:
    for line in body.splitlines():
        rest = line.lstrip(" \t")
        if rest and len(rest) < len(line):
            return line[:len(line) - len(rest)]
    return "  "


def _dump(value: Any, indent: str, unit: str, nl: str) -> str:
    return json.dumps(value, indent=unit, ensure_ascii=False).replace("\n", nl + indent)


def _item_indent(body: str, node: _Node, unit: str) -> str:
    if node.items:
        first = node.items[0].start
        lead = body[_line_start(body, first):first]
        if not lead.strip():
            return lead
    return _line_indent(body, node.start) + unit


def _insert(body: str, node: _Node, piece: Callable[[str], str], unit: str, nl: str) -> str:
    """Add an item before node's closing bracket. piece(indent) renders the item."""
    close = node.end - 1
    p = close
    while p > node.start + 1 and body[p - 1] in _WS:
        p -= 1
    indent = _item_indent(body, node, unit)
    text = nl + indent + piece(indent)
    if node.items:
        last = node.items[-1]
        if last.comma is not None:
            return body[:p] + text + "," + body[p:]
        cut = last.node.end
        return body[:cut] + "," + body[cut:p] + text + body[p:]
    if "\n" not in body[p:close]:
        return body[:p] + text + nl + _line_indent(body, node.start) + body[close:]
    return body[:p] + text + body[p:]


def _remove(body: str, node: _Node, index: int) -> str:
    """Remove item index of node: the inverse of _insert."""
    it = node.items[index]
    ws = it.start
    while ws > 0 and body[ws - 1] in _WS:
        ws -= 1
    after = it.comma + 1 if it.comma is not None else it.node.end
    if len(node.items) == 1:
        inner = node.start + 1
        if not body[inner:it.start].strip() and not body[after:node.end - 1].strip():
            return body[:inner] + body[node.end - 1:]
        return body[:ws] + body[after:]
    if index == len(node.items) - 1 and it.comma is None:
        comma = node.items[index - 1].comma
        assert comma is not None
        return body[:comma] + body[comma + 1:ws] + body[it.node.end:]
    return body[:ws] + body[after:]


def _nest(keys: Sequence[str], value: Any) -> Any:
    for key in reversed(keys):
        value = {key: value}
    return value


def _get(obj: Any, path: Sequence[str]) -> Tuple[bool, Any]:
    for key in path:
        if not isinstance(obj, dict) or key not in obj:
            return False, None
        obj = obj[key]
    return True, obj


def _strip(obj: Any, path: Sequence[str]) -> Any:
    """obj without path, and without the objects on path that are then empty."""
    obj = copy.deepcopy(obj)
    chain = [obj]
    for key in path[:-1]:
        nxt = chain[-1].get(key) if isinstance(chain[-1], dict) else None
        if not isinstance(nxt, dict):
            return obj
        chain.append(nxt)
    if isinstance(chain[-1], dict):
        chain[-1].pop(path[-1], None)
    for k in range(len(chain) - 1, 0, -1):
        if chain[k] == {}:
            chain[k - 1].pop(path[k - 1], None)
    return obj


def _load_or_empty(body: str) -> Any:
    return _py(_parse(body)) if body.strip() else {}


def _verify(old: str, new: str, path: Sequence[str], expect: Tuple[bool, Any]) -> None:
    """new reads back expect at path, and equals old everywhere else."""
    try:
        after = _load_or_empty(new)
    except ParseError as exc:
        raise EditError(f"the edit does not parse: {exc}") from None
    before = _load_or_empty(old)
    found, got = _get(after, path)
    if expect[0] is not None and (found != expect[0] or (found and _canon(got) != _canon(expect[1]))):
        raise EditError("the edit does not read back")
    if _canon(_strip(after, path)) != _canon(_strip(before, path)):
        raise EditError("the edit changed something else")


def _root(body: str) -> _Node:
    root = _parse(body)
    if root.kind != "object":
        raise EditError("the root is not an object")
    return root


def json_get(text: str, path: Sequence[str]) -> Tuple[bool, Any]:
    _, body = _split_bom(text)
    if not body.strip():
        return False, None
    _, it = _walk(_root(body), path)
    return (True, _py(it.node)) if it is not None else (False, None)


def json_missing_containers(text: str, path: Sequence[str], *, append: bool = False) -> int:
    """How many containers a json_set (or json_append) at path would create, the root
    counting when the file is empty: the `prune` for the matching delete."""
    containers = len(path) if append else len(path) - 1
    _, body = _split_bom(text)
    if not body.strip():
        return containers + 1
    root = _root(body)
    node = root
    for k, key in enumerate(path[:containers]):
        it = _member(node, key) if node.kind == "object" else None
        if it is None:
            return containers - k
        node = it.node
    return 0


def json_set(text: str, path: Sequence[str], value: Any) -> str:
    if not path:
        raise EditError("an empty path")
    bom, body = _split_bom(text)
    nl = _newline(body)
    if not body.strip():
        unit = "  "
        new = "{" + nl + unit + json.dumps(path[0], ensure_ascii=False) + ": " \
            + _dump(_nest(path[1:], value), unit, unit, nl) + nl + "}" + nl
    else:
        unit = _unit(body)
        nodes, it = _walk(_root(body), path)
        if it is not None:
            indent = _line_indent(body, it.start)
            new = body[:it.node.start] + _dump(value, indent, unit, nl) + body[it.node.end:]
        else:
            parent = nodes[-1]
            key = path[len(nodes) - 1]
            rest = _nest(path[len(nodes):], value)
            new = _insert(body, parent, lambda ind: json.dumps(key, ensure_ascii=False) + ": "
                          + _dump(rest, ind, unit, nl), unit, nl)
    _verify(body, new, path, (True, value))
    return bom + new


def _delete_body(body: str, path: Sequence[str], prune: int) -> str:
    nodes, it = _walk(_root(body), path)
    if it is None:
        return body
    parent = nodes[-1]
    new = _remove(body, parent, parent.items.index(it))
    return _prune(new, path[:-1], prune)


def _prune(body: str, container: Sequence[str], prune: int) -> str:
    """Remove the (now possibly empty) container at path and its parents, up to prune."""
    if prune <= 0:
        return body
    root = _root(body)
    if not container:
        return "" if body.strip() == "{}" else body
    _, it = _walk(root, container)
    if it is None or it.node.items or body[it.node.start + 1:it.node.end - 1].strip():
        return body
    return _delete_body(body, container, prune - 1)


def json_delete(text: str, path: Sequence[str], *, prune: int = 0) -> str:
    if not path:
        raise EditError("an empty path")
    bom, body = _split_bom(text)
    if not body.strip():
        return text
    new = _delete_body(body, path, prune)
    if new == body:
        return text
    _verify(body, new, path, (False, None))
    return (bom + new) if new else ""


def _array(body: str, path: Sequence[str]) -> Optional[_Node]:
    _, it = _walk(_root(body), path)
    if it is None:
        return None
    if it.node.kind != "array":
        raise EditError(f"{'.'.join(path)} is not an array")
    return it.node


def json_append(text: str, path: Sequence[str], element: Any, match: Callable[[Any], bool]) -> str:
    if not path:
        raise EditError("an empty path")
    bom, body = _split_bom(text)
    node = _array(body, path) if body.strip() else None
    if node is None:
        return json_set(text, path, [element])
    old = [_py(it.node) for it in node.items]
    if any(match(e) for e in old):
        return text
    nl, unit = _newline(body), _unit(body)
    new = _insert(body, node, lambda ind: _dump(element, ind, unit, nl), unit, nl)
    _verify(body, new, path, (True, old + [element]))
    return bom + new


def json_remove_matching(text: str, path: Sequence[str], match: Callable[[Any], bool], *,
                         prune: int = 0) -> str:
    if not path:
        raise EditError("an empty path")
    bom, body = _split_bom(text)
    if not body.strip():
        return text
    node = _array(body, path)
    if node is None:
        return text
    kept = [_py(it.node) for it in node.items if not match(_py(it.node))]
    new = body
    while True:
        node = _array(new, path)
        assert node is not None
        hits = [k for k, it in enumerate(node.items) if match(_py(it.node))]
        if not hits:
            break
        new = _remove(new, node, hits[-1])
    if new == body:
        return text
    if not kept and prune > 0:
        new = _delete_body(new, path, prune - 1)
        _verify(body, new, path, (None, None))
    else:
        _verify(body, new, path, (True, kept))
    return (bom + new) if new else ""


# ---------------------------------------------------------------------------------------------
# Hook's comment markers (TOML and YAML)

_ID = re.compile(r"[A-Za-z0-9_.-]+")
_HASH_BEGIN = re.compile(r"^([ \t]*)#\s*hook:begin\s+(.*?)\s*$")
_HASH_END = re.compile(r"^[ \t]*#\s*hook:end\s*$")


def _attrs(text: str) -> Dict[str, str]:
    return dict(re.findall(r"(\w+)=(\S+)", text))


def _check_id(block_id: str) -> None:
    if not _ID.fullmatch(block_id):
        raise ValueError(f"bad block id {block_id!r}")


def _find_block(lines: List[str], block_id: str, begin: "re.Pattern[str]", end: "re.Pattern[str]",
                attrs_group: int) -> Optional[Tuple[int, int]]:
    """(begin line, end line) of block_id's markers, or None. Two begins for the id, or a
    begin without its end, raise EditError."""
    _check_id(block_id)
    found: Optional[Tuple[int, int]] = None
    k = 0
    while k < len(lines):
        m = begin.match(lines[k].rstrip("\r\n"))
        if m and _attrs(m.group(attrs_group)).get("id") == block_id:
            if found is not None:
                raise EditError(f"two hook:begin markers for {block_id!r}")
            j = k + 1
            while j < len(lines) and not end.match(lines[j].rstrip("\r\n")):
                if begin.match(lines[j].rstrip("\r\n")):
                    raise EditError(f"hook:begin {block_id!r} has no hook:end")
                j += 1
            if j == len(lines):
                raise EditError(f"hook:begin {block_id!r} has no hook:end")
            found = (k, j)
            k = j
        k += 1
    return found


def _hash_block(lines: List[str], block_id: str) -> Optional[Tuple[int, int]]:
    return _find_block(lines, block_id, _HASH_BEGIN, _HASH_END, 2)


def _append_at_end(text: str, block: str, nl: str) -> str:
    """text, a final newline if it lacked one, one blank line, then block."""
    if not text:
        return block
    if not text.endswith("\n"):
        text += nl
    return text + nl + block


def _drop_block(lines: List[str], b: int, e: int, blank_before: bool = True) -> str:
    before, after = lines[:b], lines[e + 1:]
    if blank_before and before and not before[-1].strip():
        before = before[:-1]
    return "".join(before + after)


# ---------------------------------------------------------------------------------------------
# TOML: one Hook-owned table


def _toml_str(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch in "\b\t\n\f\r":
            out.append({"\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}[ch])
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append(f"\\u{ord(ch):04x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _toml_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else _toml_str(key)


def _toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _toml_str(value)
    if isinstance(value, list) and all(isinstance(v, str) for v in value):
        return "[" + ", ".join(_toml_str(v) for v in value) + "]"
    if isinstance(value, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        if not value:
            return "{}"
        return "{ " + ", ".join(f"{_toml_key(k)} = {_toml_str(v)}" for k, v in value.items()) + " }"
    raise EditError(f"Hook writes no TOML value like {type(value).__name__}")


def _toml_part(name: str) -> str:
    e = re.escape(name)
    return rf"(?:{e}|\"{e}\"|'{e}')"


def _toml_refuse(lines: List[str], table: Sequence[str]) -> None:
    if len(table) != 2:
        raise ValueError("the TOML table is two names, like mcp_servers.relay")
    t0, t1 = _toml_part(table[0]), _toml_part(table[1])
    header = re.compile(rf"^\s*\[\[?\s*{t0}\s*\.\s*{t1}\s*[\].]")
    top_key = re.compile(rf"^\s*{t0}\s*(?:=|\.\s*{t1}\s*[.=])")
    parent = re.compile(rf"^\s*\[\s*{t0}\s*\]")
    child = re.compile(rf"^\s*{t1}\s*[.=]")
    any_header = re.compile(r"^\s*\[")
    triple = {'"""': 0, "'''": 0}
    section: Optional[str] = None  # None before any header, "parent" in [t0], "" elsewhere
    for line in lines:
        s = line.strip()
        if s.startswith("#"):
            continue
        for q in triple:
            triple[q] += line.count(q)
        if header.match(line):
            raise EditError(f"{'.'.join(table)} is already defined outside Hook's block")
        if any_header.match(line):
            section = "parent" if parent.match(line) else ""
        elif section is None and top_key.match(line):
            raise EditError(f"{table[0]} is set as a top-level key")
        elif section == "parent" and child.match(line):
            raise EditError(f"[{table[0]}] already holds {table[1]}")
    if any(n % 2 for n in triple.values()):
        raise EditError("a multi-line string Hook can't see past")


class _TomlReader:
    """Reads the values Hook writes: basic strings, string arrays, booleans, integers and an
    inline table of strings."""

    def __init__(self, s: str) -> None:
        self.s = s
        self.i = 0

    def ws(self) -> None:
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def string(self) -> str:
        s = self.s
        if not s.startswith('"', self.i):
            raise ParseError("expected a string")
        self.i += 1
        out = []
        simple = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}
        while True:
            if self.i >= len(s):
                raise ParseError("unterminated string")
            ch = s[self.i]
            if ch == '"':
                self.i += 1
                return "".join(out)
            if ch == "\\":
                esc = s[self.i + 1:self.i + 2]
                if esc in simple:
                    out.append(simple[esc])
                    self.i += 2
                elif esc in ("u", "U"):
                    size = 4 if esc == "u" else 8
                    digits = s[self.i + 2:self.i + 2 + size]
                    if not re.fullmatch(r"[0-9A-Fa-f]{%d}" % size, digits):
                        raise ParseError("bad unicode escape")
                    out.append(chr(int(digits, 16)))
                    self.i += 2 + size
                else:
                    raise ParseError("bad escape")
            else:
                out.append(ch)
                self.i += 1

    def key(self) -> str:
        self.ws()
        if self.s.startswith('"', self.i):
            return self.string()
        m = re.compile(r"[A-Za-z0-9_-]+").match(self.s, self.i)
        if not m:
            raise ParseError("expected a key")
        self.i = m.end()
        return m.group(0)

    def expect(self, ch: str) -> None:
        self.ws()
        if not self.s.startswith(ch, self.i):
            raise ParseError(f"expected {ch!r}")
        self.i += 1

    def value(self) -> Any:
        self.ws()
        s = self.s
        if s.startswith('"', self.i):
            return self.string()
        if s.startswith("[", self.i):
            self.i += 1
            items: List[Any] = []
            while True:
                self.ws()
                if s.startswith("]", self.i):
                    self.i += 1
                    return items
                items.append(self.string())
                self.ws()
                if s.startswith(",", self.i):
                    self.i += 1
                elif not s.startswith("]", self.i):
                    raise ParseError("expected ',' or ']'")
        if s.startswith("{", self.i):
            self.i += 1
            table: Dict[str, Any] = {}
            self.ws()
            if s.startswith("}", self.i):
                self.i += 1
                return table
            while True:
                k = self.key()
                self.expect("=")
                self.ws()
                table[k] = self.string()
                self.ws()
                if s.startswith("}", self.i):
                    self.i += 1
                    return table
                self.expect(",")
        m = re.compile(r"true|false|[+-]?\d+").match(s, self.i)
        if not m:
            raise ParseError("unsupported value")
        self.i = m.end()
        word = m.group(0)
        return word == "true" if word in ("true", "false") else int(word)

    def end(self) -> None:
        self.ws()
        if self.i < len(self.s) and not self.s.startswith("#", self.i):
            raise ParseError("unexpected text after the value")


def _toml_read(lines: List[str]) -> Dict[str, Any]:
    values: Dict[str, Any] = {}
    header = False
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("["):
            if header:
                raise ParseError("Hook's block holds more than one table")
            header = True
            continue
        if not header:
            raise ParseError("a key before the table header")
        r = _TomlReader(s)
        key = r.key()
        r.expect("=")
        values[key] = r.value()
        r.end()
    if not header:
        raise ParseError("Hook's block has no table header")
    return values


def toml_get_owned(text: str, block_id: str) -> Optional[Dict[str, Any]]:
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    if found is None:
        return None
    return _toml_read(lines[found[0] + 1:found[1]])


def toml_set_table(text: str, table: Sequence[str], values: Dict[str, Any], block_id: str, sha: str) -> str:
    nl = _newline(text)
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    outside = lines[:found[0]] + lines[found[1] + 1:] if found else lines
    _toml_refuse(outside, table)
    if _tomllib is not None:
        try:
            _tomllib.loads(text)
        except _tomllib.TOMLDecodeError as exc:
            raise ParseError(f"not valid TOML: {exc}") from None
    body = [f"# hook:begin id={block_id} sha={sha}", "[" + ".".join(_toml_key(t) for t in table) + "]"]
    body += [f"{_toml_key(k)} = {_toml_value(v)}" for k, v in values.items()]
    body.append("# hook:end")
    block = nl.join(body) + nl
    if found:
        prefix, suffix = "".join(lines[:found[0]]), "".join(lines[found[1] + 1:])
        new = prefix + block + suffix
    else:
        new = _append_at_end(text, block, nl)
        prefix, suffix = new[:len(new) - len(block)], ""
    if not (new.startswith(prefix) and new.endswith(suffix)) or toml_get_owned(new, block_id) != values:
        raise EditError("the TOML block does not read back")
    if _tomllib is not None:
        try:
            got = _tomllib.loads(new)
            for t in table:
                got = got[t]
        except (_tomllib.TOMLDecodeError, KeyError, TypeError) as exc:
            raise EditError(f"the edit is not valid TOML: {exc}") from None
        if _canon(got) != _canon(values):
            raise EditError("tomllib reads the block back differently")
    return new


def toml_remove_table(text: str, block_id: str) -> str:
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    if found is None:
        return text
    return _drop_block(lines, *found)


# ---------------------------------------------------------------------------------------------
# YAML: one Hook-owned child of a top-level mapping (Goose's extensions)

_YAML_ANCHOR = re.compile(r"(?:^|[\s\[{,:-])[&*][^\s,\]}]|<<\s*:")


def _yaml_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise EditError(f"Hook writes no YAML value like {type(value).__name__}")


def _yaml_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", key) else json.dumps(key, ensure_ascii=False)


def _yaml_lines(mapping: Dict[str, Any], indent: str, unit: str) -> List[str]:
    out = []
    for k, v in mapping.items():
        key = indent + _yaml_key(k) + ":"
        if isinstance(v, dict):
            out += [key + " {}"] if not v else [key] + _yaml_lines(v, indent + unit, unit)
        elif isinstance(v, list):
            out += [key + " []"] if not v else [key] + [f"{indent}{unit}- {_yaml_scalar(x)}" for x in v]
        else:
            out.append(f"{key} {_yaml_scalar(v)}")
    return out


def _yaml_content(line: str) -> str:
    """The line without a trailing comment (a # after whitespace, outside double quotes)."""
    s = line.rstrip("\r\n")
    quoted = False
    for k, ch in enumerate(s):
        if ch == '"' and (k == 0 or s[k - 1] != "\\"):
            quoted = not quoted
        elif ch == "#" and not quoted and (k == 0 or s[k - 1] in " \t"):
            return s[:k].rstrip()
    return s.rstrip()


def _yaml_flow(content: str) -> Optional[str]:
    m = re.match(r"^\s*(?:-\s+)?(?:(?:\"[^\"]*\"|'[^']*'|[^\s\"'#][^:#]*?)\s*:(?:\s+|$))?(.*)$", content)
    value = m.group(1).strip() if m else ""
    return value if value[:1] in ("{", "[") else None


def _yaml_section(lines: List[str], parent: str) -> Optional[Tuple[int, int]]:
    """(parent line, first line after its section), or None. Two parent lines raise."""
    pat = re.compile(rf"^{re.escape(parent)}\s*:(?:\s|$)")
    hits = [k for k, line in enumerate(lines) if pat.match(line)]
    if len(hits) > 1:
        raise EditError(f"{parent} appears twice")
    if not hits:
        return None
    p = hits[0]
    k = p + 1
    while k < len(lines):
        s = lines[k]
        if s.strip() and s[0] not in " \t#":
            break
        k += 1
    return p, k


def _yaml_not_a_list(lines: List[str], section: Optional[Tuple[int, int]]) -> None:
    if section is not None and section[1] < len(lines) and lines[section[1]].startswith("-"):
        raise EditError("the parent is a list")


def _yaml_check(lines: List[str], start: int, stop: int, child: str) -> str:
    """Refuse what Hook can't safely edit in lines[start:stop]; return the children's indent."""
    indent = None
    for line in lines[start:stop]:
        if line.startswith("\t"):
            raise EditError("a tab-indented line")
        content = _yaml_content(line)
        if not content.strip():
            continue
        if indent is None:
            indent = content[:len(content) - len(content.lstrip(" "))]
            if content.lstrip().startswith("-"):
                raise EditError("the parent is a list")
        if _YAML_ANCHOR.search(content):
            raise EditError("an anchor, alias or merge key")
        flow = _yaml_flow(content)
        if flow is not None and flow not in ("{}", "[]"):
            raise EditError("a flow collection")
        if re.match(rf"^{indent}[\"']?{re.escape(child)}[\"']?\s*:", content):
            raise EditError(f"{child} already exists outside Hook's block")
    return indent or "  "


class _YamlReader:
    """Reads the mappings Hook writes: nested keys, scalars, `- scalar` lists, {} and []."""

    def __init__(self, lines: List[str]) -> None:
        self.items = []
        for line in lines:
            content = _yaml_content(line)
            if content.strip():
                if "\t" in content[:len(content) - len(content.lstrip())]:
                    raise ParseError("a tab-indented line")
                self.items.append((len(content) - len(content.lstrip(" ")), content.strip()))
        self.k = 0

    def scalar(self, s: str) -> Any:
        if s == "{}":
            return {}
        if s == "[]":
            return []
        if s.startswith('"'):
            try:
                return json.loads(s)
            except ValueError:
                raise ParseError("a bad quoted string") from None
        if s.startswith("'") and s.endswith("'") and len(s) > 1:
            return s[1:-1].replace("''", "'")
        if s in ("true", "false"):
            return s == "true"
        if s in ("null", "~"):
            return None
        if re.fullmatch(r"[+-]?\d+", s):
            return int(s)
        return s

    def mapping(self, level: int) -> Dict[str, Any]:
        out: Dict[str, Any] = {}
        while self.k < len(self.items):
            indent, s = self.items[self.k]
            if indent < level:
                break
            if indent > level or s.startswith("-"):
                raise ParseError("unexpected indentation")
            m = re.match(r"^(\"(?:[^\"\\]|\\.)*\"|[^:]+?)\s*:(?:\s+(.*))?$", s)
            if not m:
                raise ParseError("expected a key")
            key = json.loads(m.group(1)) if m.group(1).startswith('"') else m.group(1)
            self.k += 1
            if m.group(2):
                out[key] = self.scalar(m.group(2))
            elif self.k < len(self.items) and self.items[self.k][0] > level:
                deeper, first = self.items[self.k]
                out[key] = self.sequence(deeper) if first.startswith("- ") else self.mapping(deeper)
            else:
                out[key] = None
        return out

    def sequence(self, level: int) -> List[Any]:
        out = []
        while self.k < len(self.items) and self.items[self.k][0] == level and self.items[self.k][1].startswith("- "):
            out.append(self.scalar(self.items[self.k][1][2:].strip()))
            self.k += 1
        return out


def yaml_get_owned(text: str, block_id: str) -> Optional[Dict[str, Any]]:
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    if found is None:
        return None
    reader = _YamlReader(lines[found[0] + 1:found[1]])
    if not reader.items:
        raise ParseError("Hook's block is empty")
    data: Any = reader.mapping(reader.items[0][0])
    if reader.k != len(reader.items):
        raise ParseError("Hook's block has more than one key")
    depth = 2 if not _HASH_BEGIN.match(lines[found[0]]).group(1) else 1  # type: ignore[union-attr]
    for _ in range(depth):
        if not isinstance(data, dict) or len(data) != 1:
            raise ParseError("Hook's block holds more than one key")
        data = next(iter(data.values()))
    if not isinstance(data, dict):
        raise ParseError("Hook's block holds no mapping")
    return data


def _yaml_block(parent: str, child: str, value: Dict[str, Any], block_id: str, sha: str,
                indent: Optional[str], extra: str, nl: str) -> str:
    """indent None wraps the parent in the block (the file had no parent key)."""
    if not isinstance(value, dict):
        raise EditError("the YAML value is a mapping")
    if indent is None:
        rows = [f"# hook:begin id={block_id} sha={sha}", f"{_yaml_key(parent)}:"]
        indent = "  "
        rows += [f"{indent}{_yaml_key(child)}:" + (" {}" if not value else "")]
    else:
        rows = [f"{indent}# hook:begin id={block_id} sha={sha}{extra}"]
        rows += [f"{indent}{_yaml_key(child)}:" + (" {}" if not value else "")]
    rows += _yaml_lines(value, indent + indent, indent)
    rows.append(("" if rows[0].startswith("#") else indent) + "# hook:end")
    return nl.join(rows) + nl


def yaml_set_child(text: str, parent: str, child: str, value: Dict[str, Any], block_id: str, sha: str) -> str:
    nl = _newline(text)
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    if found:
        b, e = found
        m = _HASH_BEGIN.match(lines[b].rstrip("\r\n"))
        assert m is not None
        indent = m.group(1)
        rest = lines[:b] + lines[e + 1:]
        section = _yaml_section(rest, parent)
        _yaml_not_a_list(rest, section)
        if not indent:
            if section is not None:
                raise EditError(f"{parent} appears outside Hook's block too")
            block = _yaml_block(parent, child, value, block_id, sha, None, "", nl)
        else:
            if section is None:
                raise EditError(f"Hook's block is not under {parent}")
            _yaml_check(rest, section[0] + 1, section[1], child)
            was = _attrs(m.group(2)).get("was")
            block = _yaml_block(parent, child, value, block_id, sha, indent, f" was={was}" if was else "", nl)
        new = "".join(lines[:b]) + block + "".join(lines[e + 1:])
        base = yaml_remove_child(text, block_id)
    else:
        base = text
        section = _yaml_section(lines, parent)
        _yaml_not_a_list(lines, section)
        if section is None:
            new = _append_at_end(text, _yaml_block(parent, child, value, block_id, sha, None, "", nl), nl)
        else:
            p, stop = section
            head = lines[p]
            content = _yaml_content(head)[len(parent):].lstrip()
            extra = ""
            if content.startswith(":"):
                content = content[1:].strip()
            if content == "{}":
                if any(_yaml_content(line).strip() for line in lines[p + 1:stop]):
                    raise EditError(f"{parent}: {{}} with lines under it")
                fm = re.match(rf"^({re.escape(parent)}\s*:)\s*\{{\}}(.*)$", head, re.S)
                assert fm is not None
                lines[p] = fm.group(1) + fm.group(2)
                extra = " was={}"
            elif content:
                raise EditError(f"{parent} is not a block mapping")
            indent = _yaml_check(lines, p + 1, stop, child)
            last = p
            for k in range(p + 1, stop):
                if lines[k].strip() and not lines[k].startswith("#"):
                    last = k
            if not lines[last].endswith("\n"):
                lines[last] += nl
            block = _yaml_block(parent, child, value, block_id, sha, indent, extra, nl)
            new = "".join(lines[:last + 1]) + block + "".join(lines[last + 1:])
    if yaml_get_owned(new, block_id) != value or yaml_remove_child(new, block_id) != _final_nl(base, nl):
        raise EditError("the YAML block does not read back")
    return new


def _final_nl(text: str, nl: str) -> str:
    return text if not text or text.endswith("\n") else text + nl


def yaml_remove_child(text: str, block_id: str) -> str:
    lines = text.splitlines(keepends=True)
    found = _hash_block(lines, block_id)
    if found is None:
        return text
    b, e = found
    m = _HASH_BEGIN.match(lines[b].rstrip("\r\n"))
    assert m is not None
    if not m.group(1):
        return _drop_block(lines, b, e)
    rest = lines[:b] + lines[e + 1:]
    if _attrs(m.group(2)).get("was") == "{}":
        p = b - 1
        while p >= 0 and (not rest[p].strip() or rest[p][0] in " \t#"):
            p -= 1
        stop = p + 1
        while stop < len(rest) and (not rest[stop].strip() or rest[stop][0] in " \t#"):
            stop += 1
        fm = re.match(r"^([^\s#][^:]*:)(.*)$", rest[p], re.S) if p >= 0 else None
        if fm and not any(_yaml_content(line).strip() for line in rest[p + 1:stop]):
            rest[p] = fm.group(1) + " {}" + fm.group(2)
    return "".join(rest)


# ---------------------------------------------------------------------------------------------
# Markdown: one marked block

_MD_BEGIN = re.compile(r"^<!--\s*hook:begin\s+(.*?)\s*-->\s*$")
_MD_END = re.compile(r"^<!--\s*hook:end\s*-->\s*$")


def _md_block(lines: List[str], block_id: str) -> Optional[Tuple[int, int]]:
    return _find_block(lines, block_id, _MD_BEGIN, _MD_END, 1)


def md_get_block(text: str, block_id: str) -> Optional[Tuple[str, str]]:
    """(body, sha in the begin marker), or None. The body is the text between the markers,
    as it is in the file; a marker's sha16 covers exactly that text."""
    lines = text.splitlines(keepends=True)
    found = _md_block(lines, block_id)
    if found is None:
        return None
    m = _MD_BEGIN.match(lines[found[0]].rstrip("\r\n"))
    assert m is not None
    return "".join(lines[found[0] + 1:found[1]]), _attrs(m.group(1)).get("sha", "")


def md_set_block(text: str, block_id: str, body: str, schema: int) -> str:
    nl = _newline(text)
    body = body.replace("\r\n", "\n")
    if not body.endswith("\n"):
        body += "\n"
    body = body.replace("\n", nl)
    sha16 = sha256(body.encode("utf-8"))[:16]
    block = f"<!-- hook:begin id={block_id} v={schema} sha={sha16} -->{nl}{body}<!-- hook:end -->{nl}"
    lines = text.splitlines(keepends=True)
    found = _md_block(lines, block_id)
    if found:
        prefix, suffix = "".join(lines[:found[0]]), "".join(lines[found[1] + 1:])
        new = prefix + block + suffix
    else:
        new = _append_at_end(text, block, nl)
        prefix, suffix = new[:len(new) - len(block)], ""
    if not (new.startswith(prefix) and new.endswith(suffix)) or md_get_block(new, block_id) != (body, sha16):
        raise EditError("the Markdown block does not read back (does the body hold a marker?)")
    return new


def md_remove_block(text: str, block_id: str) -> str:
    lines = text.splitlines(keepends=True)
    found = _md_block(lines, block_id)
    if found is None:
        return text
    return _drop_block(lines, *found)


# ---------------------------------------------------------------------------------------------
# Files


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes, *, mode: Optional[int] = None) -> None:
    """Write data to path through a temp file in the same folder, fsync, then rename. A
    symlink is followed and its target replaced, so the link stays. The mode is `mode`, else
    the existing file's, else 0666 less the umask."""
    target = Path(os.path.realpath(path))
    if mode is None:
        try:
            mode = target.stat().st_mode & 0o7777
        except FileNotFoundError:
            umask = os.umask(0)
            os.umask(umask)
            mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=f".{target.name}.", suffix=".hook-tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fchmod(fh.fileno(), mode)
            os.fsync(fh.fileno())
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    dfd = os.open(str(target.parent), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def make_backup(path: Path, now: datetime) -> Path:
    """Copy path (its target, if a symlink) to <name>.bak beside it, or, when that exists, to
    <name>.bak-YYYYMMDD-HHMMSS, then -2, -3, ... Never overwrites; the mode is copied."""
    path = Path(path)
    data = path.read_bytes()
    mode = path.stat().st_mode & 0o7777
    stamp = now.strftime("%Y%m%d-%H%M%S")
    numbered = (f"{path.name}.bak-{stamp}-{n}" for n in itertools.count(2))
    for name in itertools.chain([f"{path.name}.bak", f"{path.name}.bak-{stamp}"], numbered):
        dest = path.with_name(name)
        try:
            fd = os.open(str(dest), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
                os.fchmod(fh.fileno(), mode)
                fh.flush()
                os.fsync(fh.fileno())
        except BaseException:
            os.unlink(str(dest))
            raise
        return dest
    raise AssertionError("unreachable")
