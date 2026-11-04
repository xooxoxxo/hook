"""The integration bundle: one versioned tree per release, built from integration/src and the
instructables skill, that `relay integrations` installs into every agent harness.

    python3 clients/relay_bundle.py build [--version X.Y.Z] --out DIR [--src DIR] [--skill DIR] [--table FILE]

The built layout (support/integration/ in a release zip, build/integration/ in a clone):
    bundle.json                       {"schema", "version", "files": {relpath: sha256}}
    harnesses.json                    the harness table, when there is one
    harnesses.schema.json             its schema, so an installed bundle can check it
    instructions/hook.md              the stamp line, then the one instructions text
    instructions/hook.mdc             Cursor rule frontmatter, the stamp, the text
    instructions/hook.instructions.md Copilot frontmatter, the stamp, the text
    instructions/hook.steering.md     Kiro steering frontmatter, the stamp, the text
    skills/instructables/             the skill, with metadata.version in its frontmatter
    plugins/<id>/                     plugin templates with {{placeholders}}; render.json names extra copies
    files/                            templates for single files Hook owns
    legacy/claude-md-sections/        every released CLAUDE.md section text, for the migration

Templates are filled per machine by render_text and render_tree. In .json, .ts and .js files a
value is JSON-escaped; in .md and .mdc files it goes in raw. Standard library only (Python 3.9).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

BUNDLE_SCHEMA = 1                        # bump only when configs Hook writes must change shape
STAMP = "<!-- hook:instructions v={schema} app={version} -->"

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDERS = frozenset({
    "home", "harness_home", "python", "mcp_server", "relay", "bundle", "instructions",
    "instructions_home_ref", "plugins", "version", "schema",
})
REPLY_FORMATS = ("claude", "gemini", "kiro", "cursor", "copilot", "plain", "plain-session")
JSON_SUFFIXES = (".json", ".ts", ".js")
RAW_SUFFIXES = (".md", ".mdc")
SKIP_NAMES = (".DS_Store", "__pycache__")
PLACEHOLDER = re.compile(r"\{\{([^{}]*)\}\}")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

# The instruction projections: (built path, frontmatter lines before the stamp).
PROJECTIONS: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    ("instructions/hook.md", ()),
    ("instructions/hook.mdc", ("description: Hook owner asks", "alwaysApply: true")),         # Cursor
    ("instructions/hook.instructions.md", ('applyTo: "**"',)),                                 # Copilot
    ("instructions/hook.steering.md", ("inclusion: always",)),                                 # Kiro
)


class BundleError(Exception):
    """The bundle can't be built or read."""


class RenderError(BundleError):
    """An unknown {{placeholder}}, a placeholder without a value, or a missing source."""


# --- placeholders --------------------------------------------------------------------------

def known_placeholder(name: str) -> bool:
    """True for a name the templates and the harness table may use inside {{…}}."""
    if name in PLACEHOLDERS:
        return True
    kind, _, fmt = name.partition(":")
    return kind == "replies" and fmt in REPLY_FORMATS


def shell_quote(value: str) -> str:
    """value in single quotes for a POSIX shell, always quoted."""
    return "'" + value.replace("'", "'\\''") + "'"


def replies_command(relay: str, fmt: str) -> str:
    """The replies hook command line for one format; plain-session is plain at session start."""
    if fmt == "plain-session":
        return f"{shell_quote(relay)} hook replies --format plain --when session-start"
    return f"{shell_quote(relay)} hook replies --format {fmt}"


def _value(name: str, values: Mapping[str, Any]) -> str:
    if not known_placeholder(name):
        raise RenderError(f"unknown placeholder {{{{{name}}}}}")
    if name in values:
        return str(values[name])
    if name.startswith("replies:") and "relay" in values:
        return replies_command(str(values["relay"]), name.split(":", 1)[1])
    raise RenderError(f"no value for {{{{{name}}}}}")


def render_text(text: str, values: Mapping[str, Any], *, json_escape: bool) -> str:
    """text with every {{name}} replaced by its value, JSON-escaped when json_escape."""
    def sub(match: "re.Match[str]") -> str:
        value = _value(match.group(1), values)
        return json.dumps(value)[1:-1] if json_escape else value
    return PLACEHOLDER.sub(sub, text)


def template_names(text: str) -> List[str]:
    """The placeholder names a template uses, in order."""
    return PLACEHOLDER.findall(text)


# --- trees ---------------------------------------------------------------------------------

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _files(root: Path) -> List[Tuple[str, Path]]:
    """(posix relpath, path) of every regular file under root, sorted, caches skipped.
    A symlink anywhere raises BundleError."""
    found: List[Tuple[str, Path]] = []
    for here, dirs, names in os.walk(root):
        base = Path(here)
        for name in list(dirs):
            if (base / name).is_symlink():
                raise BundleError(f"symlink in the bundle: {base / name}")
        dirs[:] = sorted(d for d in dirs if d not in SKIP_NAMES)
        for name in names:
            path = base / name
            if path.is_symlink():
                raise BundleError(f"symlink in the bundle: {path}")
            if name in SKIP_NAMES or name.endswith(".pyc"):
                continue
            found.append((path.relative_to(root).as_posix(), path))
    return sorted(found)


