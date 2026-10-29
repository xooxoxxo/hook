"""The `relay` command (also linked as `hook`): post an instructable, check on it, list, resolve, read replies.

Exit codes: 0 ok, 1 refused / not found / bad input, 2 no config or Hook unreachable,
3 `wait` saw no owner answer before its timeout.
Standard library only; runs on Python 3.9+.

Test-only switch: RELAY_NO_AUTOLAUNCH=1 turns auto-launch off for every command, so a
test or smoke run against a temp Hook never opens the installed app.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Callable, Dict, List, Optional

import relay_replies
import relay_wait
from relay_client import (OWNER_LABELS, VERSION, Client, EditKeys, PondTooOld, Refused, RelayError, accepted_rev,
                          answer_value, answers_with_state, event_rev, instructable_of, questions, revision_of,
                          session_label, session_text)

DEFAULT_TIMEOUT = 10.0
SUBSTEPS_SENTENCE = ("A step that needs more than one action can hold `substeps`: 1 to 10 step objects "
                     "(same keys, no nesting, not on verify), shown indented and ticked one by one. "
                     "At most 60 steps and sub-steps in total.")
QUESTIONS_SENTENCE = ("Any step or sub-step (not verify) can hold a `question` {prompt, choices 0-6, multi}: "
                      "the owner answers it per step without closing the ask, so bundle related questions "
                      "into one ask. At most 20. Read the answers with relay_status, relay status or relay wait.")
BLOCKING_SENTENCE = ("A step or sub-step (not verify) can set `blocking: true` when the next steps can't "
                     "start without it: the owner can't open later steps until it is done. Use it only when "
                     "later steps fail without it, and put the reason in `warning` (at most 300 chars). "
                     "`warning` alone shows a caution box. A Pond that is too old refuses these keys.")
OPTIONAL_SENTENCE = ("A step or sub-step (not verify) can set `optional: true` when the owner may finish it "
                     "without doing or answering it, e.g. a feedback question or a nice-to-have; it can't "
                     "also be blocking. On a step with sub-steps it makes every sub-step optional. "
                     "A Pond that is too old refuses this key.")
FILES_SENTENCE = ("When the owner should read a document, write it as a Markdown file and point to it with "
                  "`file` on a step or sub-step (not verify), or with a link that has `path` instead of `url`: "
                  "an absolute path (/... or ~/...) on the owner's Mac, which Hook opens rendered. Keep `do` to "
                  "one action and `detail` to a few lines; never paste a whole document into an ask. "
                  "A Pond that is too old refuses these keys.")


AMEND_SENTENCE = ("Send the whole corrected instructable: keep every step's `id` and leave ids out only on new "
                  "steps. Only the process that posted the ask holds its edit key. The owner reviews the change "
                  "in Hook before acting on it.")
OWNER_TEXT_CAP = 300


class _ParserExit(Exception):
    def __init__(self, status: int) -> None:
        super().__init__(status)
        self.status = status


# The names the CLI answers to: `relay`, and `hook` since the rename. Messages use the
# name it was run as; anything else (python3 relay_cli.py) is `relay`.
NAMES = ("relay", "hook")


def invoked_name(argv0: Optional[str]) -> str:
    name = os.path.basename(argv0 or "")
    return name if name in NAMES else "relay"


def _parser(out: Any, err: Any, prog: str = "relay") -> argparse.ArgumentParser:
    class Parser(argparse.ArgumentParser):
        """argparse that writes to the given streams and never calls sys.exit."""

        def _print_message(self, message: str, file: Any = None) -> None:
            if message:
                (out if file is sys.stdout else err).write(message)

        def exit(self, status: int = 0, message: Optional[str] = None) -> None:  # type: ignore[override]
            if message:
                err.write(message)
            raise _ParserExit(status)

    parser = Parser(prog=prog, description="Send the owner instructables through Hook and read the answers.")
    parser.add_argument("--version", action="store_true", help="print the version and exit")
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    post = sub.add_parser("post", help="post one instructable",
                          description=" ".join((SUBSTEPS_SENTENCE, QUESTIONS_SENTENCE, BLOCKING_SENTENCE,
                                                OPTIONAL_SENTENCE, FILES_SENTENCE)))
    post.add_argument("project")
    post.add_argument("--json", dest="json_src", required=True, metavar="FILE|-",
                      help="the instructable, from a file or - for stdin")
    status = sub.add_parser("status", help="status of one ask and the owner's answers")
    status.add_argument("id")
    status.add_argument("--json", action="store_true")
    listing = sub.add_parser("list", help="open asks")
    listing.add_argument("--json", action="store_true")
    for name, text in (("done", "mark an ask done"), ("skip", "skip (decline) an ask")):
        cmd = sub.add_parser(name, help=text)
        cmd.add_argument("id")
        cmd.add_argument("note", nargs="?")
    replies = sub.add_parser("replies", help="new owner answers")
    replies.add_argument("--new", action="store_true", help="remember what was shown")
    replies.add_argument("--hook", action="store_true", help="run as a UserPromptSubmit hook; always exits 0")
    wait = sub.add_parser("wait", help="wait for the owner's answer to one ask (run it in the background)")
    wait.add_argument("id")
    wait.add_argument("--timeout", type=float, default=28800.0, metavar="SECONDS",
                      help="give up after this many seconds and exit 3 (default 8 h)")
    wait.add_argument("--interval", type=float, default=None, metavar="SECONDS",
                      help="seconds between checks, at least 1 (default 2 on This Mac, 20 with a Pond)")
    wait.add_argument("--after", type=int, default=0, metavar="SEQ",
                      help="only answers after this event seq (the last seq a previous wait printed)")
    amend = sub.add_parser("amend", help="correct an open ask you posted (the owner reviews it in Hook)",
                           description=AMEND_SENTENCE)
    amend.add_argument("id")
    amend.add_argument("--reason", required=True, metavar="TEXT",
                       help="what was wrong and what changed, one line (at most 200 chars)")
    amend.add_argument("--base", type=int, default=None, metavar="REV",
                       help="the version you corrected (default: the newest, if this Mac wrote it)")
    amend.add_argument("--json", dest="json_src", default="-", metavar="FILE|-",
                       help="the whole corrected instructable, from a file or - for stdin (the default)")
    return parser


class _Ctx:
    def __init__(self, stdin: Any, out: Any, err: Any, factory: Callable[..., Any],
                 env: Optional[Dict[str, str]] = None) -> None:
        self.stdin, self.out, self.err, self.factory = stdin, out, err, factory
        self.env = env

    def say(self, line: str) -> None:
        self.out.write(line + "\n")


def resolved_by(events: list) -> Optional[str]:
    """Actor of the last resolved/declined event; None when a reopen came after it."""
    for event in reversed(events or []):
        if not isinstance(event, dict):
            continue
        if event.get("kind") == "reopened":
            return None
        if event.get("kind") in ("resolved", "declined"):
            actor = event.get("actor")
            return actor if isinstance(actor, str) else None
    return None


def problems(detail: dict) -> List[Dict[str, Any]]:
    """The owner's problem reports: [{"id", "step", "note", "rev", "at"}], oldest first."""
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    found: List[Dict[str, Any]] = []
    for event in events:
        if not isinstance(event, dict) or event.get("kind") != "problem" or event.get("actor") != "owner":
            continue
        try:
            body = json.loads(event.get("text") or "")
        except (TypeError, ValueError):
            body = None
        body = body if isinstance(body, dict) else {}
        found.append({"id": body.get("id"), "step": body.get("step"), "note": body.get("note"),
                      "rev": event_rev(event), "at": event.get("at")})
    return found


