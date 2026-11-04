"""The Claude Code migration of `relay integrations`: from the old setup to the Hook plugin and
~/.claude/rules/hook.md. Standard library only (Python 3.9).

Before 0.13, install.sh added a `claude mcp` server, a skill symlink in ~/.claude/skills, and
the app's buttons a replies hook in ~/.claude/settings.json; the owner pasted
docs/claude-md-section.md into ~/.claude/CLAUDE.md. Once the plugin and the rules file are
installed (so no session ever loses the hook or the text), each step below runs, idempotent,
recorded in manifest.migrations as {"id": "claude-<step>", "state", ...}:

1. mcp    The engine adopts a server whose JSON equals Hook's, replaces one that points at
          another */mcp/relay_mcp.py, and leaves anything else (foreign). This records which.
2. skill  A symlink to */skill/instructables beside an mcp/relay_mcp.py, or a dangling one into
          ~/.local/share/hook, is removed: the plugin carries the skill. A real folder or another
          link is foreign and stays.
3. hook   Every inner hook in hooks.UserPromptSubmit whose command runs `relay replies --new` or
          `hook replies --new` is removed, with a .bak first; nothing else in the file changes.
          Only after the plugin's own hook command runs: each `hook replies` command in the
          rendered plugin's hooks file is run once with --probe and must print PROBE_OK
          (a relay from before `hook replies` doesn't); until then the old hook stays (waiting).
4. md     The "Owner asks go to Hook|Relay" section (by heading) or a Hook instructions block:
          a released Hook text goes at once (.bak first); a hand-written one gets a proposal
          file and one ask (Apply / Remove the whole section / Keep CLAUDE.md as is). The answer
          applies at the next sync, only while the section is the one proposed; Keep is never
          asked again unless --again. Uninstall never puts the section back; it names the .bak.
"""
from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import relay_edits as ed

HID = "claude-code"
MIGRATED = "<!-- hook:migrated v=1 -->"
POINTER = "Hook's own rules are in `~/.claude/rules/hook.md`."
HEADING = re.compile(r"^(#{1,6})\s+Owner asks go to (Hook|Relay)\b.*$")
ATX = re.compile(r"^(#{1,6})(\s|$)")
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
BLOCK_BEGIN = re.compile(r"^<!--\s*hook:begin\s+id=instructions\b.*-->\s*$")
BLOCK_END = re.compile(r"^<!--\s*hook:end\s*-->\s*$")
STAMP = re.compile(r"^<!--\s*hook:instructions\b.*-->\s*$")
LIST_ITEM = re.compile(r"^\s{0,3}([-*+]|\d+[.)])\s+")
APPLY, REMOVE, KEEP = "Apply", "Remove the whole section", "Keep CLAUDE.md as is"
CHOICES = (APPLY, REMOVE, KEEP)
TITLE = "Move the Hook section out of ~/.claude/CLAUDE.md"
RETITLE = "Review the new proposal for the Hook section in ~/.claude/CLAUDE.md"
QUESTION_STEP = "2"
HOOK_PATHS = ("~/.local/share/hook", "~/.config/relay", "~/.local/bin/relay", "~/.local/bin/hook",
              "~/.claude/rules/hook.md")
HOOK_WORDS = frozenset(("relay", "hook", "relay_post", "relay_status", "relay_list", "relay_amend", "relay_wait"))
PATH_TOKEN = re.compile(r"(?<![\w~.:/@-])(~/[^\s`'\"()<>\[\],;]*|/[A-Za-z0-9._-]+/[^\s`'\"()<>\[\],;]*)")
SLASH_COMMAND = re.compile(r"(?<![\w/.~:-])/[a-z][a-z0-9-]*(?![\w/.-])")
BACKTICKS = re.compile(r"`([^`\n]+)`")
LEGACY_HOOK = ("relay replies --new", "hook replies --new")


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _iso(now: datetime) -> str:
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- finding the section -------------------------------------------------------------------

@dataclass
class Section:
    start: int          # offsets into the text; end is exclusive and takes the trailing blank lines
    end: int
    heading: str        # the heading line (or the block's begin line), without its newline
    text: str
    kind: str           # "heading" | "block"


