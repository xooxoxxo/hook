"""Documents on the Pond, the posting side (Pond feature `docs`, Pond 1.10.0).

A step's `file`, a sub-step's `file` and a link's `path` point at a document on the owner's
Mac, which a phone can't open. A Pond that lists `docs` in GET /version's `features` keeps a
checked copy: this module reads the file, writes its fingerprint beside the path,
`doc: {"sha256", "bytes"}` (of the exact UTF-8 bytes), and returns the text by hash for the
request's `docs` member. Sessions never write `doc`: attach_docs drops every `doc` it is given
first, and strip_docs does only that (for a This Mac queue, or a Pond without `docs`).

A file that can't be copied posts with its path alone and gives one note:
`steps[2].file not copied to the Pond: <reason>`. Errors and notes name field paths in the
validator's notation, never the text. Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import hashlib
import os
import re
import stat
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

DOCS_FEATURE = "docs"
DOC_SUFFIXES = (".md", ".markdown", ".txt")
MAX_DOC_BYTES = 262144          # one document
MAX_DOCS_BYTES = 786432         # all documents of one request
MAX_REQUEST_BYTES = 1048576     # the Pond refuses a request body larger than this (413)

# The reasons a note gives, after "<field> not copied to the Pond: ".
NOT_HERE = "not on this machine"
NOT_FILE = "not a file"
NOT_TEXT_FILE = "not a .md, .markdown or .txt file"
EMPTY = "empty"
TOO_BIG = "larger than 256 KB"
NOT_UTF8 = "not UTF-8 text"
FULL = "the request is full (768 KB)"
SECRET = "it holds a secret-like value"
OFF = "documents are turned off on the Pond"
STORE_FULL = "the Pond's document store is full"

# The 409s a request is refused with for its new documents alone; one resend without them.
NOT_NEW = {"documents not enabled": OFF, "document store full": STORE_FULL}

# The validator's path rules (the Pond's instructable._path, Hook's own validator): a path they
# refuse is never opened, since the ask is refused anyway and opening it could reach a server.
MAX_PATH = 500
NETWORK_ROOTS = ("/net", "/network", "/home")
FIRMLINK_PREFIXES = ("/private/var/automount", "/var/automount", "/private", "/system/volumes/data")

_SHA256 = re.compile(r"[0-9a-f]{64}")
_SECRET_DETAIL = re.compile(r"docs\.([0-9a-f]{64}): secret-like value")

Entry = Tuple[str, List[Any], int, str]   # (field path, the list holding the node, its index, "file" or "path")


def note(field: str, reason: str) -> str:
    """One note: `steps[2].file not copied to the Pond: <reason>`."""
    return f"{field} not copied to the Pond: {reason}"


def _copy(instructable: Any, drop_doc: bool) -> Any:
    """A copy whose steps, sub-steps and links are new dicts (and lists), so they can be changed
    without touching the caller's. Key order is kept; with drop_doc, every `doc` is left out."""
    if not isinstance(instructable, dict):
        return instructable

    def node(value: Any) -> Any:
        if not isinstance(value, dict):
            return value
        return {k: v for k, v in value.items() if not (drop_doc and k == "doc")}

    out = dict(instructable)
    if isinstance(out.get("steps"), list):
        steps = []
        for step in out["steps"]:
            step = node(step)
            if isinstance(step, dict) and isinstance(step.get("substeps"), list):
                step["substeps"] = [node(sub) for sub in step["substeps"]]
            steps.append(step)
        out["steps"] = steps
    if isinstance(out.get("links"), list):
        out["links"] = [node(link) for link in out["links"]]
    return out


def strip_docs(instructable: Any) -> Any:
    """A copy without any `doc` on steps, sub-steps and links: a session never chooses a
    fingerprint. Everything else, key order included, is as given."""
    return _copy(instructable, drop_doc=True)


def _entries(instructable: Any) -> List[Entry]:
    """Every step and sub-step with a string `file` and every link with a string `path` and no
    `url`, in document order: a step before its sub-steps, the steps before the links."""
    found: List[Entry] = []
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    for i, step in enumerate(steps if isinstance(steps, list) else []):
        if not isinstance(step, dict):
            continue
        if isinstance(step.get("file"), str):
            found.append((f"steps[{i}].file", steps, i, "file"))   # type: ignore[arg-type]
        subs = step.get("substeps")
        for j, sub in enumerate(subs if isinstance(subs, list) else []):
            if isinstance(sub, dict) and isinstance(sub.get("file"), str):
                found.append((f"steps[{i}].substeps[{j}].file", subs, j, "file"))
    links = instructable.get("links") if isinstance(instructable, dict) else None
    for k, link in enumerate(links if isinstance(links, list) else []):
        # A link with a `url` (null counts as absent) is refused by the validator whatever its
        # path is: its path is never read.
        if isinstance(link, dict) and isinstance(link.get("path"), str) and link.get("url") is None:
            found.append((f"links[{k}].path", links, k, "path"))   # type: ignore[arg-type]
    return found