def format_status(detail: dict) -> list:
    """`relay status`: owner text and answers quoted on one line each (session_text), so nothing
    the owner or an ask says can pass for a line of its own."""
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    status = item.get("status") or "?"
    title = session_text(item["title"], 120) if item.get("title") else "?"
    where = f"{session_label(item.get('projectId') or '?', 60)} · {title}"
    by = None if status == "open" else resolved_by(events)
    lines = [f"{status} (by {by}) · {where}" if by else f"{status} · {where}"]
    current = revision_of(detail)
    if current is not None and current["rev"] > 1:
        lines.append(f"version {current['rev']}, accepted by the owner: version {accepted_rev(detail)}")
    for event in events:
        if not isinstance(event, dict) or event.get("actor") != "owner":
            continue
        at = session_label(event.get("at") or "?", 40)
        if event.get("kind") == "problem":
            continue
        if event.get("kind") == "accepted":
            lines.append(f"{at} accepted version {event_rev(event)}")
            continue
        label = OWNER_LABELS.get(event.get("kind"))
        if label is None:
            continue
        text = event.get("text") or ""
        lines.append(f"{at} {label}: {session_text(text, OWNER_TEXT_CAP)}" if text else f"{at} {label}")
    for problem in problems(detail):
        lines.append(f"{session_label(problem['at'] or '?', 40)} problem on step "
                     f"{session_label(problem['step'] or '?', 20)} (version {problem['rev']}), quoted: "
                     f"{session_text(problem['note'], OWNER_TEXT_CAP)}")
    asked = questions(instructable_of(detail))
    if asked:
        given = answers_with_state(detail)
        open_paths = _unanswered(asked, given)
        lines.append(f"Answers ({len(asked) - len(open_paths)} of {len(asked)}):")
        for path, question in asked.items():
            prompt = str(question.get("prompt") or "").strip().split("\n")[0]
            lines.append(f"  {path}  {session_text(prompt, 120)}")
            if path in given:
                answer = given[path]
                note = f" (version {answer['rev']}, an earlier question)" if answer["stale"] else ""
                lines.append("     " + session_text(answer_value(answer), OWNER_TEXT_CAP) + note)
        if open_paths:
            lines.append("Unanswered: " + ", ".join(open_paths))
    return lines