def _lines(text: str) -> List[Tuple[int, str]]:
    out, pos = [], 0
    for line in text.splitlines(keepends=True):
        out.append((pos, line))
        pos += len(line)
    return out


def _section(text: str) -> Optional[Section]:
    lines = _lines(text)
    fence: Optional[str] = None
    for k, (pos, raw) in enumerate(lines):
        line = raw.rstrip("\r\n")
        m = FENCE.match(line)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        hm = HEADING.match(line)
        if hm:
            following = lines[k + 1][1].strip() if k + 1 < len(lines) else ""
            if following == MIGRATED:
                continue
            level = len(hm.group(1))
            end = len(text)
            inner: Optional[str] = None
            for pos2, raw2 in lines[k + 1:]:
                l2 = raw2.rstrip("\r\n")
                m2 = FENCE.match(l2)
                if inner is not None:
                    if m2 and m2.group(1)[0] == inner[0] and len(m2.group(1)) >= len(inner):
                        inner = None
                    continue
                if m2:
                    inner = m2.group(1)
                    continue
                a = ATX.match(l2)
                if a and len(a.group(1)) <= level:
                    end = pos2
                    break
            return Section(pos, end, line, text[pos:end], "heading")
        if BLOCK_BEGIN.match(line):
            for j in range(k + 1, len(lines)):
                if BLOCK_END.match(lines[j][1].rstrip("\r\n")):
                    end = lines[j][0] + len(lines[j][1])
                    for pos3, raw3 in lines[j + 1:]:
                        if raw3.strip():
                            break
                        end = pos3 + len(raw3)
                    return Section(pos, end, line, text[pos:end], "block")
            return None
    return None


def find_section(text: str) -> Optional[Tuple[int, int, str]]:
    """(start, end, heading line) of the Hook section, found by its heading; it ends at the next
    heading of the same or a higher level, or at the end of the file. A section marked
    hook:migrated is skipped; a Hook instructions block also counts. None if absent."""
    sec = _section(text)
    return (sec.start, sec.end, sec.heading) if sec else None


def _norm(text: str) -> str:
    return " ".join(text.split())


def _body_of(sec: Section) -> str:
    if sec.kind == "block":
        rows = sec.text.splitlines()[1:]
        while rows and not BLOCK_END.match(rows[-1].strip()):
            rows.pop()
        return "\n".join(r for r in rows[:-1] if not STAMP.match(r.strip()))
    return sec.text


def known_texts(bundle: Path) -> List[str]:
    """Every released section text, and the current hook.md body (its stamp line left out)."""
    texts = []
    for path in sorted((bundle / "legacy" / "claude-md-sections").glob("*.md")):
        texts.append(path.read_text("utf-8"))
    current = bundle / "instructions" / "hook.md"
    if current.is_file():
        texts.append("\n".join(r for r in current.read_text("utf-8").splitlines() if not STAMP.match(r.strip())))
    return texts


def _known(sec: Section, bundle: Path) -> bool:
    return _norm(_body_of(sec)) in {_norm(t) for t in known_texts(bundle)}


# --- the personal remainder ----------------------------------------------------------------

def _blocks(body: str) -> List[Tuple[str, str]]:
    """(kind, text) for each paragraph, list item and fenced code block of body."""
    out: List[Tuple[str, List[str]]] = []
    cur: Optional[Tuple[str, List[str]]] = None
    fence: Optional[str] = None
    for raw in body.splitlines():
        if fence is not None:
            cur[1].append(raw)
            m = FENCE.match(raw)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence, cur = None, None
            continue
        m = FENCE.match(raw)
        if m:
            fence = m.group(1)
            cur = ("code", [raw])
            out.append(cur)
            continue
        if not raw.strip():
            cur = None
            continue
        if raw.strip() in (MIGRATED, POINTER):
            cur = None
            continue
        if LIST_ITEM.match(raw):
            cur = ("item", [raw])
            out.append(cur)
            continue
        if cur is None:
            cur = ("para", [raw])
            out.append(cur)
        else:
            cur[1].append(raw)
    return [(kind, "\n".join(rows)) for kind, rows in out]


