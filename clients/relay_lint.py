"""Values to copy that sit inside a step's prose, and requirements that can never be met.

An owner can copy a step's `code` and open its `url`, but nothing inside `do`. So a URL,
an address, a path, a model name or a command written into `do` has to be retyped by hand.
lint_instructable() finds them; `relay post` and `relay_post` refuse an ask that has any,
with the same output as a validation error, so the session moves each value into a
sub-step's `code` (or a page into `url`) and posts again. lint_requirements() adds the
`required` and `done` (Pond 1.3.0) that nothing could ever finish, worded as guidance.
lint_choice_labels() flags a string choice that asks for words in its label ("Mix (reply
what)"): from Pond 1.4.0 such a choice is {"label", "text"} with its own field.
lint_hook_controls() flags a step that only points at Hook's own controls ("Pick an answer
below", "Press Done") and a verify that only restates the reply or Done.
lint_do_title() flags a do that is more than the owner's one action: over 60 characters, or
several actions joined by commas, "and" or "then" ("Install X, create Y and add Z").

The rules live here and nowhere else in Hook. Other clients copy this file's functions and
test them against clients/lint-vectors.json. Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Tuple

# --- what counts as a value to copy ---

_URL = re.compile(r"https?://[^\s<>\"'`]+", re.IGNORECASE)
_BACKTICK = re.compile(r"`([^`\n]+)`")
_DOUBLE = re.compile(r"[\"“]([^\"“”\n]{3,})[\"”]")
# A single quote opens only after a space or a bracket, so "the owner's key" isn't a quote.
_SINGLE = re.compile(r"(?<![^\s(\[])['‘]([^'‘’\n]{3,}?)['’](?=$|[\s.,;:!?)\]])")
_IPV4 = re.compile(r"(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?::(\d{1,5}))?(?![\w]|\.\d)")
_HOST_PORT = re.compile(r"(?<![\w.:/@-])([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):(\d{2,5})(?![\w:])")
_PATH = re.compile(r"(?<![\w/:.~\\-])(?:~/[^\s,;\"'`()<>\[\]]*|/[A-Za-z0-9._@+-][^\s,;\"'`()<>\[\]]*)")
_KEY_VALUE = re.compile(r"(?<![\w=@.])(-{0,2}[A-Za-z_][\w.-]*)=([^\s,;\"'`=][^\s,;\"'`]*)")
_RUN = re.compile(r"[A-Za-z0-9:/._-]+")
_LONG_MIN = 12

# Prose that looks like a run but is not a value to copy.
_DATE_TIME = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?Z?)?")
_SEMVER = re.compile(r"v?\d+(?:\.\d+)+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?")

# A quoted phrase of several words is a command when it starts with one of these.
_COMMANDS = frozenset((
    "bash", "brew", "bun", "cargo", "cat", "cd", "chmod", "chown", "colima", "cp", "curl", "defaults",
    "deno", "docker", "echo", "export", "gh", "git", "go", "grep", "kill", "kubectl", "launchctl", "ln",
    "ls", "make", "mkdir", "mv", "node", "npm", "npx", "open", "pip", "pip3", "pnpm", "python",
    "python3", "relay", "hook", "rm", "scp", "security", "sh", "ssh", "sudo", "swift", "systemctl",
    "tailscale", "tar", "touch", "uv", "uvx", "wget", "yarn", "zsh",
))
_SHELLISH = re.compile(r"(?:^|\s)--?[A-Za-z]|\||&&|\$|=|~/|(?:^|\s)/[\w.]|://|[<>]")
_TRAILING = ".,;:!?…"


def _quoted_value(text: str) -> bool:
    """A quoted phrase that is an identifier, a path or a command, not a button label."""
    s = text.strip().rstrip(_TRAILING)
    if len(s) < 3:
        return False
    if any(ch.isspace() for ch in s):
        return s.split()[0] in _COMMANDS or bool(_SHELLISH.search(s))
    letters, digits = re.search(r"[A-Za-z]", s), re.search(r"\d", s)
    if letters and digits:
        return True                                   # studio2, C07ABC123
    marks = set(re.findall(r"[^A-Za-z0-9]", s))
    if marks and marks <= {"-", "."} and re.search(r"[A-Z]", s):
        return False                                  # Wi-Fi, Sign-in, Node.js: names, not values
    if marks & set("_-./:=@$~\\"):
        return True                                   # acme-brief, chat:write, RELAY_CONFIG
    return bool(re.search(r"[a-z][A-Z]", s))          # editKeyHash


def _long_run(run: str) -> bool:
    if len(run) < _LONG_MIN or not re.search(r"[A-Za-z]", run) or not re.search(r"\d", run):
        return False
    return not (_DATE_TIME.fullmatch(run) or _SEMVER.fullmatch(run))


def _trim(start: int, value: str, chars: str = _TRAILING) -> Tuple[int, int, str]:
    trimmed = value.rstrip(chars)
    return start, start + len(trimmed), trimmed


def _trim_url(start: int, value: str) -> Tuple[int, int, str]:
    trimmed = value.rstrip(_TRAILING)
    while trimmed.endswith(")") and trimmed.count("(") < trimmed.count(")"):
        trimmed = trimmed[:-1].rstrip(_TRAILING)
    return start, start + len(trimmed), trimmed


def _candidates(text: str) -> List[Tuple[int, int, str]]:
    """(start, end, value) for each value to copy in text, in priority order. A later
    rule never reports what an earlier one already covered."""
    found: List[Tuple[int, int, str]] = []
    for m in _BACKTICK.finditer(text):
        found.append((m.start(), m.end(), m.group(1).strip()))
    for pattern in (_DOUBLE, _SINGLE):
        for m in pattern.finditer(text):
            if _quoted_value(m.group(1)):
                found.append((m.start(), m.end(), m.group(1).strip().rstrip(_TRAILING)))
    for m in _URL.finditer(text):
        found.append(_trim_url(m.start(), m.group(0)))
    for m in _IPV4.finditer(text):
        if m.group(1).startswith("127.") and m.group(2) is None:
            continue                                   # a bare loopback address describes, it isn't typed
        if all(int(octet) <= 255 for octet in m.group(1).split(".")):
            found.append((m.start(), m.end(), m.group(0)))
    for m in _HOST_PORT.finditer(text):
        if re.search(r"[A-Za-z]", m.group(1)) and 0 < int(m.group(2)) <= 65535:
            found.append((m.start(), m.end(), m.group(0)))
    for m in _PATH.finditer(text):
        start, end, value = _trim(m.start(), m.group(0))
        if value not in ("/", "~/") and len(value) > 1:
            found.append((start, end, value))
    for m in _KEY_VALUE.finditer(text):
        if "@" not in m.group(0):
            found.append(_trim(m.start(), m.group(0)))
    for m in _RUN.finditer(text):
        start, end, value = _trim(m.start(), m.group(0), _TRAILING + "/-")
        if _long_run(value):
            found.append((start, end, value))
    taken: List[Tuple[int, int, str]] = []
    for start, end, value in found:
        if value and not any(start < t_end and t_start < end for t_start, t_end, _ in taken):
            taken.append((start, end, value))
    return sorted(taken)


# --- where a value may already be copyable ---

def _strings(node: Any, key: str) -> List[str]:
    value = node.get(key) if isinstance(node, dict) else None
    return [value.strip()] if isinstance(value, str) and value.strip() else []


def _bare_url(url: str) -> str:
    return url.rstrip("/").lower()


def _copyable(value: str, codes: List[str], urls: List[str]) -> bool:
    if any(value in code for code in codes):
        return True
    return value.lower().startswith(("http://", "https://")) and _bare_url(value) in {_bare_url(u) for u in urls}


def _message(values: List[str], verify: bool) -> str:
    shown = ", ".join(json.dumps(v, ensure_ascii=False) for v in values)
    if len(values) == 1:
        return f"{shown} is a value to copy: put it in code (or a URL in url)"
    if verify:
        return f"{shown} are values to copy: put them in code (or a URL in url)"
    return f"{shown} are values to copy: put each in a sub-step's code (or a URL in url)"


def lint_do(text: Any, codes: List[str], urls: List[str]) -> List[str]:
    """The values to copy in one `do`, minus those already in codes or urls, in order, once each."""
    if not isinstance(text, str):
        return []
    values: List[str] = []
    for _, _, value in _candidates(text):
        if value not in values and not _copyable(value, codes, urls):
            values.append(value)
    return values


# --- requirements that can never be met (Pond 1.3.0's `required` and `done`) ---

NOTHING_TO_FINISH = ("has nothing to finish: every sub-step is optional. Drop required, "
                     "or make a sub-step one the owner must do")
WITH_OPTIONAL = "can't go with optional: drop one of them"
INSIDE_OPTIONAL = "can't be required inside an optional step"
NO_REPLY = "\"reply\" needs a reply prompt: add reply, or drop it from done"
ALL_OPTIONAL = "\"steps\" has nothing to finish: every step is optional"


def _all_optional(steps: Any) -> bool:
    """A non-empty list whose entries are all steps with optional: true."""
    return (isinstance(steps, list) and bool(steps)
            and all(isinstance(s, dict) and s.get("optional") is True for s in steps))


def lint_requirements(doc: Any) -> List[Tuple[str, str]]:
    """(path, message) for a `required` or `done` that can never be met, with what to do about
    it. Guidance only: the Pond's validator stays authoritative and words a malformed key itself
    (a `required` that isn't a bool, a `done` that isn't a list of known values). One pair per
    step, in document order, then one per distinct `done` entry, in its order."""
    problems: List[Tuple[str, str]] = []
    if not isinstance(doc, dict):
        return problems

    def check(path: str, node: Dict[str, Any], *, in_optional: bool) -> None:
        if node.get("required") is not True:
            return
        if node.get("optional") is True:
            problems.append((f"{path}.required", WITH_OPTIONAL))
        elif in_optional:
            problems.append((f"{path}.required", INSIDE_OPTIONAL))
        elif node.get("question") is None and _all_optional(node.get("substeps")):
            problems.append((f"{path}.required", NOTHING_TO_FINISH))

    steps = doc.get("steps") if isinstance(doc.get("steps"), list) else []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        check(f"steps[{i}]", step, in_optional=False)
        subs = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        for j, sub in enumerate(subs):
            if isinstance(sub, dict):
                check(f"steps[{i}].substeps[{j}]", sub, in_optional=step.get("optional") is True)
    done = doc.get("done")
    seen: List[str] = []
    for entry in done if isinstance(done, list) else []:
        if not isinstance(entry, str) or entry in seen:
            continue
        seen.append(entry)
        if entry == "reply" and doc.get("reply") is None:
            problems.append(("done", NO_REPLY))
        elif entry == "steps" and _all_optional(doc.get("steps")):
            problems.append(("done", ALL_OPTIONAL))
    return problems


# A string choice that asks for the owner's words in its label (Pond 1.4.0 has a field for them).
_REPLY_LABEL = re.compile(r"\(\s*reply\b[^)]*\)", re.IGNORECASE)


def _choice_lists(doc: Dict[str, Any]) -> List[Tuple[str, List[Any]]]:
    """(path, choices) for each question (each step, then its sub-steps) and the reply."""
    found: List[Tuple[str, List[Any]]] = []

    def add(path: str, holder: Any) -> None:
        if isinstance(holder, dict) and isinstance(holder.get("choices"), list):
            found.append((f"{path}.choices", holder["choices"]))

    steps = doc.get("steps") if isinstance(doc.get("steps"), list) else []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        add(f"steps[{i}].question", step.get("question"))
        subs = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        for j, sub in enumerate(subs):
            if isinstance(sub, dict):
                add(f"steps[{i}].substeps[{j}].question", sub.get("question"))
    add("reply", doc.get("reply"))
    return found


def lint_choice_labels(doc: Any) -> List[Tuple[str, str]]:
    """(path, message) for each string choice whose label asks for words ("Mix (reply what)",
    "Changes (reply)"): from Pond 1.4.0 such a choice is {"label", "text"}, and on an older Pond
    the prompt says what to write. Questions in document order, then the reply."""
    problems: List[Tuple[str, str]] = []
    if not isinstance(doc, dict):
        return problems
    for path, choices in _choice_lists(doc):
        for i, choice in enumerate(choices):
            if not isinstance(choice, str) or not _REPLY_LABEL.search(choice):
                continue
            label = " ".join(_REPLY_LABEL.sub(" ", choice).split()) or "…"
            suggestion = json.dumps({"label": label, "text": "…"}, ensure_ascii=False)
            problems.append((f"{path}[{i}]", f"{json.dumps(choice, ensure_ascii=False)} asks for words: "
                                             f"make it {suggestion} (Pond 1.4.0), or say what to write in the prompt"))
    return problems


# A step that only points at Hook's own controls: the reply box, the questions, Done and Skip.
# Hook already shows them, so such a step (or a verify that restates them) is filler.
_HOOK_PLACES = frozenset(("hook", "hook app", "the hook app", "hook sidebar", "hook queue", "relay", "here",
                          "this ask", "the ask"))
_ON_HOOK = r"(?:this|the|your|my)\s+(?:ask|question|questions|prompt|instructable)\b|hook\b|relay\b|here\b|below\b|above\b"
_CONTROL_DO = re.compile(r"(?:" + "|".join((
    r"reply\b(?!\s+all\b)(?!\s+(?:to|in|on|at)\s+(?!" + _ON_HOOK + r"))",
    r"(?:pick|choose|select)\s+(?:an?\s+|one\s+|your\s+)?(?:answer|option|choice|reply)s?\b",
    r"(?:pick|choose|select)\s+(?:one\s+)?(?:below|above)\b",
    r"answer\s+(?:(?:the|each|every|all|all\s+the|these|this|my|both)\s+)?(?:question|questions|prompt)\b",
    r"answer\s+(?:it\s+)?(?:below|above|here|in\s+hook)\b",
    r"press\s+(?:the\s+)?(?:done|skip)\b",
    # "Click Done" alone is a button in any app; only Hook's Done comes after answering.
    r"(?:click|tap|hit|use)\s+(?:the\s+)?(?:done|skip)\s+(?:button\s+)?"
    r"(?:on\s+(?:this|the)\s+ask|in\s+hook|after\b|when\b|once\b|to\s+(?:close|finish))",
    r"(?:look\s+at|check|review|read|confirm)\s+(?:the|your)\s+(?:reply|replies|answer|answers)\b",
)) + r")", re.IGNORECASE)
_CONTROL_EXPECT = re.compile(r"(?:" + "|".join((
    r"(?:the\s+)?ask\s+(?:closes|is\s+closed|is\s+done|shows\s+done|moves\s+to\s+done)\b",
    r"(?:[^.]{0,30}\bor\s+)?your\s+(?:reply|replies|answer|answers|notes)"
    r"(?:\s+(?:is|are)\s+(?:sent|shown|listed|recorded|there))?\s*[.!]?$",
    r".*\b(?:done|skip)\s+(?:is\s+)?(?:pressed|turns\s+on|is\s+on)\b",
)) + r")", re.IGNORECASE)
_VERIFY_DO = re.compile(r"(?:the\s+)?ask\s+(?:closes|is\s+closed|is\s+done)\b", re.IGNORECASE)
# "Reply to the Slack thread", "Answer the question in the Google form": work in another app.
_ELSEWHERE = re.compile(r"\b(?:in|on|to|via|from|at)\s+(?:the\s+|your\s+|a\s+)?([A-Z][\w.-]*)")


def _elsewhere(text: str) -> bool:
    return any(m.group(1).lower() not in ("hook", "relay", "done", "skip") for m in _ELSEWHERE.finditer(text))


def _hook_only(node: Dict[str, Any]) -> bool:
    """No code, url, file, question or sub-steps, and no other place named in where."""
    if any(node.get(k) not in (None, "", []) for k in ("code", "url", "file", "question", "substeps")):
        return False
    where = node.get("where")
    return not (isinstance(where, str) and where.strip() and where.strip().lower() not in _HOOK_PLACES)


def _points_at_controls(text: Any, pattern: "re.Pattern[str]") -> bool:
    return isinstance(text, str) and bool(pattern.match(text.strip())) and not _elsewhere(text)


def lint_hook_controls(doc: Any) -> List[Tuple[str, str]]:
    """(path, message) for each step or sub-step whose do only points at Hook's own controls
    ("Pick an answer below", "Reply with …", "Press Done after answering"), then for a verify
    whose do or expect only restates the reply or Done. A step with code, url, file, a question
    or sub-steps, or with a where that names another app, is real work and passes."""
    problems: List[Tuple[str, str]] = []
    if not isinstance(doc, dict):
        return problems
    steps = doc.get("steps") if isinstance(doc.get("steps"), list) else []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        raw = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        nodes: List[Tuple[str, Dict[str, Any]]] = [(f"steps[{i}]", step)]
        nodes += [(f"steps[{i}].substeps[{j}]", sub) for j, sub in enumerate(raw) if isinstance(sub, dict)]
        for path, node in nodes:
            if _hook_only(node) and _points_at_controls(node.get("do"), _CONTROL_DO):
                problems.append((f"{path}.do", f"{json.dumps(node['do'].strip(), ensure_ascii=False)} only points at "
                                               "Hook's own controls: drop the step; the reply box and questions "
                                               "already show"))
    verify = doc.get("verify")
    if isinstance(verify, dict) and _hook_only(verify):
        for key in ("do", "expect"):
            text = verify.get(key)
            pattern = _CONTROL_EXPECT if key == "expect" else _CONTROL_DO
            if _points_at_controls(text, pattern) or (key == "do" and _points_at_controls(text, _VERIFY_DO)):
                problems.append((f"verify.{key}", f"{json.dumps(text.strip(), ensure_ascii=False)} only restates the "
                                                  "reply or Done: drop verify; keep it only for a real check, "
                                                  "like a command with expect"))
                break
    return problems


# --- do is the owner's one action ---

DO_MAX = 60
# An action is a clause that starts with one of these. Clauses are split at a comma, a
# semicolon, " and " and " then ", so "Click Create New App, then From scratch" is one
# action and "Install X, create Y and add Z" is three.
_ACTION_VERBS = frozenset((
    "accept", "add", "allow", "answer", "approve", "attach", "build", "change", "check", "choose",
    "click", "close", "configure", "confirm", "connect", "copy", "create", "delete", "deploy",
    "disable", "download", "drag", "drop", "edit", "eject", "enable", "enter", "fill", "find",
    "follow", "generate", "go", "grant", "hold", "insert", "install", "invite", "launch", "log",
    "look", "make", "mention", "merge", "move", "name", "open", "pair", "paste", "pick", "ping",
    "plug", "post", "press", "pull", "push", "quit", "read", "reboot", "register", "relaunch",
    "reload", "remove", "rename", "reopen", "replace", "reply", "restart", "review", "revoke",
    "rotate", "run", "save", "scroll", "select", "send", "set", "share", "sign", "skip", "start",
    "stop", "store", "switch", "tap", "toggle", "trust", "turn", "type", "uninstall", "unlock",
    "unplug", "update", "upgrade", "upload", "use", "verify", "visit", "wait",
))
_CLAUSE = re.compile(r"\s*(?:[,;]\s*(?:and\s+|then\s+)?|\s(?:and|then)\s+)", re.IGNORECASE)
_FIRST_WORD = re.compile(r"[A-Za-z]+")


def _actions(text: str) -> int:
    """How many clauses of text start with an action verb."""
    count = 0
    for clause in _CLAUSE.split(text):
        word = _FIRST_WORD.match(clause.strip())
        count += bool(word and word.group(0).lower() in _ACTION_VERBS)
    return count


def _opening(text: str, room: int = 28) -> str:
    """The first words of text, up to room characters, with … when there is more."""
    if len(text) <= room + 2:
        return text
    words, kept = text.split(), ""
    for word in words:
        if kept and len(kept) + 1 + len(word) > room:
            break
        kept = f"{kept} {word}" if kept else word
    return kept.rstrip(_TRAILING) + "…"


def _title_problem(text: Any, verify: bool) -> str:
    if not isinstance(text, str):
        return ""
    text = text.strip()
    actions = 0 if verify else _actions(text)
    if actions >= 3 or (actions >= 2 and len(text) > DO_MAX):
        return (f"{json.dumps(_opening(text), ensure_ascii=False)} names more than one action: keep do to "
                "the owner's one action and move the rest to detail, or split into steps")
    if len(text) > DO_MAX:
        return f"do is {len(text)} characters: keep it under {DO_MAX} and move the rest to detail"
    return ""


def lint_do_title(doc: Any) -> List[Tuple[str, str]]:
    """(path, message) for each step or sub-step whose do is more than the owner's one action:
    three or more actions ("Install X, create Y and add Z"), two over 60 characters, or any do
    over 60 characters. Two actions within 60 are a click path ("Open Settings and click Save")
    and pass. verify gets only the length check. A do that already holds a value to copy gets
    that message alone: moving the values rewrites it, and the next post checks it again."""
    problems: List[Tuple[str, str]] = []
    if not isinstance(doc, dict):
        return problems
    steps = doc.get("steps") if isinstance(doc.get("steps"), list) else []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        raw = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        nodes: List[Tuple[str, Dict[str, Any]]] = [(f"steps[{i}]", step)]
        nodes += [(f"steps[{i}].substeps[{j}]", sub) for j, sub in enumerate(raw) if isinstance(sub, dict)]
        codes = [c for _, node in nodes for c in _strings(node, "code")]
        urls = [u for _, node in nodes for u in _strings(node, "url")]
        for path, node in nodes:
            message = "" if lint_do(node.get("do"), codes, urls) else _title_problem(node.get("do"), verify=False)
            if message:
                problems.append((f"{path}.do", message))
    verify = doc.get("verify")
    if isinstance(verify, dict) and not lint_do(verify.get("do"), _strings(verify, "code"), _strings(verify, "url")):
        message = _title_problem(verify.get("do"), verify=True)
        if message:
            problems.append(("verify.do", message))
    return problems


def lint_instructable(doc: Any) -> List[Tuple[str, str]]:
    """(path, message) for each `do` (step, sub-step, verify) that holds a value the owner
    would have to retype, then lint_requirements' pairs, then lint_choice_labels', then
    lint_hook_controls', then lint_do_title's. A step shares its sub-steps' code and url, and
    they share its."""
    problems: List[Tuple[str, str]] = []
    if not isinstance(doc, dict):
        return problems
    steps = doc.get("steps") if isinstance(doc.get("steps"), list) else []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        raw = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        nodes: List[Tuple[str, Dict[str, Any]]] = [(f"steps[{i}]", step)]
        nodes += [(f"steps[{i}].substeps[{j}]", sub) for j, sub in enumerate(raw) if isinstance(sub, dict)]
        codes = [c for _, node in nodes for c in _strings(node, "code")]
        urls = [u for _, node in nodes for u in _strings(node, "url")]
        for path, node in nodes:
            values = lint_do(node.get("do"), codes, urls)
            if values:
                problems.append((f"{path}.do", _message(values, verify=False)))
    verify = doc.get("verify")
    if isinstance(verify, dict):
        values = lint_do(verify.get("do"), _strings(verify, "code"), _strings(verify, "url"))
        if values:
            problems.append(("verify.do", _message(values, verify=True)))
    return (problems + lint_requirements(doc) + lint_choice_labels(doc) + lint_hook_controls(doc)
            + lint_do_title(doc))


def lint_details(doc: Any) -> List[str]:
    """lint_instructable as the field-error lines a refusal prints: "<path>: <message>"."""
    return [f"{path}: {message}" for path, message in lint_instructable(doc)]
