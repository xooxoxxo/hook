#!/usr/bin/env python3
"""Render docs/*.md into site pages: site/docs/<name>.html, with docs/README.md as index.html.

    python3 scripts/build-docs-site.py [--out DIR] [--layout sidebar|column]

Standard library only (Python 3.9). The converter covers the Markdown the docs use: ATX
headings, paragraphs, `-` and `1.` lists with one nested level, pipe tables, fenced code,
inline code, links, bold, italic and `<a id="…"></a>` anchors. Heading ids follow GitHub's
rule, so a link like `privacy.md#crash-reports` works on GitHub and on the site alike.
The navigation comes from docs/README.md: each `## Group` and its `- [Title](file.md)` lines.
"""
from __future__ import annotations

import argparse
import html
import plistlib
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ASSETS = Path(__file__).resolve().parent / "docs-site"
REPO = "https://github.com/xooxoxxo/hook"
LAYOUTS = ("sidebar", "column")


def slug(text: str) -> str:
    """GitHub's heading anchor: lowercase, letters, digits, spaces, '-' and '_' kept, spaces as '-'."""
    plain = "".join(c for c in text.lower() if c.isalpha() or c.isdigit() or c in " -_")
    return plain.replace(" ", "-")


# ---------------------------------------------------------------- inline

CODE = re.compile(r"(`+)(.+?)\1")
LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
BOLD = re.compile(r"\*\*(.+?)\*\*")
ITALIC = re.compile(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])")


def inline(text: str, link) -> str:
    """Inline Markdown to HTML. `link` maps a Markdown target to an href."""
    keep: list[str] = []

    def stash(fragment: str) -> str:
        keep.append(fragment)
        return f"\x00{len(keep) - 1}\x00"

    text = CODE.sub(lambda m: stash(f"<code>{html.escape(m.group(2).strip() if m.group(2).strip() else m.group(2))}</code>"), text)
    text = html.escape(text, quote=False)
    text = LINK.sub(lambda m: stash(f'<a href="{html.escape(link(html.unescape(m.group(2))))}">{m.group(1)}</a>'), text)
    text = BOLD.sub(r"<strong>\1</strong>", text)
    text = ITALIC.sub(r"<em>\1</em>", text)
    while "\x00" in text:
        text = re.sub(r"\x00(\d+)\x00", lambda m: keep[int(m.group(1))], text)
    return text


def plain(text: str) -> str:
    """The heading's visible text: code ticks, link targets and emphasis dropped."""
    text = CODE.sub(lambda m: m.group(2), text)
    text = LINK.sub(lambda m: m.group(1), text)
    return re.sub(r"\*\*?(.+?)\*\*?", r"\1", text)


# ---------------------------------------------------------------- blocks

FENCE = re.compile(r"^```\s*([\w+-]*)\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
ITEM = re.compile(r"^( *)([-*+]|\d+[.)])\s+(.*)$")
ANCHOR = re.compile(r'^<a id="([^"]+)"></a>\s*$')
SEPARATOR = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$")


def cells(row: str) -> list[str]:
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", row)]


class Doc:
    def __init__(self, title: str, body: str, toc: list[tuple[int, str, str]]):
        self.title, self.body, self.toc = title, body, toc


def render(md: str, link) -> Doc:
    lines = md.replace("\t", "    ").split("\n")
    out: list[str] = []
    toc: list[tuple[int, str, str]] = []
    used: dict[str, int] = {}
    title = ""
    i = 0

    def heading_id(text: str) -> str:
        base = slug(plain(text))
        n = used.get(base, 0)
        used[base] = n + 1
        return base if n == 0 else f"{base}-{n}"

    def starts_block(line: str) -> bool:
        return bool(FENCE.match(line) or HEADING.match(line) or ITEM.match(line) or ANCHOR.match(line)
                    or line.startswith("|") or line.startswith(">"))

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = FENCE.match(line)
        if m:
            lang, code = m.group(1), []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            cls = f' class="language-{lang}"' if lang else ""
            out.append(f'<div class="code"><pre><code{cls}>{html.escape(chr(10).join(code))}</code></pre>'
                       '<button class="copy" type="button">Copy</button></div>')
            continue
        m = ANCHOR.match(line)
        if m:
            out.append(f'<a id="{html.escape(m.group(1))}"></a>')
            i += 1
            continue
        m = HEADING.match(line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            hid = heading_id(text)
            if level == 1 and not title:
                title = plain(text)
                out.append(f'<h1 id="{hid}">{inline(text, link)}</h1>')
            else:
                if level in (2, 3):
                    toc.append((level, hid, inline(text, link)))
                out.append(f'<h{level} id="{hid}">{inline(text, link)}'
                           f'<a class="anchor" href="#{hid}" aria-label="Link to this section">#</a></h{level}>')
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and SEPARATOR.match(lines[i + 1]):
            head = cells(line)
            aligns = []
            for c in cells(lines[i + 1]):
                aligns.append("center" if c.startswith(":") and c.endswith(":") else "right" if c.endswith(":") else "")
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(cells(lines[i]))
                i += 1

            def tr(row, tag):
                tds = []
                for n, c in enumerate(row):
                    a = aligns[n] if n < len(aligns) and aligns[n] else ""
                    style = f' style="text-align:{a}"' if a else ""
                    tds.append(f"<{tag}{style}>{inline(c, link)}</{tag}>")
                return "<tr>" + "".join(tds) + "</tr>"
            out.append('<div class="table"><table><thead>' + tr(head, "th") + "</thead><tbody>"
                       + "".join(tr(r, "td") for r in rows) + "</tbody></table></div>")
            continue
        if line.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].lstrip())
                i += 1
            out.append("<blockquote>" + render("\n".join(quote), link).body + "</blockquote>")
            continue
        if ITEM.match(line):
            i = render_list(lines, i, out, link)
            continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not starts_block(lines[i]):
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(para), link)}</p>")
    return Doc(title, "\n".join(out), toc)


