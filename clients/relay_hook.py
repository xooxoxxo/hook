"""`relay hook replies --format claude|gemini|kiro|cursor|copilot|plain [--when prompt|session-start]`:
the owner's new Hook answers in the shape each agent harness's hook expects.

    claude   {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit"|"SessionStart", "additionalContext": …}}
    gemini   the same, with "BeforeAgent" (or "SessionStart")
    cursor   {"additional_context": …}
    copilot  {"additionalContext": …}
    kiro, plain   the lines, one per row

Nothing at all is printed when there are no lines. Prompt mode (the default, except for cursor
and copilot) keeps a cursor per session: `session:<id>` from the hook's stdin (session_id,
sessionId or conversation_id), or `session:ppid-<parent pid>` when the harness names none; with
no session named, problem reports, accepted versions and the owner's messages are left out, as
in 0.12. Session-start mode prints the owner's events from the last 24 h, the newest 10, keeps no
cursor and leaves those poster-only kinds out.

Like the 0.12 hook it never launches Hook, keeps to a 2 s budget, prints every owner and ask text
quoted on one line (session_text, message_line), cuts the context at 8 000 characters on a line
boundary, and always exits 0, argument errors included. `--probe` prints PROBE_OK and contacts
nothing: `relay integrations` runs it to check that a rendered hook command works.

`relay replies [--new] --hook` stays as an alias with its 0.12 output byte for byte (run_alias).
Standard library only; Python 3.9+.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from typing import Any, Callable, Dict, List, Optional

import relay_replies as rr
from relay_client import RelayError

FORMATS = ("claude", "gemini", "kiro", "cursor", "copilot", "plain")
WHENS = ("prompt", "session-start")
SESSION_START = {"cursor", "copilot"}                       # default --when per format
# Under Claude Code's 10 000-character hook output, and room for one whole 8000-character
# owner text (relay_replies.TEXT_CAP) with its line.
CONTEXT_CAP = 9800
MORE = "… more in relay list"
PROBE_OK = "hook replies: ok"
SESSION_KEYS = ("session_id", "sessionId", "conversation_id")
EVENT_NAMES = {"claude": "UserPromptSubmit", "gemini": "BeforeAgent"}


class _Exit(Exception):
    def __init__(self, status: int) -> None:
        super().__init__(status)
        self.status = status


def _parser(out: Any, err: Any) -> argparse.ArgumentParser:
    class Parser(argparse.ArgumentParser):
        def _print_message(self, message: str, file: Any = None) -> None:
            if message:
                (out if file is sys.stdout else err).write(message)

        def exit(self, status: int = 0, message: Optional[str] = None) -> None:  # type: ignore[override]
            if message:
                err.write(message)
            raise _Exit(status)

    parser = Parser(prog="relay hook", description="Hook's commands for agent harness hooks.")
    sub = parser.add_subparsers(dest="command", metavar="<command>", parser_class=Parser)
    replies = sub.add_parser("replies", help="the owner's new answers, in a harness's hook format")
    replies.add_argument("--format", required=True, choices=FORMATS)
    replies.add_argument("--when", choices=WHENS, default=None,
                         help="prompt (a cursor per session) or session-start (the last 24 h); "
                              "default session-start for cursor and copilot, else prompt")
    replies.add_argument("--probe", action="store_true", help="print that the command runs, and nothing else")
    return parser


def read_session(stdin: Any) -> Optional[str]:
    """session_id | sessionId | conversation_id from ≤1 MiB of JSON on stdin (0.5 s wait); None for
    a TTY, empty, oversized or non-JSON input. The rest of the payload (the prompt) is dropped."""
    if stdin is None:
        return None
    try:
        if stdin.isatty():
            return None
    except (AttributeError, OSError, ValueError):
        pass
    try:
        raw = rr._read_limited(stdin, rr.HOOK_STDIN_LIMIT + 1, rr.HOOK_STDIN_WAIT_S)
    except (AttributeError, OSError, ValueError):
        return None
    if not raw or len(raw) > rr.HOOK_STDIN_LIMIT:
        return None
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None
    del raw
    if not isinstance(payload, dict):
        return None
    for key in SESSION_KEYS:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


# The formats whose context goes out inside a JSON string (emit), escaped.
JSON_FORMATS = {"claude", "gemini", "cursor", "copilot"}


def _escaped_size(text: str) -> int:
    """`text`'s length inside a JSON string as emit writes it (é as \\u00e9, " as \\")."""
    return len(json.dumps(text)) - 2