def _network_form(value: str) -> str:
    """Runs of "/" as one, lowercased, and the /private, /var/automount, /private/var/automount
    and /System/Volumes/Data prefixes stripped until none is left: they all lead back to the roots."""
    form = re.sub(r"/+", "/", value).lower()
    changed = True
    while changed:
        changed = False
        for prefix in FIRMLINK_PREFIXES:
            if form == prefix or form.startswith(prefix + "/"):
                form = form[len(prefix):] or "/"
                changed = True
                break
    return form


def path_allowed(value: Any) -> bool:
    """Would the validator take this `file` or link `path`? An absolute local path ("/…" or
    "~/…") of 1 to MAX_PATH characters on one line, with no hidden characters, no "." or ".."
    segment, and, for "/…", a first folder that is plain ASCII and doesn't start with ".", and
    not /net, /Network or /home (in any case, also behind "//" or a firmlink prefix). Held to
    conformance/data/instructable-vectors.json."""
    from relay_client import _is_hidden   # the one hidden-character policy (imported late: no cycle)
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_PATH:
        return False
    if any(_is_hidden(ch) for ch in value):     # NUL, TAB, LF and the joiners included
        return False
    if not (value.startswith("/") or value.startswith("~/")):
        return False
    if any(segment in (".", "..") for segment in value.split("/")):
        return False
    if value.startswith("/"):
        segments = [segment for segment in value.split("/") if segment]
        if segments and (segments[0].startswith(".") or not segments[0].isascii()):
            return False
        form = _network_form(value)
        if form in NETWORK_ROOTS or form.startswith(tuple(root + "/" for root in NETWORK_ROOTS)):
            return False
    return True


def has_doc_paths(instructable: Any) -> bool:
    """Does a step, sub-step or link point at a local document?"""
    return bool(_entries(instructable))


def _valid_doc(doc: Any) -> bool:
    size = doc.get("bytes") if isinstance(doc, dict) else None
    return (isinstance(doc, dict) and isinstance(doc.get("sha256"), str) and _SHA256.fullmatch(doc["sha256"]) is not None
            and isinstance(size, int) and not isinstance(size, bool) and 1 <= size <= MAX_DOC_BYTES)


def _set_doc(parent: List[Any], index: int, key: str, doc: Dict[str, Any]) -> None:
    """The node with `doc` right after its path key."""
    out: Dict[str, Any] = {}
    for k, v in parent[index].items():
        if k == "doc":
            continue
        out[k] = v
        if k == key:
            out["doc"] = doc
    parent[index] = out


def _inside(path: str, folder: str) -> bool:
    folder = folder.rstrip(os.sep) or os.sep
    return path == folder or path.startswith(folder if folder.endswith(os.sep) else folder + os.sep)


def _read(path: str, home: str) -> Tuple[Optional[bytes], Optional[str]]:
    """(the file's exact bytes, None), or (None, the reason it isn't sent). (None, None) for a
    path that is neither `/…` nor `~/…`: the validator refuses it, so no note is due."""
    if path.startswith("~/"):
        # As Hook opens it: the home folder, then everything after the "~". Never os.path.join,
        # which would drop the home folder for "~//etc/x.md".
        full = home + path[1:]
    elif path.startswith("/"):
        full = path
    else:
        return None, None
    # As written, before the disk is touched: Hook never even opens a file it would not send.
    if not path.lower().endswith(DOC_SUFFIXES):
        return None, NOT_TEXT_FILE
    try:
        info = os.lstat(full)
    except (FileNotFoundError, NotADirectoryError):
        return None, NOT_HERE
    except OSError:
        return None, NOT_FILE
    if stat.S_ISLNK(info.st_mode):
        # A link is followed only to a file inside the home folder.
        real = os.path.realpath(full)
        if not _inside(real, os.path.realpath(home)):
            return None, NOT_FILE
        try:
            info = os.stat(real)
        except (FileNotFoundError, NotADirectoryError):
            return None, NOT_HERE
        except OSError:
            return None, NOT_FILE
        full = real
    # Resolved, the file must be a document too: a link named plan.md to a key file is not one.
    if not os.path.realpath(full).lower().endswith(DOC_SUFFIXES):
        return None, NOT_TEXT_FILE
    if not stat.S_ISREG(info.st_mode):
        return None, NOT_FILE
    if info.st_size == 0:
        return None, EMPTY
    if info.st_size > MAX_DOC_BYTES:
        return None, TOO_BIG
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(full, flags)
    except (FileNotFoundError, NotADirectoryError):
        return None, NOT_HERE
    except OSError:          # no permission, or swapped for a link since the check
        return None, NOT_FILE
    try:
        with os.fdopen(fd, "rb") as fh:
            if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                return None, NOT_FILE
            data = fh.read(MAX_DOC_BYTES + 1)
    except OSError:
        return None, NOT_FILE
    if not data:
        return None, EMPTY
    if len(data) > MAX_DOC_BYTES:
        return None, TOO_BIG
    if b"\x00" in data:
        return None, NOT_UTF8
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return None, NOT_UTF8
    return data, None