def _hook_path(token: str) -> bool:
    token = token.rstrip(".,:;!?")
    return any(token == p or token.startswith(p + "/") for p in HOOK_PATHS)


def _personal(kind: str, block: str) -> bool:
    if kind == "code":
        for row in block.splitlines()[1:-1]:
            words = row.split()
            if words and words[0] not in HOOK_WORDS:
                return True
    for m in PATH_TOKEN.finditer(block):
        token = m.group(1).rstrip(".,:;!?")
        if len(token) > 2 and not _hook_path(token):
            return True
    for m in BACKTICKS.finditer(block):
        words = m.group(1).split()
        if len(words) >= 2 and words[0] not in HOOK_WORDS:
            return True
    return bool(SLASH_COMMAND.search(block))


def personal_remainder(section_body: str) -> str:
    """The blocks of the section's body (paragraphs, list items, fenced code) that hold the
    owner's own things: a path outside Hook's own, a backticked command that isn't Hook's,
    or a /slash-command. The rest is Hook's text and goes."""
    kept = [(kind, text) for kind, text in _blocks(section_body) if _personal(kind, text)]
    out = ""
    for k, (kind, text) in enumerate(kept):
        if k:
            out += "\n" if kind == "item" and kept[k - 1][0] == "item" else "\n\n"
        out += text
    return out


# --- proposal and choice -------------------------------------------------------------------

