"""The docs site build (scripts/build-docs-site.py): the Markdown it converts, heading ids
that match GitHub's, doc links that become site pages, and a build of the real docs where
every link between pages lands on a page and an id that exist. Standard library only."""
from __future__ import annotations

import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("build_docs_site", ROOT / "scripts" / "build-docs-site.py")
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


def render(md: str) -> str:
    return site.render(md, site.make_linker({"install.md", "README.md", "privacy.md"}, "using.md")).body


class ConverterTests(unittest.TestCase):
    def test_heading_ids_follow_github(self):
        self.assertEqual(site.slug("Settings › Privacy"), "settings--privacy")
        self.assertEqual(site.slug("What a report contains"), "what-a-report-contains")
        body = render("# Title\n\n## The `relay` command\n\n## Notes\n\n## Notes\n")
        self.assertIn('id="the-relay-command"', body)
        self.assertIn('id="notes"', body)
        self.assertIn('id="notes-1"', body)

    def test_code_is_escaped_and_gets_a_copy_button(self):
        body = render("```bash\necho '<b>' && ls\n```\n")
        self.assertIn('<code class="language-bash">echo &#x27;&lt;b&gt;&#x27; &amp;&amp; ls</code>', body)
        self.assertIn('class="copy"', body)
        self.assertIn("<code>&lt;port&gt;</code>", render("Listens on `<port>` only."))

    def test_tables_keep_escaped_pipes_in_code(self):
        body = render("| Command | Does |\n|---|---|\n| `set auto-setup on\\|off` | **Changes** it |\n")
        self.assertIn("<th>Command</th>", body)
        self.assertIn("<code>set auto-setup on|off</code>", body)
        self.assertIn("<strong>Changes</strong>", body)

    def test_lists_nest_and_continue(self):
        body = render("1. First\n   goes on\n2. Second\n   - inner *one*\n   - inner two\n3. Third\n")
        self.assertIn("<ol><li>First goes on</li><li>Second<ul><li>inner <em>one</em></li><li>inner two</li></ul></li>"
                      "<li>Third</li></ol>", body)
        self.assertIn('<ol start="3">', render("3. Three\n4. Four\n"))

    def test_links_become_site_pages_or_github(self):
        body = render("[a](install.md#update) [b](README.md) [c](../SECURITY.md#x) [d](#here) [e](https://x.example)")
        self.assertIn('href="install.html#update"', body)
        self.assertIn('href="index.html"', body)
        self.assertIn('href="https://github.com/xooxoxxo/hook/blob/main/SECURITY.md#x"', body)
        self.assertIn('href="#here"', body)
        self.assertIn('href="https://x.example"', body)

    def test_explicit_anchors_pass_through(self):
        self.assertIn('<a id="old-name"></a>', render('<a id="old-name"></a>\n## New name\n'))
        self.assertIn("&lt;script&gt;", render("A <script> tag."))


class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.pages = {p.name: p.read_text("utf-8") for p in site.build(cls.out, "sidebar")}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_one_page_per_doc_and_the_assets(self):
        expected = {site.page_name(p.name) for p in (ROOT / "docs").glob("*.md")}
        self.assertEqual(set(self.pages), expected)
        self.assertIn("index.html", self.pages)
        for asset in ("docs.css", "docs.js"):
            self.assertTrue((self.out / asset).exists(), asset)

    def test_every_link_between_pages_resolves(self):
        ids = {name: set(re.findall(r'\bid="([^"]+)"', text)) for name, text in self.pages.items()}
        broken = []
        for name, text in self.pages.items():
            for href in re.findall(r'href="([^"]+)"', text):
                if re.match(r"^[a-z]+:", href) or href.startswith("../"):
                    continue
                path, _, anchor = href.partition("#")
                target = path or name
                if target.endswith(".md"):
                    broken.append(f"{name}: {href} (still .md)")
                elif target in ("docs.css", "docs.js"):
                    continue
                elif target not in self.pages:
                    broken.append(f"{name}: {href}")
                elif anchor and anchor not in ids[target]:
                    broken.append(f"{name}: {href}")
        self.assertEqual(broken, [])

    def test_every_page_has_the_shared_parts(self):
        for name, text in self.pages.items():
            with self.subTest(name):
                self.assertIn('href="../index.html"', text)              # the logo leads home
                self.assertIn("hook-tile-128.png", text)
                self.assertNotIn("{{", text)
                if "<h2" in text:
                    self.assertIn('class="toc-side"', text)
                    self.assertRegex(text, r'class="toc-side"[^>]*><p>On this page</p><ul>')

    def test_the_nav_lists_every_doc_in_the_readme(self):
        groups = site.navigation((ROOT / "docs" / "README.md").read_text("utf-8"))
        listed = [n for _, docs in groups for n, _, _ in docs]
        self.assertTrue(listed)
        for name in listed:
            self.assertIn(f'href="{site.page_name(name)}"', self.pages["index.html"])


if __name__ == "__main__":
    unittest.main()