def _held(current: Any) -> Tuple[Dict[str, Tuple[str, Dict[str, Any]]], Dict[str, Dict[str, Any]]]:
    """The documents the ask holds: ({step id: (path, doc)}, {path: doc}). For a path held more
    than once, the first entry in document order gives the doc."""
    by_id: Dict[str, Tuple[str, Dict[str, Any]]] = {}
    by_path: Dict[str, Dict[str, Any]] = {}
    for _, parent, index, key in _entries(current):
        node = parent[index]
        doc = node.get("doc")
        if not _valid_doc(doc):
            continue
        doc = {"sha256": doc["sha256"], "bytes": doc["bytes"]}
        if isinstance(node.get("id"), str):
            by_id[node["id"]] = (node[key], doc)
        by_path.setdefault(node[key], doc)
    return by_id, by_path


def held_hashes(current: Any) -> Set[str]:
    """The hashes of the valid `doc`s of the ask's served instructable: documents the ask holds,
    which a request may keep without their text."""
    return {parent[index]["doc"]["sha256"] for _, parent, index, _ in _entries(current)
            if _valid_doc(parent[index].get("doc"))}


def attach_docs(instructable: Dict[str, Any], *, current: Optional[Dict[str, Any]] = None, refresh: bool = False,
                home: Optional[str] = None) -> Tuple[Dict[str, Any], Dict[str, str], List[str]]:
    """(the instructable with `doc` keys, the `docs` member {sha256: text}, the notes).

    Every `doc` the caller sent is dropped first. Then each step, sub-step and link with a path,
    in document order, gets the fingerprint of the file it names (`~/` is `home`, by default the
    user's home folder), or a note saying why not. The same text is sent once, and the texts of
    one request hold at most MAX_DOCS_BYTES: a document that would pass that is skipped, and a
    later, smaller one may still fit.

    `current` is the ask's served instructable, for a correction or an append. Without
    `refresh`, an entry whose path the ask already holds a valid `doc` for takes that `doc`
    unchanged, and the file is not read: the owner reviewed that copy. The entry with the same
    step id is used when it has the same path, else the first entry with that path. With
    `refresh`, every file is read again."""
    home = home or os.path.expanduser("~")
    out = strip_docs(instructable)
    docs: Dict[str, str] = {}
    notes: List[str] = []
    total = 0
    by_id, by_path = _held(current) if current is not None and not refresh else ({}, {})
    reads: Dict[str, Tuple[Optional[bytes], Optional[str]]] = {}
    for field, parent, index, key in _entries(out):
        node = parent[index]
        path = node[key]
        node_id = node.get("id")
        if isinstance(node_id, str) and node_id in by_id and by_id[node_id][0] == path:
            _set_doc(parent, index, key, dict(by_id[node_id][1]))
            continue
        if path in by_path:
            _set_doc(parent, index, key, dict(by_path[path]))
            continue
        if path not in reads:
            if not path_allowed(path):
                reads[path] = (None, None)    # the validator refuses it: no disk call, no note
            else:
                try:
                    reads[path] = _read(path, home)
                except (OSError, ValueError):
                    reads[path] = (None, None)    # the ask posts with its path; the Pond decides
        data, reason = reads[path]
        if data is None:
            if reason is not None:
                notes.append(note(field, reason))
            continue
        sha256 = hashlib.sha256(data).hexdigest()
        if sha256 not in docs:
            if total + len(data) > MAX_DOCS_BYTES:
                notes.append(note(field, FULL))
                continue
            docs[sha256] = data.decode("utf-8")
            total += len(data)
        _set_doc(parent, index, key, {"sha256": sha256, "bytes": len(data)})
    return out, docs, notes