def _nl(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _trailing_blank(text: str) -> str:
    """The blank lines at the end of a section (kept when it is replaced)."""
    rows = text.splitlines(keepends=True)
    tail = ""
    for row in reversed(rows):
        if row.strip():
            break
        tail = row + tail
    return tail


def replacement(sec: Section, remainder: str) -> str:
    """The original heading, the migrated marker, a pointer to Hook's rules file, and the
    owner's own blocks; the section's trailing blank lines stay."""
    heading = sec.heading if sec.kind == "heading" else "# Owner asks go to Hook"
    text = f"{heading}\n{MIGRATED}\n\n{POINTER}\n" + (f"\n{remainder}\n" if remainder else "")
    nl = _nl(sec.text)
    return text.replace("\n", nl) + _trailing_blank(sec.text)


def _without(text: str, sec: Section) -> str:
    """text without the section, and one blank line with it."""
    before, after = text[:sec.start], text[sec.end:]
    if not after:
        if before.endswith("\r\n\r\n"):
            before = before[:-2]
        elif before.endswith("\n\n"):
            before = before[:-1]
    return before + after


def _fence(*texts: str) -> str:
    longest = max([len(m) for t in texts for m in re.findall(r"`+", t)] + [2])
    return "`" * max(3, longest + 1)


def proposal_path(values: Any) -> Path:
    return values.home / ".local" / "state" / "relay" / "integrations" / "claude-md-proposal.md"


def propose(values: Any, section: Section, remainder: str) -> Path:
    """Write the proposal (~/.local/state/relay/integrations/claude-md-proposal.md): the
    section as it is, the proposed replacement, a unified diff, and the section's sha256."""
    new = replacement(section, remainder)
    diff = "".join(difflib.unified_diff(section.text.splitlines(keepends=True), new.splitlines(keepends=True),
                                        fromfile="~/.claude/CLAUDE.md (now)", tofile="~/.claude/CLAUDE.md (proposed)"))
    f = _fence(section.text, new, diff)
    doc = (
        "# Move the Hook section out of ~/.claude/CLAUDE.md\n\n"
        "Hook now keeps its rules for agents in `~/.claude/rules/hook.md`, and Claude Code loads that file "
        "on its own. The section below in `~/.claude/CLAUDE.md` repeats them. Hook proposes to keep only "
        "your own lines under the heading.\n\n"
        f"- **{APPLY}:** replace the section with the proposal below.\n"
        f"- **{REMOVE}:** take the section out, your own lines too.\n"
        f"- **{KEEP}:** change nothing. Hook won't ask again.\n\n"
        "Hook makes the change at its next sync, keeps a `.bak` copy of CLAUDE.md first, and changes nothing "
        "if the section was edited since this proposal.\n\n"
        f"## The proposed section\n\n{f}markdown\n{new.rstrip()}\n{f}\n\n"
        f"## The difference\n\n{f}diff\n{diff.rstrip()}\n{f}\n\n"
        f"## The section now\n\n{f}markdown\n{section.text.rstrip()}\n{f}\n\n"
        f"<!-- hook:proposal sha256={sha256(section.text)} -->\n"
    )
    path = proposal_path(values)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    ed.atomic_write(path, doc.encode("utf-8"), mode=0o600)
    return path


def _md_path(values: Any) -> Path:
    return values.home / ".claude" / "CLAUDE.md"


def _tilde(path: Any, home: Path) -> str:
    text, root = str(path), str(home).rstrip("/")
    return "~/" + text[len(root) + 1:] if text.startswith(root + "/") else text


def _record(manifest: Any, mid: str) -> Dict[str, Any]:
    migrations = manifest.data.setdefault("migrations", [])
    for rec in migrations:
        if isinstance(rec, dict) and rec.get("id") == mid:
            return rec
    rec = {"id": mid}
    migrations.append(rec)
    return rec


def _peek(manifest: Any, mid: str) -> Dict[str, Any]:
    for rec in manifest.data.get("migrations") or []:
        if isinstance(rec, dict) and rec.get("id") == mid:
            return rec
    return {}


def apply_choice(values: Any, manifest: Any, choice: str, now: datetime) -> Dict[str, Any]:
    """Carry out the owner's choice on CLAUDE.md, only while the section is the one proposed.
    Returns the record; its state is applied, removed, declined, or changed (propose again)."""
    if choice not in CHOICES:
        raise ValueError(f"choose one of: {', '.join(CHOICES)}")
    rec = _record(manifest, "claude-md")
    path = _md_path(values)
    text = path.read_text("utf-8") if path.is_file() else ""
    sec = _section(text)
    if sec is None or sha256(sec.text) != rec.get("sha"):
        rec["state"] = "changed"
        return rec
    if choice == KEEP:
        rec.update(state="declined", decided=_iso(now), note="you kept CLAUDE.md as it is")
        return rec
    new = _without(text, sec) if choice == REMOVE else \
        text[:sec.start] + replacement(sec, personal_remainder(sec.text.split("\n", 1)[1] if "\n" in sec.text else "")) + text[sec.end:]
    backup = ed.make_backup(path, now)
    ed.atomic_write(path, new.encode("utf-8"))
    rec.update(state="removed" if choice == REMOVE else "applied", decided=_iso(now),
               backup=_tilde(backup, values.home), path=_tilde(path, values.home))
    rec.pop("note", None)
    return rec


# --- the steps -----------------------------------------------------------------------------

def _ready(manifest: Any) -> Tuple[bool, bool]:
    """(the plugin is installed, the rules file is installed)."""
    h = manifest.harnesses.get(HID) or {}
    plugin = h.get("plugin")
    rules = ((h.get("pieces") or {}).get("instructions") or {}).get("target")
    return bool(plugin and plugin in manifest.targets), bool(rules and rules in manifest.targets)


def _item(mid: str, state: str, path: Optional[str], note: Optional[str] = None) -> Dict[str, Any]:
    return {"id": mid, "state": state, "path": path, "note": note}


def _set(rec: Dict[str, Any], state: str, **extra: Any) -> bool:
    """Update the record; True when its state changed."""
    changed = rec.get("state") != state
    rec["state"] = state
    rec.update({k: v for k, v in extra.items() if v is not None})
    if extra.get("note") is None:
        rec.pop("note", None)
    return changed


def _step_mcp(values: Any, manifest: Any, dry_run: bool, engine: Optional[str]) -> List[Dict[str, Any]]:
    """engine: what the sync did with the mcp piece this run (replaced, recorded, ...)."""
    h = manifest.harnesses.get(HID) or {}
    target = ((h.get("pieces") or {}).get("mcp") or {}).get("target")
    path = values.home / ".claude.json"
    if target and target in manifest.targets:
        if engine not in ("replaced", "recorded"):
            return []
        state = "replaced" if engine == "replaced" else "adopted"
        note = "an earlier Hook server, now Hook's current one" if state == "replaced" else None
    else:
        try:
            found, value = ed.json_get(path.read_text("utf-8"), ["mcpServers", "relay"]) if path.is_file() else (False, None)
        except (ed.ParseError, ed.EditError, OSError, UnicodeDecodeError):
            return []
        if not found:
            return []
        hookish = "relay_mcp.py" in json.dumps(value)
        state, note = ("waiting", "needs `claude`") if hookish else \
            ("foreign", "a relay server that isn't Hook's; Hook left it alone")
    if dry_run:
        return [] if _peek(manifest, "claude-mcp").get("state") == state else [_item("claude-mcp", state, "~/.claude.json", note)]
    if _set(_record(manifest, "claude-mcp"), state, note=note):
        return [_item("claude-mcp", state, "~/.claude.json", note)]
    return []


def _legacy_link(link: Path, home: Path) -> bool:
    target = Path(os.path.realpath(link))
    if target.name == "instructables" and target.parent.name == "skill" \
            and (target.parent.parent / "mcp" / "relay_mcp.py").is_file():
        return True
    return not target.exists() and str(target).startswith(str(Path(os.path.realpath(home)) / ".local" / "share" / "hook") + "/")


def _step_skill(values: Any, manifest: Any, dry_run: bool) -> List[Dict[str, Any]]:
    link = values.home / ".claude" / "skills" / "instructables"
    shown = "~/.claude/skills/instructables"
    if not (link.is_symlink() or link.exists()):
        return []
    if link.is_symlink() and _legacy_link(link, values.home):
        if dry_run:
            return [_item("claude-skill", "would remove", shown, "the plugin carries the skill")]
        link.unlink()
        _set(_record(manifest, "claude-skill"), "removed", path=shown)
        return [_item("claude-skill", "removed", shown, "the plugin carries the skill")]
    note = "a second instructables skill; remove it to avoid duplicates"
    if dry_run:
        return []
    if _set(_record(manifest, "claude-skill"), "foreign", path=shown, note=note):
        return [_item("claude-skill", "foreign", shown, note)]
    return []


def _legacy_hook(element: Any) -> bool:
    command = element.get("command") if isinstance(element, dict) else None
    return isinstance(command, str) and any(mark in command for mark in LEGACY_HOOK)


PLUGIN_HOOKS = Path("hooks") / "claude-hooks.json"
PROBE_TIMEOUT = 10.0


def plugin_hook_runs(values: Any, manifest: Any, runner: Any) -> Optional[str]:
    """None when every `hook replies` command in the rendered plugin's hooks file runs (its
    --probe prints PROBE_OK), else why not. Nothing reaches Hook: --probe contacts nothing."""
    from relay_hook import PROBE_OK
    h = manifest.harnesses.get(HID) or {}
    rec = manifest.targets.get(h.get("plugin") or "") or {}
    if not rec.get("path"):
        return "the plugin isn't installed"
    hooks_file = Path(rec["path"]) / PLUGIN_HOOKS
    try:
        hooks = json.loads(hooks_file.read_text("utf-8"))
        groups = hooks["hooks"]["UserPromptSubmit"]
        commands = [inner["command"] for group in groups for inner in group.get("hooks") or []
                    if isinstance(inner, dict) and isinstance(inner.get("command"), str)
                    and "hook replies" in inner["command"]]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return "the plugin's hooks file doesn't read"
    if not commands:
        return "the plugin has no replies hook"
    if runner is None:
        return "nothing to run its hook with"
    for command in commands:
        rc, out, _ = runner.run(["/bin/sh", "-c", command + " --probe"], timeout=PROBE_TIMEOUT)
        if rc != 0 or PROBE_OK not in out.splitlines():
            return f"its command exited {rc}" if rc != 0 else "its command printed something else"
    return None


def _step_hook(values: Any, manifest: Any, now: datetime, dry_run: bool, runner: Any = None) -> List[Dict[str, Any]]:
    path = values.home / ".claude" / "settings.json"
    shown = "~/.claude/settings.json"
    if not path.is_file():
        return []
    try:
        text = path.read_text("utf-8")
        new = ed.json_remove_nested(text, ["hooks", "UserPromptSubmit"], "hooks", _legacy_hook)
    except (ed.ParseError, ed.EditError, UnicodeDecodeError) as exc:
        note = f"{shown} doesn't parse ({exc}); Hook left it alone"
        if not dry_run and _set(_record(manifest, "claude-hook"), "blocked", path=shown, note=note):
            return [_item("claude-hook", "blocked", shown, note)]
        return []
    if new == text:
        return []
    why = plugin_hook_runs(values, manifest, runner)
    if why is not None:
        # Removing the old hook now would leave Claude Code with no working replies hook.
        note = f"the plugin's replies hook doesn't run yet ({why}); the old replies hook stays until it does"
        if dry_run:
            return [] if _peek(manifest, "claude-hook").get("state") == "waiting" else \
                [_item("claude-hook", "would wait", shown, note)]
        if _set(_record(manifest, "claude-hook"), "waiting", path=shown, note=note):
            return [_item("claude-hook", "waiting", shown, note)]
        return []
    if dry_run:
        return [_item("claude-hook", "would remove", shown, "the old replies hook; the plugin has it")]
    backup = ed.make_backup(path, now)
    ed.atomic_write(path, new.encode("utf-8"))
    _set(_record(manifest, "claude-hook"), "removed", path=shown, backup=_tilde(backup, values.home))
    return [_item("claude-hook", "removed", shown, "the old replies hook; the plugin has it")]


def _ask(values: Any, title: str) -> Dict[str, Any]:
    return {
        "v": 1, "title": title,
        "why": "Hook's rules now load from their own file, so the copy in CLAUDE.md can go. Your own lines stay.",
        "urgency": "whenever",
        "steps": [
            {"do": "Read Hook's proposal for your CLAUDE.md", "file": _tilde(proposal_path(values), values.home)},
            {"do": "Choose what Hook does with the section",
             "detail": "Hook makes the change at its next sync and keeps a .bak copy of CLAUDE.md first.",
             "question": {"prompt": "Apply the proposal, remove the whole section, or keep CLAUDE.md as it is?",
                          "choices": list(CHOICES)}},
        ],
        "verify": {"do": "After the next sync, start a new Claude Code session and ask how it sends you an ask",
                   "expect": "It names relay_post and Hook's rules file"},
    }


def _close(rec: Dict[str, Any], poster: Any, choice: str) -> None:
    """Close the ask once Hook carried out the owner's choice."""
    if rec.get("askId") and rec.get("askState", "open") == "open" and poster is not None:
        if poster.resolve(rec["askId"], f"Hook did it: {choice}."):
            rec["askState"] = "done"


def _post_proposal(values: Any, rec: Dict[str, Any], poster: Any, now: datetime) -> None:
    if poster is None:
        return
    title = rec.get("title") or TITLE
    ask_id = poster.post(_ask(values, title))
    if ask_id:
        rec.update(askId=ask_id, askState="open", posted=_iso(now))


def _step_md(values: Any, manifest: Any, poster: Any, now: datetime, dry_run: bool, again: bool,
             choice: Optional[str]) -> List[Dict[str, Any]]:
    path = _md_path(values)
    shown = "~/.claude/CLAUDE.md"
    try:
        text = path.read_text("utf-8") if path.is_file() else ""
    except (OSError, UnicodeDecodeError):
        return []
    sec = _section(text)
    rec = _peek(manifest, "claude-md")
    if sec is None:
        if rec.get("state") == "proposed" and not dry_run:
            _set(_record(manifest, "claude-md"), "gone", note="the section is no longer in CLAUDE.md")
        return []
    sha = sha256(sec.text)
    if _known(sec, values.bundle):
        if dry_run:
            return [_item("claude-md", "would remove", shown, "a section Hook wrote; its rules file has it now")]
        backup = ed.make_backup(path, now)
        ed.atomic_write(path, _without(text, sec).encode("utf-8"))
        rec = _record(manifest, "claude-md")
        for k in ("askId", "askState", "answers", "title"):
            rec.pop(k, None)
        _set(rec, "removed", path=shown, backup=_tilde(backup, values.home), sha=sha, decided=_iso(now))
        return [_item("claude-md", "removed", shown, "a section Hook wrote; its rules file has it now")]
    if rec.get("state") == "declined" and not again and choice is None:
        return []
    if dry_run:
        if rec.get("state") == "proposed" and rec.get("sha") == sha:
            return []
        return [_item("claude-md", "would propose", shown, "Hook asks before it changes this section")]
    rec = _record(manifest, "claude-md")
    answer = choice or ((rec.get("answers") or {}).get(QUESTION_STEP) if rec.get("state") == "proposed" else None)
    if rec.get("state") == "proposed" and rec.get("sha") == sha and not again:
        if answer in CHOICES:
            done = apply_choice(values, manifest, answer, now)
            if done["state"] != "changed":
                _close(rec, poster, answer)
                return [_item("claude-md", done["state"], shown, done.get("note"))]
        elif rec.get("askState") in ("done", "skipped"):
            _set(rec, "declined", note="you closed the ask without choosing")
            return [_item("claude-md", "declined", shown, rec["note"])]
        else:
            if not rec.get("askId"):
                _post_proposal(values, rec, poster, now)
            return []
    elif choice is not None and choice in CHOICES and rec.get("sha") == sha:
        done = apply_choice(values, manifest, choice, now)
        if done["state"] != "changed":
            _close(rec, poster, choice)
            return [_item("claude-md", done["state"], shown, done.get("note"))]
    # A new proposal: the first one, or the section changed since the last one.
    still_open = bool(rec.get("askId")) and rec.get("askState", "open") == "open"
    if still_open and poster is not None:
        poster.resolve(rec["askId"], "Hook made a new proposal: the section changed since.")
    remainder = personal_remainder(sec.text.split("\n", 1)[1] if "\n" in sec.text else "")
    propose(values, sec, remainder)
    if rec.get("askId"):
        # Should the queue hand the old ask back, its earlier answers don't count again.
        rec["ignoreFor"], rec["ignoreSeq"] = rec["askId"], int(rec.get("answerSeq") or 0)
    for k in ("askId", "askState", "answers", "answerSeq", "posted", "note"):
        rec.pop(k, None)
    rec.update(state="proposed", sha=sha, path=shown, title=RETITLE if still_open else TITLE,
               proposal=_tilde(proposal_path(values), values.home), proposed=_iso(now))
    _post_proposal(values, rec, poster, now)
    return [_item("claude-md", "proposed", shown, "Hook asks before it changes this section")]


def migrate(values: Any, manifest: Any, runner: Any, client_factory: Any, now: datetime, *, dry_run: bool,
            again: bool = False, choice: Optional[str] = None, poster: Any = None,
            mcp_outcome: Optional[str] = None) -> List[Dict[str, Any]]:
    """Run the steps that are due; return report items [{id, state, path, note}]. Nothing runs
    before the plugin and the rules file are installed. dry_run writes nothing and posts nothing."""
    if poster is None and client_factory is not None and not dry_run:
        import relay_owner_steps as ros
        poster = ros.Poster(client_factory, no_asks=False)
    items = _step_mcp(values, manifest, dry_run, mcp_outcome)
    plugin_ok, rules_ok = _ready(manifest)
    if not (plugin_ok and rules_ok):
        return items
    items += _step_skill(values, manifest, dry_run)
    items += _step_hook(values, manifest, now, dry_run, runner)
    items += _step_md(values, manifest, None if dry_run else poster, now, dry_run, again, choice)
    return items


def backups(manifest: Any) -> List[Tuple[str, str]]:
    """(path, .bak) of every file a migration changed, for the uninstall report."""
    out = []
    for rec in manifest.data.get("migrations") or []:
        if isinstance(rec, dict) and rec.get("backup") and rec.get("path"):
            out.append((rec["path"], rec["backup"]))
    return out
