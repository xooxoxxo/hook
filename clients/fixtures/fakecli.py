"""A fake harness CLI for the integration tests. Standard library only (Python 3.9).

The tests copy this file under each needed name (codex, claude, gemini, ...) into a temp bin
folder, with its first line set to the running interpreter. It never touches anything but the
files its rules name, and those live in the test's temp HOME.

Environment:
    FAKECLI_LOG       append one JSON line per call: {"prog": name, "argv": [...]}
    FAKECLI_CONFIG    a JSON file: {"rules": [rule, ...], "fail": [prog, ...],
                      "sleep": {prog: seconds}, "stdout": {prog: text}}
    FAKECLI_STATE     a JSON file the fake keeps its own state in (what it set, and its prune)
    FAKECLI_CLIENTS   the clients folder, so the fake can edit files with relay_edits

A rule is {"prog", "prefix": [args], "action", "writes"?, "text"?}; the first rule whose prog
matches and whose prefix starts argv[1:] runs. Actions:
    set      write {"fake": prog, "args": rest} at writes.key (json, jsonc or toml)
    delete   remove what `set` wrote, byte for byte
    touch    create writes.path (a folder), remembering the parent folders it made
    rm       remove writes.path and those parent folders
    print    print text
Without a matching rule the fake exits 0 and prints nothing. A prog in "fail" exits 1 with one
stderr line; "sleep" waits first (to test timeouts and the lock).
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path


def _load(path, default):
    try:
        return json.loads(Path(path).read_text("utf-8"))
    except (OSError, ValueError):
        return default


def main() -> int:
    prog = Path(sys.argv[0]).name
    args = sys.argv[1:]
    log = os.environ.get("FAKECLI_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"prog": prog, "argv": args, "start": time.time()}) + "\n")
    config = _load(os.environ.get("FAKECLI_CONFIG", ""), {})
    delay = (config.get("sleep") or {}).get(prog)
    if delay:
        time.sleep(float(delay))
    if prog in (config.get("fail") or []):
        sys.stderr.write(f"{prog}: fake failure\nsecond line\n")
        return 1
    if prog in (config.get("stdout") or {}):
        sys.stdout.write(config["stdout"][prog])
    for rule in config.get("rules") or []:
        prefix = rule.get("prefix") or []
        if rule.get("prog") != prog or args[:len(prefix)] != prefix:
            continue
        rc = _act(rule, prog, args[len(prefix):])
        if log:
            with open(log, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"prog": prog, "end": time.time()}) + "\n")
        return rc
    if log:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"prog": prog, "end": time.time()}) + "\n")
    return 0


def _act(rule, prog, rest) -> int:
    sys.path.insert(0, os.environ.get("FAKECLI_CLIENTS", ""))
    import relay_edits as ed  # noqa: E402

    action = rule["action"]
    writes = rule.get("writes") or {}
    path = Path(writes["path"]) if writes.get("path") else None
    state_path = os.environ.get("FAKECLI_STATE", "")
    state = _load(state_path, {}) if state_path else {}
    sid = f"{prog}:{writes.get('path')}:{'.'.join(writes.get('key') or [])}"
    if action == "print":
        sys.stdout.write(rule.get("text", ""))
        return 0
    if action == "touch":
        made = []
        parent = path.parent
        while not parent.exists():
            made.append(str(parent))
            parent = parent.parent
        path.mkdir(parents=True, exist_ok=True)
        state.setdefault(sid, {})["dirs"] = made
        _save(state_path, state)
        return 0
    if action == "rm":
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        for d in (state.pop(sid, {}) or {}).get("dirs") or []:
            try:
                os.rmdir(d)
            except OSError:
                pass
        _save(state_path, state)
        return 0
    fmt, key = writes["format"], writes["key"]
    text = path.read_text("utf-8") if path.exists() else ""
    value = {"fake": prog, "args": [str(a) for a in rest]}
    if action == "set":
        if fmt in ("json", "jsonc"):
            if sid not in state:
                state[sid] = {"prune": ed.json_missing_containers(text, key), "created": not path.exists()}
            new = ed.json_set(text, key, value)
        else:
            if sid not in state:
                state[sid] = {"created": not path.exists()}
            new = ed.toml_set_table(text, key, value, "fake", "0" * 16)
    elif action == "delete":
        if sid not in state and not text:
            return 0
        info = state.pop(sid, {"prune": 0, "created": False})
        if fmt in ("json", "jsonc"):
            new = ed.json_delete(text, key, prune=info.get("prune", 0))
        else:
            new = ed.toml_remove_table(text, "fake")
        if not new and info.get("created"):
            if path.exists():
                path.unlink()
            _save(state_path, state)
            return 0
    else:
        sys.stderr.write(f"fakecli: unknown action {action}\n")
        return 2
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new, "utf-8")
    _save(state_path, state)
    return 0


def _save(state_path, state) -> None:
    if state_path:
        Path(state_path).write_text(json.dumps(state), "utf-8")


if __name__ == "__main__":
    sys.exit(main())