def drop_docs(instructable: Dict[str, Any], docs: Dict[str, str], hashes: Optional[Set[str]],
              reason: str) -> Tuple[Dict[str, Any], Dict[str, str], List[str]]:
    """(the instructable without the `doc` keys of these hashes, the texts left, one note per
    entry that lost its `doc`, in document order). hashes None drops every `doc` and text."""
    out = _copy(instructable, drop_doc=False)
    notes: List[str] = []
    for field, parent, index, _ in _entries(out):
        node = parent[index]
        if "doc" not in node:
            continue
        doc = node["doc"]
        if hashes is None or (isinstance(doc, dict) and doc.get("sha256") in hashes):
            parent[index] = {k: v for k, v in node.items() if k != "doc"}
            notes.append(note(field, reason))
    kept = {} if hashes is None else {h: t for h, t in docs.items() if h not in hashes}
    return out, kept, notes


def fit_request(instructable: Dict[str, Any], docs: Dict[str, str],
                encode: Callable[[Dict[str, Any], Dict[str, str]], bytes]
                ) -> Tuple[Dict[str, Any], Dict[str, str], List[str]]:
    """Keeps the encoded request (encode(instructable, docs)) within MAX_REQUEST_BYTES: drops
    the texts from the last attached on, each entry that loses its `doc` with a FULL note."""
    if not docs or len(encode(instructable, docs)) <= MAX_REQUEST_BYTES:
        return instructable, docs, []
    order = list(docs)
    dropped: Set[str] = set()
    while order:
        dropped.add(order.pop())
        result = drop_docs(instructable, docs, dropped, FULL)
        if len(encode(result[0], result[1])) <= MAX_REQUEST_BYTES:
            return result
    return drop_docs(instructable, docs, dropped, FULL)


def secret_hashes(exc: Any) -> Set[str]:
    """The hashes a 400 `invalid documents` called secret-like, when that is all it says; else empty."""
    details = list(getattr(exc, "details", None) or [])
    if getattr(exc, "status", None) != 400 or getattr(exc, "error", None) != "invalid documents" or not details:
        return set()
    matches = [_SECRET_DETAIL.fullmatch(str(detail)) for detail in details]
    return {m.group(1) for m in matches if m is not None} if all(matches) else set()


def reapply(exc: Any, instructable: Dict[str, Any], docs: Dict[str, str], held: Set[str] = frozenset()
            ) -> Optional[Tuple[Dict[str, Any], Dict[str, str], List[str]]]:
    """A documents refusal already answered in this call, applied again to documents attached
    afresh (after a stale revision). Every text the Pond called secret-like that is attached again
    is dropped, whether or not the others are still there: none is sent twice in one call. A
    409 drops what retry_without drops. None when there is nothing to drop."""
    flagged = secret_hashes(exc)
    if flagged:
        again = flagged & set(docs)
        return drop_docs(instructable, docs, again, SECRET) if again else None
    return retry_without(exc, instructable, docs, held)


def retry_without(exc: Any, instructable: Dict[str, Any], docs: Dict[str, str], held: Set[str] = frozenset()
                  ) -> Optional[Tuple[Dict[str, Any], Dict[str, str], List[str]]]:
    """What to send once more after a refusal, or None when it isn't about documents.

    - 400 `invalid documents` whose every detail is `docs.<sha256>: secret-like value` for a
      text this request sent: those texts and their `doc` keys go (SECRET).
    - 409 `documents not enabled` (the switch was turned off after the feature was read) or
      `document store full`: the `docs` member goes, and every `doc` whose hash is not in `held`
      (what the ask already holds; empty for a new ask), each with a note (OFF, STORE_FULL). A
      held `doc` stays: the Pond takes a request that only keeps what the ask holds.
    The caller sends once more, never a third time. Nothing is scanned here: the Pond decides."""
    status, error = getattr(exc, "status", None), getattr(exc, "error", None)
    if status == 400:
        hashes = secret_hashes(exc)
        return drop_docs(instructable, docs, hashes, SECRET) if hashes and hashes <= set(docs) else None
    if status == 409 and error in NOT_NEW:
        docs_of = [parent[index]["doc"] for _, parent, index, _ in _entries(instructable)
                   if isinstance(parent[index].get("doc"), dict)]
        # A newly read `doc` whose hash the ask already holds stays, with no note: the Pond keeps
        # that text already, so the request is taken without it.
        new = {doc.get("sha256") for doc in docs_of if doc.get("sha256") not in held}
        if not docs and not new:
            return None
        out, _, notes = drop_docs(instructable, docs, new, NOT_NEW[error])
        return out, {}, notes
    return None