def render_list(lines: list[str], i: int, out: list[str], link) -> int:
    """A list and its one nested level. Indented lines continue the item above them."""
    first = ITEM.match(lines[i])
    indent = len(first.group(1))
    ordered = first.group(2)[0].isdigit()
    start = int(first.group(2)[:-1]) if ordered else 1
    items: list[list[str]] = []          # each item: its own lines, nested lines kept raw
    loose = False
    while i < len(lines):
        line = lines[i]
        m = ITEM.match(line)
        if m and len(m.group(1)) == indent and m.group(2)[0].isdigit() == ordered:
            items.append([m.group(3)])
            i += 1
            continue
        if not line.strip():
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            nxt = lines[j] if j < len(lines) else ""
            m2 = ITEM.match(nxt)
            nested = len(nxt) - len(nxt.lstrip(" ")) > indent
            if (m2 and len(m2.group(1)) == indent and m2.group(2)[0].isdigit() == ordered) or (nxt.strip() and nested):
                loose = True
                items[-1].append("")
                i = j
                continue
            break
        if len(line) - len(line.lstrip(" ")) > indent or not starts_new_block(line):
            items[-1].append(line)
            i += 1
            continue
        break
    tag = "ol" if ordered else "ul"
    attr = f' start="{start}"' if ordered and start != 1 else ""
    html_items = []
    for item in items:
        head, rest = item[0], item[1:]
        text_lines, nested = [head], []
        for k, l in enumerate(rest):
            if ITEM.match(l) and len(ITEM.match(l).group(1)) > indent:
                nested = rest[k:]
                break
            text_lines.append(l)
        paras = [p for p in "\n".join(text_lines).split("\n\n") if p.strip()]
        inner = []
        for p in paras:
            body = inline(" ".join(s.strip() for s in p.split("\n")), link)
            inner.append(f"<p>{body}</p>" if loose or len(paras) > 1 else body)
        if nested:
            pad = min(len(l) - len(l.lstrip(" ")) for l in nested if l.strip())
            sub: list[str] = []
            render_list([l[pad:] for l in nested], 0, sub, link)
            inner.append("".join(sub))
        html_items.append("<li>" + "".join(inner) + "</li>")
    out.append(f"<{tag}{attr}>" + "".join(html_items) + f"</{tag}>")
    return i


def starts_new_block(line: str) -> bool:
    return bool(FENCE.match(line) or HEADING.match(line) or ANCHOR.match(line) or line.startswith("|"))


# ---------------------------------------------------------------- site

def page_name(md_name: str) -> str:
    return "index.html" if md_name == "README.md" else md_name[:-3] + ".html"


def make_linker(names: set[str], source: str):
    """Doc links become site pages; other repo paths go to GitHub; URLs and anchors stay."""
    def link(target: str) -> str:
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            return target
        path, _, anchor = target.partition("#")
        frag = f"#{anchor}" if anchor else ""
        if "/" not in path and path in names:
            return page_name(path) + frag
        resolved = (DOCS / path).resolve()
        try:
            rel = resolved.relative_to(ROOT).as_posix()
        except ValueError:
            return target
        kind = "tree" if resolved.is_dir() else "blob"
        return f"{REPO}/{kind}/main/{rel}{frag}"
    return link


def navigation(readme: str) -> list[tuple[str, list[tuple[str, str, str]]]]:
    """[(group, [(file.md, title, blurb)])] from docs/README.md."""
    groups: list[tuple[str, list[tuple[str, str, str]]]] = []
    for line in readme.splitlines():
        h = re.match(r"^##\s+(.*)$", line)
        if h:
            groups.append((h.group(1).strip(), []))
            continue
        m = re.match(r"^- \[([^\]]+)\]\(([\w.-]+\.md)\)(?::\s*(.*))?$", line)
        if m and groups:
            groups[-1][1].append((m.group(2), m.group(1), m.group(3) or ""))
    if not groups:
        raise SystemExit("docs/README.md has no '## Group' with '- [Title](file.md)' lines")
    return groups