def _unanswered(asked: Dict[str, Any], given: Dict[str, Dict[str, Any]]) -> List[str]:
    """Question paths without a current answer: an answer to an earlier question doesn't count."""
    return [path for path in asked if path not in given or given[path]["stale"]]


def answers_json(detail: dict) -> Dict[str, Any]:
    """{"answers": {path: {picked|text, at, rev, stale, verified}}, "unanswered": [path, ...]} for status
    --json and MCP. `stale`: the owner answered an earlier version of the question; `verified`: the
    answer came with Hook's owner key or from Telegram."""
    given = answers_with_state(detail)
    answers = {}
    for path, a in given.items():
        value = {k: v for k, v in a.items() if k in ("picked", "text", "at", "rev", "stale")}
        value["verified"] = a.get("auth") in ("owner-key", "telegram")
        answers[path] = value
    return {"answers": answers, "unanswered": _unanswered(questions(instructable_of(detail)), given)}


def revision_json(detail: dict, editable: bool) -> Dict[str, Any]:
    """The version fields of status --json and relay_status: rev, hash, acceptedRev, the current
    instructable (with step ids), the owner's problem reports, and whether this Mac can correct it."""
    current = revision_of(detail)
    return {"rev": current["rev"] if current is not None else 1,
            "hash": current["hash"] if current is not None else None,
            "acceptedRev": accepted_rev(detail), "instructable": instructable_of(detail),
            "problems": problems(detail), "editable": editable}


def is_editable(ask_id: Any, env: Optional[Dict[str, str]] = None) -> bool:
    """Is there an edit-key file for this ask on this Mac? An unreadable folder counts as no."""
    try:
        record = EditKeys(env).load(str(ask_id or ""))
    except RelayError:
        return False
    return record is not None and isinstance(record.get("key"), str)


def _status_json(detail: dict, editable: bool = False) -> Dict[str, Any]:
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    status = item.get("status")
    return {"id": item.get("id"), "status": status,
            "resolvedBy": resolved_by(events) if status != "open" else None,
            "project": item.get("projectId"), "title": item.get("title"),
            "ownerEvents": [{"kind": e.get("kind"), "text": e.get("text"), "at": e.get("at")}
                            for e in events if isinstance(e, dict) and e.get("actor") == "owner"],
            **answers_json(detail), **revision_json(detail, editable)}


