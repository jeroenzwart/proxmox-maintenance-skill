import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "docs"

# Loaded by path: the name "docs" would resolve to the repository's docs/ folder.
spec = importlib.util.spec_from_file_location("proxmox_docs", ROOT / "scripts" / "docs.py")
proxmox_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxmox_docs)


def sections_of(name):
    return proxmox_docs.parse_sections((FIXTURES / name).read_text())


class AsciidocTest(unittest.TestCase):
    def test_asciidoc_anchor(self):
        anchors = [section["anchor"] for section in sections_of("asciidoc.html")]

        self.assertIn("_bind_mount_points", anchors)


class SphinxTest(unittest.TestCase):
    def test_sphinx_anchor_from_section_id(self):
        sections = sections_of("sphinx.html")

        self.assertIn({"anchor": "pruning", "title": "Pruning"},
                      [{"anchor": s["anchor"], "title": s["title"]} for s in sections])

    def test_sphinx_title_has_no_pilcrow(self):
        titles = [section["title"] for section in sections_of("sphinx.html")]

        self.assertFalse([title for title in titles if "¶" in title])

    def test_sphinx_sidebar_ignored(self):
        titles = [section["title"] for section in sections_of("sphinx.html")]

        self.assertNotIn("Quick search", titles)
        self.assertNotIn("Navigation", titles)


class SourceFilesTest(unittest.TestCase):
    def test_skipped_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("genindex.html", "search.html", "index.html", "storage.html"):
                (Path(directory) / name).write_text("<h1>x</h1>")

            names = [path.name for path in proxmox_docs.source_files(Path(directory))]

        self.assertEqual(names, ["storage.html"])


class ProductTableTest(unittest.TestCase):
    def test_pdm_has_no_online_notes(self):
        self.assertIsNone(proxmox_docs.PRODUCTS["pdm"].notes_url)


if __name__ == "__main__":
    unittest.main()