def cap(lines: List[str], limit: int = CONTEXT_CAP, escaped: bool = False) -> List[str]:
    """The lines, cut at a line boundary so that they and MORE fit in `limit` characters.
    With `escaped`, the size counted is the JSON-escaped one (each joining newline is \\n),
    so a context full of escapes can't take the hook's output past the limit."""
    size_of = _escaped_size if escaped else len
    newline = size_of("\n")
    if size_of("\n".join(lines)) <= limit:
        return lines
    kept: List[str] = []
    size = size_of(MORE)
    for line in lines:
        if size + size_of(line) + newline > limit:
            break
        kept.append(line)
        size += size_of(line) + newline
    return kept + [MORE]


def emit(lines: List[str], fmt: str, when: str) -> str:
    """What the hook prints for these lines: "" when there are none."""
    if not lines:
        return ""
    text = "\n".join(lines)
    if fmt in ("claude", "gemini"):
        name = "SessionStart" if when == "session-start" else EVENT_NAMES[fmt]
        body: Dict[str, Any] = {"hookSpecificOutput": {"hookEventName": name, "additionalContext": text}}
    elif fmt == "cursor":
        body = {"additional_context": text}
    elif fmt == "copilot":
        body = {"additionalContext": text}
    else:
        return text + "\n"
    return json.dumps(body) + "\n"


def run(argv: List[str], *, stdin: Any, out: Any, err: Any, client_factory: Callable[..., Any],
        env: Optional[Dict[str, str]] = None, ppid: Callable[[], int] = os.getppid,
        now: Optional[Callable[[], datetime.datetime]] = None,
        monotonic: Optional[Callable[[], float]] = None) -> int:
    """`relay hook <argv>`. Always 0."""
    try:
        args = _parser(out, err).parse_args(argv)
    except _Exit:
        return 0
    if args.command != "replies":
        err.write("relay hook: say which command, e.g. relay hook replies --format plain\n")
        return 0
    if args.probe:
        out.write(PROBE_OK + "\n")
        return 0
    when = args.when or ("session-start" if args.format in SESSION_START else "prompt")
    try:
        if when == "prompt":
            session = read_session(stdin)
            key = "session:" + (session if session else f"ppid-{ppid()}")
            client = client_factory(autolaunch=False, timeout=rr.HOOK_BUDGET_S)
            lines, partial = rr.collect(client, key, session_id=session or "", monotonic=monotonic)
        else:
            client = client_factory(autolaunch=False, timeout=rr.HOOK_BUDGET_S)
            lines, partial = rr.recent(client, now=now() if now else None, monotonic=monotonic)
        text = emit(cap(lines, escaped=args.format in JSON_FORMATS), args.format, when)
    except rr.OutOfTime:
        err.write("hook replies: ran out of time\n")
        return 0
    except RelayError as exc:
        err.write(f"hook replies: {exc}\n")
        return 0
    except Exception as exc:  # noqa: BLE001 — a hook must never fail a prompt
        err.write(f"hook replies: internal error: {type(exc).__name__}\n")
        return 0
    try:
        out.write(text)
        if partial:
            err.write("hook replies: stopped at the time budget; the rest shows next time\n")
    except (OSError, ValueError):
        pass
    return 0


def run_alias(*, new: bool, stdin: Any, out: Any, err: Any, client_factory: Callable[..., Any]) -> int:
    """`relay replies [--new] --hook`, the 0.12 hook: `--format plain --when prompt` with its 0.12
    output byte for byte. It needs `session_id` (no ppid fallback, no context cap), as before."""
    try:
        session_id = rr.read_hook_session(stdin)
        client = client_factory(autolaunch=False, timeout=rr.HOOK_BUDGET_S)
        rr.run(client, new=new, hook=True, session_id=session_id, out=out, err=err)
    except RelayError as exc:
        err.write(f"relay replies: {exc}\n")
    except Exception as exc:  # noqa: BLE001
        err.write(f"relay replies: internal error: {type(exc).__name__}\n")
    return 0