def tree_sha(path: Path) -> str:
    """sha256 over the sorted "relpath\\0sha256(file)\\n" lines of a tree. No symlinks allowed;
    .DS_Store files (Finder makes them) are left out."""
    if path.is_symlink() or not path.is_dir():
        raise BundleError(f"not a folder: {path}")
    listing = "".join(f"{rel}\0{sha256_bytes(p.read_bytes())}\n" for rel, p in _files(path))
    return sha256_bytes(listing.encode("utf-8"))


def _copy_tree(src: Path, dest: Path) -> None:
    for rel, path in _files(src):
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        os.chmod(target, stat.S_IMODE(path.stat().st_mode))


def _swap_in(tmp: Path, dest: Path) -> None:
    """Put tmp at dest, replacing what was there, with renames in the same folder."""
    if dest.exists() or dest.is_symlink():
        old = dest.with_name(f"{dest.name}.old-{os.getpid()}")
        if old.exists():
            shutil.rmtree(old)
        dest.rename(old)
        tmp.rename(dest)
        shutil.rmtree(old, ignore_errors=True)
    else:
        tmp.rename(dest)


def _fresh_tmp(dest: Path) -> Path:
    tmp = dest.with_name(f"{dest.name}.tmp-{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp.mkdir()
    return tmp


def _relative(rel: str) -> str:
    parts = Path(rel).parts
    if not rel or Path(rel).is_absolute() or ".." in parts:
        raise RenderError(f"not a relative path inside the plugin: {rel!r}")
    return Path(rel).as_posix()


def plugin_extras(bundle: Path, plugin_id: str) -> Dict[str, Path]:
    """The extra copies a plugin's render.json lists, as {dest relpath: bundle path}."""
    spec = bundle / "plugins" / plugin_id / "render.json"
    if not spec.is_file():
        return {}
    try:
        data = json.loads(spec.read_text("utf-8"))
    except ValueError as e:
        raise RenderError(f"{spec}: not JSON ({e})") from None
    copy = data.get("copy", {}) if isinstance(data, dict) else None
    if not isinstance(copy, dict) or not all(isinstance(v, str) for v in copy.values()):
        raise RenderError(f"{spec}: copy must map paths to bundle paths")
    return {_relative(dest): bundle / _relative(source) for dest, source in copy.items()}


def render_files(src: Path, values: Mapping[str, Any], extra: Mapping[str, Path]) -> Dict[str, Tuple[bytes, int]]:
    """What render_tree would write, in memory: {relpath: (bytes, mode)}. Templates are filled
    with values; extra maps a dest relpath to a bundle file or folder copied as it is.
    render.json itself is left out."""
    if not src.is_dir():
        raise RenderError(f"missing source: {src}")
    for rel, source in extra.items():
        if not source.exists():
            raise RenderError(f"missing source for {rel}: {source}")
    files: Dict[str, Tuple[bytes, int]] = {}
    for rel, path in _files(src):
        if rel == "render.json":
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        if path.suffix in JSON_SUFFIXES + RAW_SUFFIXES:
            text = render_text(path.read_text("utf-8"), values, json_escape=path.suffix in JSON_SUFFIXES)
            files[rel] = (text.encode("utf-8"), mode)
        else:
            files[rel] = (path.read_bytes(), mode)
    for rel, source in sorted(extra.items()):
        rel = _relative(rel)
        if source.is_dir():
            for sub, path in _files(source):
                files[f"{rel}/{sub}"] = (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
        else:
            if source.is_symlink():
                raise BundleError(f"symlink in the bundle: {source}")
            files[rel] = (source.read_bytes(), stat.S_IMODE(source.stat().st_mode))
    return files


def files_sha(files: Mapping[str, Tuple[bytes, int]]) -> str:
    """The tree_sha that a folder holding exactly these files would have."""
    listing = "".join(f"{rel}\0{sha256_bytes(data)}\n" for rel, (data, _) in sorted(files.items()))
    return sha256_bytes(listing.encode("utf-8"))


def render_tree(src: Path, dest: Path, values: Mapping[str, Any], extra: Mapping[str, Path]) -> str:
    """Render a plugin template folder into dest (replacing it) and return the new tree sha.
    Templates are filled with values; extra maps a dest relpath to a bundle file or folder
    that is copied as it is. render.json itself is not copied."""
    files = render_files(src, values, extra)
    tmp = _fresh_tmp(dest)
    try:
        for rel, (data, mode) in files.items():
            target = tmp / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.chmod(target, mode)
        sha = tree_sha(tmp)
        _swap_in(tmp, dest)
        return sha
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


# --- build ---------------------------------------------------------------------------------

def stamp(version: str, schema: int = BUNDLE_SCHEMA) -> str:
    return STAMP.format(schema=schema, version=version)


def _projection(head: Tuple[str, ...], body: str) -> str:
    return ("---\n" + "".join(line + "\n" for line in head) + "---\n" if head else "") + body


def skill_with_version(text: str, version: str) -> str:
    """SKILL.md with metadata.version set in its frontmatter; everything else byte-identical."""
    if not text.startswith("---\n"):
        raise BundleError("SKILL.md has no frontmatter")
    end = text.find("\n---\n", 3)
    if end < 0:
        raise BundleError("SKILL.md frontmatter is not closed")
    head, rest = text[4:end].split("\n"), text[end:]
    line = f'  version: "{version}"'
    tops = [i for i, row in enumerate(head) if re.match(r"^metadata\s*:", row)]
    if not tops:
        head += ["metadata:", line]
    else:
        at = tops[0]
        if head[at].split(":", 1)[1].strip():
            raise BundleError("SKILL.md metadata must be a block mapping")
        stop = at + 1
        while stop < len(head) and (head[stop].startswith((" ", "\t")) or not head[stop].strip()):
            stop += 1
        children = [row for row in head[at + 1:stop] if not re.match(r"^\s+version\s*:", row)]
        head = head[:at + 1] + [line] + children + head[stop:]
    return "---\n" + "\n".join(head) + rest


def _check_templates(root: Path) -> None:
    for rel, path in _files(root):
        if path.suffix in JSON_SUFFIXES + RAW_SUFFIXES:
            for name in template_names(path.read_text("utf-8")):
                if not known_placeholder(name):
                    raise RenderError(f"{rel}: unknown placeholder {{{{{name}}}}}")


def build(src: Path, skill: Path, table: Path, out: Path, version: str) -> Dict[str, Any]:
    """Build the bundle into out (replacing an earlier bundle there) and return bundle.json."""
    if not VERSION_RE.match(version or ""):
        raise BundleError(f"version {version!r} is not X.Y.Z")
    if out.is_symlink() or (out.exists() and not (out / "bundle.json").is_file()):
        raise BundleError(f"refusing to replace {out}: not a Hook bundle")
    for need in (src / "instructions" / "hook.md", src / "plugins", src / "files", skill / "SKILL.md"):
        if not need.exists():
            raise RenderError(f"missing source: {need}")
    tmp = _fresh_tmp(out)
    try:
        text = (src / "instructions" / "hook.md").read_text("utf-8")
        body = stamp(version) + "\n" + text
        for rel, head in PROJECTIONS:
            target = tmp / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(_projection(head, body), "utf-8")
        _copy_tree(skill, tmp / "skills" / "instructables")
        skill_md = tmp / "skills" / "instructables" / "SKILL.md"
        skill_md.write_text(skill_with_version(skill_md.read_text("utf-8"), version), "utf-8")
        for part in ("plugins", "files"):
            _copy_tree(src / part, tmp / part)
            _check_templates(tmp / part)
        if (src / "legacy").is_dir():
            _copy_tree(src / "legacy", tmp / "legacy")      # earlier Hook texts, copied as they are
        for plugin in sorted(p.name for p in (tmp / "plugins").iterdir() if p.is_dir()):
            for rel, source in plugin_extras(tmp, plugin).items():
                if not source.exists():
                    raise RenderError(f"plugins/{plugin}/render.json: {rel} copies a missing {source.relative_to(tmp)}")
        if table.is_file():
            try:
                json.loads(table.read_text("utf-8"))
            except ValueError as e:
                raise BundleError(f"{table}: not JSON ({e})") from None
            shutil.copyfile(table, tmp / "harnesses.json")
            schema = table.with_name("harnesses.schema.json")
            if schema.is_file():
                shutil.copyfile(schema, tmp / "harnesses.schema.json")
        files = {rel: sha256_bytes(path.read_bytes()) for rel, path in _files(tmp)}
        manifest = {"schema": BUNDLE_SCHEMA, "version": version, "files": files}
        (tmp / "bundle.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", "utf-8")
        _swap_in(tmp, out)
        return manifest
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def app_version(root: Path = ROOT) -> str:
    """CFBundleShortVersionString from Resources/Info.plist, the one place a version is set."""
    with open(root / "Resources" / "Info.plist", "rb") as f:
        return str(plistlib.load(f)["CFBundleShortVersionString"])


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="relay_bundle.py", description="Build Hook's integration bundle.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="build the bundle into --out")
    b.add_argument("--version", help="the Hook version (default: Resources/Info.plist)")
    b.add_argument("--out", required=True, type=Path)
    b.add_argument("--src", type=Path, default=ROOT / "integration" / "src")
    b.add_argument("--skill", type=Path, default=ROOT / "skill" / "instructables")
    b.add_argument("--table", type=Path, default=ROOT / "integration" / "harnesses.json")
    args = parser.parse_args(argv)
    try:
        version = args.version or app_version()
        manifest = build(args.src, args.skill, args.table, args.out, version)
    except (BundleError, OSError, KeyError, plistlib.InvalidFileException) as e:
        print(f"relay_bundle: {e}", file=sys.stderr)
        return 1
    print(f"bundle: {args.out} ({len(manifest['files'])} files, {version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