def version() -> str:
    with open(ROOT / "Resources" / "Info.plist", "rb") as f:
        return plistlib.load(f)["CFBundleShortVersionString"]


def esc(s: str) -> str:
    return html.escape(s, quote=True)


def nav_html(groups, current: str, link) -> str:
    parts = ['<a class="nav-home' + (' on' if current == "README.md" else '') + '" href="index.html"'
             + (' aria-current="page"' if current == "README.md" else '') + '>Overview</a>']
    for group, docs in groups:
        parts.append(f'<p class="nav-group">{esc(group)}</p><ul>')
        for name, title, _ in docs:
            on = name == current
            parts.append(f'<li><a href="{page_name(name)}"' + (' class="on" aria-current="page"' if on else "")
                         + f">{inline(title, link)}</a></li>")
        parts.append("</ul>")
    return "".join(parts)


def tabs_html(groups, current: str, link) -> str:
    parts = ['<a href="index.html"' + (' class="on" aria-current="page"' if current == "README.md" else "") + ">Overview</a>"]
    for _, docs in groups:
        parts.append('<span class="sep" aria-hidden="true"></span>')
        for name, title, _ in docs:
            on = name == current
            parts.append(f'<a href="{page_name(name)}"' + (' class="on" aria-current="page"' if on else "")
                         + f">{inline(title, link)}</a>")
    return "".join(parts)


def toc_html(toc) -> str:
    if not toc:
        return ""
    return "<ul>" + "".join(f'<li class="lv{lvl}"><a href="#{hid}">{text}</a></li>' for lvl, hid, text in toc) + "</ul>"


def pager(order, current: str) -> str:
    try:
        k = [n for n, _ in order].index(current)
    except ValueError:
        return ""
    prev_ = order[k - 1] if k > 0 else None
    next_ = order[k + 1] if k + 1 < len(order) else None
    out = '<nav class="pager" aria-label="Previous and next">'
    out += (f'<a class="prev" href="{page_name(prev_[0])}"><span>Previous</span>{esc(prev_[1])}</a>' if prev_ else "<span></span>")
    out += (f'<a class="next" href="{page_name(next_[0])}"><span>Next</span>{esc(next_[1])}</a>' if next_ else "<span></span>")
    return out + "</nav>"


def build(out_dir: Path, layout: str) -> list[Path]:
    if layout not in LAYOUTS:
        raise SystemExit(f"--layout must be one of {', '.join(LAYOUTS)}")
    sources = sorted(DOCS.glob("*.md"))
    if not sources:
        raise SystemExit("no docs/*.md to render")
    names = {p.name for p in sources}
    groups = navigation((DOCS / "README.md").read_text("utf-8"))
    order = [("README.md", "Overview")] + [(n, plain(t)) for _, docs in groups for n, t, _ in docs]
    missing = [n for n, _ in order if n not in names]
    if missing:
        raise SystemExit(f"docs/README.md links to missing docs: {', '.join(missing)}")
    template = (ASSETS / "page.html").read_text("utf-8")
    ver = version()
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for src in sources:
        link = make_linker(names, src.name)
        doc = render(src.read_text("utf-8"), link)
        title = doc.title or src.stem
        toc = toc_html(doc.toc)
        h1, _, body = doc.body.partition("\n") if doc.body.startswith("<h1") else ("", "", doc.body)
        lead = ""
        if body.startswith("<p>"):
            lead, _, body = body.partition("\n")
        page = template
        for key, value in {
            "{{layout}}": layout,
            "{{title}}": esc(title),
            "{{page_title}}": esc("Hook docs" if src.name == "README.md" else f"{title} · Hook docs"),
            "{{description}}": esc(next((b for n, _, b in (d for _, ds in groups for d in ds) if n == src.name), "")
                                   or "Hook documentation"),
            "{{nav}}": nav_html(groups, src.name, link),
            "{{tabs}}": tabs_html(groups, src.name, link),
            "{{toc}}": toc,
            "{{toc_class}}": "" if toc else " empty",
            "{{h1}}": h1,
            "{{lead}}": lead.replace("<p>", '<p class="lead">', 1),
            "{{body}}": body,
            "{{pager}}": pager(order, src.name),
            "{{source}}": f"{REPO}/blob/main/docs/{src.name}",
            "{{version}}": esc(ver),
        }.items():
            page = page.replace(key, value)
        target = out_dir / page_name(src.name)
        target.write_text(page, "utf-8")
        written.append(target)
    for asset in ("docs.css", "docs.js"):
        shutil.copyfile(ASSETS / asset, out_dir / asset)
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--out", type=Path, default=ROOT / "site" / "docs")
    ap.add_argument("--layout", default="sidebar", choices=LAYOUTS)
    args = ap.parse_args(argv)
    pages = build(args.out, args.layout)
    print(f"{len(pages)} pages in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