def _read_instructable(src: str, stdin: Any) -> Dict[str, Any]:
    """--json - or --json FILE, decoded as utf-8-sig so a BOM is accepted."""
    try:
        if src == "-":
            buffer = getattr(stdin, "buffer", None)
            if buffer is not None:
                text = buffer.read().decode("utf-8-sig")
            else:
                text = stdin.read()
                text = text[1:] if text.startswith("\ufeff") else text
        else:
            with open(src, encoding="utf-8-sig") as fh:
                text = fh.read()
    except UnicodeDecodeError:
        raise RelayError("--json input isn't UTF-8") from None
    except OSError as exc:
        raise RelayError(f"can't read {src}: {exc.strerror}") from None
    try:
        obj = json.loads(text)
    except ValueError as exc:
        raise RelayError(f"--json input isn't valid JSON: {exc}") from None
    if not isinstance(obj, dict):
        raise RelayError("--json input must be a JSON object")
    return obj


def _cmd_post(args: argparse.Namespace, ctx: _Ctx) -> int:
    instructable = _read_instructable(args.json_src, ctx.stdin)
    res = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT).post(args.project, instructable)
    item = res.get("item") if isinstance(res.get("item"), dict) else {}
    ctx.say(("deduped " if res.get("deduped") else "posted ") + str(item.get("id")))
    if res.get("openUrl"):
        ctx.say("open " + str(res["openUrl"]))
    return 0


def _cmd_status(args: argparse.Namespace, ctx: _Ctx) -> int:
    detail = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT).get(args.id)
    if args.json:
        editable = is_editable(args.id.strip(), ctx.env)
        ctx.say(json.dumps(_status_json(detail, editable), ensure_ascii=False, indent=2))
    else:
        for line in format_status(detail):
            ctx.say(line)
    return 0


def _urgency(item: Dict[str, Any]) -> str:
    payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
    instructable = payload.get("instructable") if isinstance(payload.get("instructable"), dict) else {}
    urgency = instructable.get("urgency")
    return urgency if isinstance(urgency, str) and urgency else "today"


def _cmd_list(args: argparse.Namespace, ctx: _Ctx) -> int:
    items = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT).list("open", 36500)
    if args.json:
        ctx.say(json.dumps(items, ensure_ascii=False, indent=2))
        return 0
    for item in items:
        ctx.say(f"{item.get('id')} {_urgency(item)} {item.get('projectId') or '?'} · {item.get('title') or '?'}")
    return 0


def _resolve(args: argparse.Namespace, ctx: _Ctx, verdict: str, word: str) -> int:
    client = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT)
    detail = client.get(args.id)
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    status = item.get("status")
    if status and status != "open":
        # A mailbox would resolve a finished ask again; say who finished it instead.
        by = resolved_by(detail.get("events") if isinstance(detail.get("events"), list) else [])
        ctx.say(f"already {status} (by {by}) {args.id}" if by else f"already {status} {args.id}")
        return 0
    res = client.resolve(args.id, verdict, args.note)
    done = res.get("item") if isinstance(res.get("item"), dict) else {}
    ctx.say(f"{word} {done.get('id') or args.id}")
    return 0


def _cmd_done(args: argparse.Namespace, ctx: _Ctx) -> int:
    return _resolve(args, ctx, "done", "done")


def _cmd_skip(args: argparse.Namespace, ctx: _Ctx) -> int:
    return _resolve(args, ctx, "declined", "skipped")


def _cmd_replies(args: argparse.Namespace, ctx: _Ctx) -> int:
    if not args.hook:
        client = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT)
        return relay_replies.run(client, new=args.new, hook=False, session_id=None, out=ctx.out, err=ctx.err)
    # Hook: never auto-launch, 2 s budget, nothing on stdout on failure, always exit 0.
    try:
        session_id = relay_replies.read_hook_session(ctx.stdin)
        client = ctx.factory(autolaunch=False, timeout=relay_replies.HOOK_BUDGET_S)
        relay_replies.run(client, new=args.new, hook=True, session_id=session_id, out=ctx.out, err=ctx.err)
    except RelayError as exc:
        ctx.err.write(f"relay replies: {exc}\n")
    except Exception as exc:  # noqa: BLE001
        ctx.err.write(f"relay replies: internal error: {type(exc).__name__}\n")
    return 0


def _cmd_wait(args: argparse.Namespace, ctx: _Ctx) -> int:
    # Never auto-launch: the wait can outlive a quit Hook, and an unreachable source is retried.
    client = ctx.factory(autolaunch=False, timeout=DEFAULT_TIMEOUT)
    return relay_wait.run(client, args.id, timeout=args.timeout, interval=args.interval, after=args.after,
                          out=ctx.out, err=ctx.err, edit_keys=EditKeys(ctx.env))


