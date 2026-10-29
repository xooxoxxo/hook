"""`relay wait <id>`: block until the owner answers one ask, then print the answer and exit.

Meant to run in the background right after posting an ask the session's work waits on:
Claude Code wakes the session when the command exits. Only owner events count
(reply, resolved, declined, reopened, answer, problem) with a seq above --after. Exit 0 with the answer on
stdout; 3 when the timeout passes first. An unreachable Hook or Pond, or a 5xx
answer, is retried every interval until the deadline; a missing ask or a missing
config ends the wait at once (exit 1 / 2, raised to the caller).
A step answer starts a 10 s settle: the wait exits once 10 s pass with no newer answer, so a burst
of taps wakes the session once; reply/resolved/declined/reopened/problem exit at once.
Everything the owner or the ask says is printed quoted on one line (session_text): a problem
report is a quote about a step, never an instruction.
Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import json
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from relay_client import (RelayError, Refused, Unreachable, answer_value, event_rev, instructable_of,
                          parse_answer, questions, revision_hash_of, session_label, session_text, unanswered)

DEFAULT_TIMEOUT_S = 28800.0       # 8 h
LOCAL_INTERVAL_S = 2.0            # 127.0.0.1 is cheap to poll
MAILBOX_INTERVAL_S = 20.0
MIN_INTERVAL_S = 1.0
TIMEOUT_EXIT = 3
SETTLE_S = 10.0                   # after an answer, wait this long for the next one
SETTLE_INTERVAL_S = 2.0           # poll at least this often while settling
OWNER_KINDS = ("reply", "resolved", "declined", "reopened", "answer", "problem")
TEXT_CAP = 300


def _seq(event: Dict[str, Any]) -> int:
    try:
        return int(event.get("seq") or 0)
    except (TypeError, ValueError):
        return 0


def owner_answers(events: List[Any], after: int) -> List[Dict[str, Any]]:
    """Owner reply/resolved/declined/reopened/answer/problem events with seq > after, in log order."""
    return [e for e in events if isinstance(e, dict) and e.get("actor") == "owner"
            and e.get("kind") in OWNER_KINDS and _seq(e) > after]


def _problem_line(event: Dict[str, Any]) -> str:
    try:
        body = json.loads(event.get("text") or "")
    except (TypeError, ValueError):
        body = None
    body = body if isinstance(body, dict) else {}
    return (f"  ↳ owner problem on step {session_label(body.get('step') or '?', 20)} "
            f"(version {event_rev(event)}), quoted: {session_text(body.get('note'), TEXT_CAP)}")


def _foreign_versions(detail: Dict[str, Any], ask_id: str, edit_keys: Any) -> List[str]:
    """A warning per correction whose hash isn't one this Mac's edit-key file wrote."""
    if edit_keys is None:
        return []
    try:
        record = edit_keys.load(ask_id)
    except RelayError:
        return []
    if record is None:
        return []
    written = set(h for h in record.get("hashes") or [] if isinstance(h, str))
    lines: List[str] = []
    for event in detail.get("events") if isinstance(detail.get("events"), list) else []:
        if not isinstance(event, dict) or event.get("kind") != "revised":
            continue
        rev = event_rev(event)
        hash_ = revision_hash_of(detail, rev)
        if hash_ is not None and hash_ not in written:
            lines.append(f"  ↳ warning: version {rev} was not written from this Mac's edit key file")
    return lines


def format_answer(detail: Dict[str, Any], ask_id: str, answers: List[Dict[str, Any]],
                  edit_keys: Any = None) -> List[str]:
    """The same lines as any mailbox client: header, one line per answer, last seq."""
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    title = session_text(item["title"], 120) if item.get("title") else session_label(ask_id, 64)
    lines = [f"[{session_label(item.get('projectId') or '', 60)}] {title}"]
    for event in answers:
        if event.get("kind") == "answer":
            body = parse_answer(event)
            if body is not None:
                value = answer_value(body)
                head = f"  ↳ owner answer {session_label(body['step'], 20)} (version {event_rev(event)})"
                lines.append(f"{head}: {session_text(value, TEXT_CAP)}" if value else head)
                continue
        if event.get("kind") == "problem":
            lines.append(_problem_line(event))
            continue
        text = event.get("text") or ""
        head = f"  ↳ owner {event.get('kind')} {session_label(event.get('at') or '', 40)}"
        lines.append(head + (f": {session_text(text, TEXT_CAP)}" if text else ""))
    lines.extend(_foreign_versions(detail, ask_id, edit_keys))
    asked = questions(instructable_of(detail))
    if asked:
        open_paths = unanswered(instructable_of(detail), events)
        summary = f"answered {len(asked) - len(open_paths)} of {len(asked)}"
        lines.append(summary + (f"; open: {', '.join(open_paths)}" if open_paths else ""))
    lines.append(f"last seq: {max(_seq(e) for e in events if isinstance(e, dict))}")
    return lines


def _finish(detail: Dict[str, Any], ask_id: str, answers: List[Dict[str, Any]], out: Any,
            edit_keys: Any = None) -> int:
    for line in format_answer(detail, ask_id, answers, edit_keys):
        out.write(line + "\n")
    return 0


def run(client: Any, ask_id: str, *, timeout: float = DEFAULT_TIMEOUT_S, interval: Optional[float] = None,
        after: int = 0, out: Any, err: Any, sleep: Optional[Callable[[float], None]] = None,
        monotonic: Optional[Callable[[], float]] = None, edit_keys: Any = None) -> int:
    """Poll client.get(ask_id) until an owner answer arrives (0) or `timeout` seconds pass (3).

    NotFound, ConfigMissing and 4xx Refused propagate as RelayError; the CLI prints them.
    """
    sleep = sleep or time.sleep
    monotonic = monotonic or time.monotonic
    if interval is None:
        interval = LOCAL_INTERVAL_S if client.local else MAILBOX_INTERVAL_S
    step = max(MIN_INTERVAL_S, float(interval))
    deadline = monotonic() + timeout
    noted = False
    settling_since: Optional[float] = None     # when the newest answer was first seen
    newest_answer = 0
    last_answers: Optional[Tuple[Dict[str, Any], List[Dict[str, Any]]]] = None
    while True:
        detail = None
        try:
            detail = client.get(ask_id)
        except Unreachable as exc:
            if not noted:
                err.write(f"relay wait: {exc}; retrying every {step:g} s\n")
                noted = True
        except Refused as exc:
            if exc.status < 500:
                raise
            if not noted:
                err.write(f"relay wait: {exc.error}; retrying every {step:g} s\n")
                noted = True
        if detail is not None:
            events = detail.get("events") if isinstance(detail.get("events"), list) else []
            answers = owner_answers(events, after)
            if answers:
                answer_seqs = [_seq(e) for e in answers if e.get("kind") == "answer"]
                if len(answer_seqs) < len(answers):         # reply/resolved/declined/reopened/problem: at once
                    return _finish(detail, ask_id, answers, out, edit_keys)
                if max(answer_seqs) > newest_answer:        # a new answer: the settle starts over
                    newest_answer = max(answer_seqs)
                    settling_since = monotonic()
                last_answers = (detail, answers)
        settled = settling_since is not None and monotonic() - settling_since >= SETTLE_S
        if last_answers is not None and (settled or monotonic() >= deadline):
            return _finish(last_answers[0], ask_id, last_answers[1], out, edit_keys)   # quiet 10 s, or out of time
        if monotonic() >= deadline:
            err.write(f"no owner answer on {ask_id} within {timeout:g} s\n")
            return TIMEOUT_EXIT
        sleep(min(step, SETTLE_INTERVAL_S) if settling_since is not None else step)