def change_summary(revision: Any) -> str:
    """"changed: step 3, verify; added: step 4" from an amend result's revision, or ""."""
    revision = revision if isinstance(revision, dict) else {}

    def paths(key: str, field: str = "path") -> List[str]:
        entries = revision.get(key) if isinstance(revision.get(key), list) else []
        return [str(e.get(field)) for e in entries if isinstance(e, dict) and e.get(field) is not None]

    def steps(found: List[str]) -> List[str]:
        return [("step " if len(found) == 1 else "steps ") + ", ".join(found)] if found else []

    top = [str(t) for t in revision.get("top") or [] if isinstance(t, str)]
    moved = [f"step {e.get('from')} → {e.get('to')}" for e in revision.get("moved") or []
             if isinstance(e, dict)]
    parts = []
    for label, found in (("changed", steps(paths("changed")) + top), ("added", steps(paths("added"))),
                         ("removed", steps(paths("removed"))), ("moved", moved)):
        if found:
            parts.append(f"{label}: " + ", ".join(found))
    return "; ".join(parts)


def _cmd_amend(args: argparse.Namespace, ctx: _Ctx) -> int:
    instructable = _read_instructable(args.json_src, ctx.stdin)
    client = ctx.factory(autolaunch=True, timeout=DEFAULT_TIMEOUT)
    res = client.amend(args.id, args.reason, instructable, args.base, edit_keys=EditKeys(ctx.env))
    revision = res.get("revision") if isinstance(res.get("revision"), dict) else {}
    summary = change_summary(revision)
    ctx.say(f"corrected {args.id.strip()} → version {revision.get('rev', '?')}"
            + (f" ({summary})" if summary else "")
            + ". The owner must review it in Hook before acting.")
    if res.get("warning"):
        ctx.err.write(f"warning: {res['warning']}\n")
    return 0


COMMANDS: Dict[str, Callable[[argparse.Namespace, _Ctx], int]] = {
    "post": _cmd_post, "status": _cmd_status, "list": _cmd_list,
    "done": _cmd_done, "skip": _cmd_skip, "replies": _cmd_replies, "wait": _cmd_wait, "amend": _cmd_amend,
}


def _default_factory(env: Optional[Dict[str, str]]) -> Callable[..., Any]:
    no_autolaunch = (env if env is not None else os.environ).get("RELAY_NO_AUTOLAUNCH") == "1"

    def factory(**kw: Any) -> Client:
        if no_autolaunch:
            kw["autolaunch"] = False
        return Client(env=env, kind="cli", **kw)
    return factory


def main(argv: Optional[List[str]] = None, *, stdin: Any = None, stdout: Any = None, stderr: Any = None,
         env: Optional[Dict[str, str]] = None, client_factory: Optional[Callable[..., Any]] = None,
         prog: Optional[str] = None) -> int:
    prog = prog if prog is not None else invoked_name(sys.argv[0] if sys.argv else None)
    argv = sys.argv[1:] if argv is None else list(argv)
    out = stdout if stdout is not None else sys.stdout
    err = stderr if stderr is not None else sys.stderr
    stdin = stdin if stdin is not None else sys.stdin
    factory = client_factory or _default_factory(env)
    parser = _parser(out, err, prog)
    try:
        args = parser.parse_args(argv)
    except _ParserExit as exc:
        return 0 if "--hook" in argv else exc.status   # a hook must never block the prompt
    if args.version:
        out.write(f"{prog} {VERSION}\n")
        return 0
    if not args.command:
        parser.print_usage(err)
        return 2
    ctx = _Ctx(stdin, out, err, factory, env)
    try:
        return COMMANDS[args.command](args, ctx)
    except PondTooOld as exc:
        err.write(f"{prog}: {exc.error}\n")
        return exc.exit_code
    except Refused as exc:
        err.write(f"refused: {exc.error}\n")
        for detail in exc.details:
            err.write(f"  {detail}\n")
        return exc.exit_code
    except RelayError as exc:
        err.write(f"{prog}: {exc}\n")
        return exc.exit_code


if __name__ == "__main__":
    sys.exit(main())
