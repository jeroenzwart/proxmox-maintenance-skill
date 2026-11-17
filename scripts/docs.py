#!/usr/bin/env python3
"""Version-aware search over the locally installed Proxmox documentation.

PVE, PBS and PDM each ship their complete manual as HTML on the host, and apt
keeps it in lockstep with the installed version, so the local copy is always
the correct manual for *this* machine. This script turns that HTML into a
plain-text index per product, stamps the index with the installed version,
and rebuilds it automatically the moment the version changes.

Commands (all take --product pve|pbs|pdm; without it, every installed product):
  status                 versions, whether the index and the cached online
                         notes are current
  sync [--force]         (re)build the index if the version or docs changed
  search QUERY [-n N]    ranked sections; prints doc id, title and a snippet
  show DOC_ID [--chars N]  full text of one section
  online-path [--version V]  where to store fetched release notes

With more than one product, doc ids carry a product prefix (`pbs:maintenance#pruning`).

Everything is read-only with respect to the system; the only writes go to the
cache directory (default: $XDG_CACHE_HOME/proxmox-skill/<product>).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path


@dataclass(frozen=True)
class Product:
    label: str
    docs_dir: Path
    version_pkg: str
    docs_pkg: str
    # Release notes and known issues, formatted with the major.minor version.
    # None where the installed docs already carry them.
    notes_url: str | None
    issues_url: str | None


PRODUCTS: dict[str, Product] = {
    "pve": Product(
        "Proxmox VE",
        Path("/usr/share/pve-docs"),
        "pve-manager",
        "pve-docs",
        "https://pve.proxmox.com/wiki/Roadmap#Proxmox_VE_{version}",
        "https://pve.proxmox.com/wiki/Roadmap#{version}-known-issues",
    ),
    "pbs": Product(
        "Proxmox Backup Server",
        Path("/usr/share/doc/proxmox-backup/html"),
        "proxmox-backup-server",
        "proxmox-backup-docs",
        "https://pbs.proxmox.com/wiki/Roadmap#Proxmox_Backup_Server_{version}",
        "https://pbs.proxmox.com/wiki/Roadmap#{version}-known-issues",
    ),
    # PDM ships its roadmap, release notes included, in the local docs.
    "pdm": Product(
        "Proxmox Datacenter Manager",
        Path("/usr/share/doc/proxmox-datacenter-manager/html"),
        "proxmox-datacenter-manager",
        "proxmox-datacenter-manager-docs",
        None,
        None,
    ),
}

CACHE_ROOT = Path(
    os.environ.get("PROXMOX_SKILL_CACHE")
    or (Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "proxmox-skill")
)

SKIP_TAGS = {"script", "style", "head"}
SKIP_PAGES = {"index.html", "genindex.html", "search.html"}
STOPWORDS = {
    "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "are",
    "how", "do", "i", "my", "with", "what", "why",
}


# --------------------------------------------------------------------------
# products and versions
# --------------------------------------------------------------------------

def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return out.stdout.strip()
    except Exception:
        return ""


def package_field(package: str, field: str) -> str:
    return _run(["dpkg-query", "-W", "-f", "${" + field + "}", package])


def installed_products() -> list[str]:
    """The products whose server package is installed, in pve/pbs/pdm order."""
    return [
        key for key, product in PRODUCTS.items()
        if package_field(product.version_pkg, "Status") == "install ok installed"
    ]


def cache_dir(product: str) -> Path:
    return CACHE_ROOT / product


def index_path(product: str) -> Path:
    return cache_dir(product) / "docs-index.jsonl"


def manifest_path(product: str) -> Path:
    return cache_dir(product) / "docs-manifest.json"


def current_versions(product: str) -> dict:
    """Identify the installed product version and its docs package.

    The server package is what the user thinks of as "the version"; the docs
    package is what actually determines the content of the index. Tracking
    both means we rebuild on a docs-only update too, and we can tell the user
    plainly which manual they are reading.
    """
    spec = PRODUCTS[product]
    newest_mtime = 0.0
    file_count = 0
    if spec.docs_dir.is_dir():
        for p in spec.docs_dir.glob("*.html"):
            file_count += 1
            try:
                newest_mtime = max(newest_mtime, p.stat().st_mtime)
            except OSError:
                pass

    return {
        "product": product,
        "version": package_field(spec.version_pkg, "Version"),
        "docs_pkg": package_field(spec.docs_pkg, "Version"),
        "kernel": _run(["uname", "-r"]),
        "docs_dir": str(spec.docs_dir),
        "docs_file_count": file_count,
        "docs_newest_mtime": round(newest_mtime, 3),
    }


def major_minor(version: str) -> str:
    m = re.match(r"(\d+\.\d+)", version or "")

    return m.group(1) if m else (version or "unknown")


def load_manifest(product: str) -> dict:
    try:
        return json.loads(manifest_path(product).read_text())
    except Exception:
        return {}


def index_is_current(product: str, cur: dict, manifest: dict) -> tuple[bool, str]:
    if not index_path(product).exists() or not manifest:
        return False, "no index yet"
    for key, label in (
        ("version", "product version"),
        ("docs_pkg", "docs package"),
        ("docs_newest_mtime", "docs files"),
        ("docs_file_count", "docs file count"),
    ):
        if manifest.get(key) != cur.get(key):
            return False, (
                f"{label} changed: {manifest.get(key)!r} -> {cur.get(key)!r}"
            )

    return True, "current"


# --------------------------------------------------------------------------
# HTML -> sections
# --------------------------------------------------------------------------

class SectionParser(HTMLParser):
    """Split a generated docs page into (anchor, title, text) sections.

    Rather than assuming a particular div nesting, we simply treat every
    heading as the start of a new section and collect the text that follows
    it. That survives changes in how the docs are generated between releases,
    and covers both PVE's asciidoc and the Sphinx output of PBS and PDM.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.sections: list[dict] = []
        self.cur = {"anchor": "", "title": "", "parts": []}
        self._skip_depth = 0
        self._sidebar_depth = 0
        self._in_heading = False
        self._heading_anchor = ""
        self._heading_parts: list[str] = []
        self._pending_id = ""

    def _flush(self) -> None:
        text = re.sub(r"\s+", " ", "".join(self.cur["parts"])).strip()
        title = self.cur["title"].strip()
        if title or text:
            self.sections.append(
                {"anchor": self.cur["anchor"], "title": title, "text": text}
            )

    def handle_starttag(self, tag, attrs):
        attrd = dict(attrs)
        # Sphinx repeats navigation and search in a sidebar on every page;
        # its headings would otherwise become sections of their own.
        if self._sidebar_depth:
            if tag == "div":
                self._sidebar_depth += 1
            return
        if tag == "div" and "sphinxsidebar" in (attrd.get("class") or "").split():
            self._sidebar_depth = 1
            return
        if tag in SKIP_TAGS:
            self._skip_depth += 1
            return
        # Sphinx puts the anchor on the enclosing <section>, asciidoc on the
        # heading itself; the first id seen since the last heading covers both.
        if attrd.get("id") and not self._pending_id:
            self._pending_id = attrd["id"]
        if re.fullmatch(r"h[1-6]", tag):
            self._flush()
            self.cur = {"anchor": "", "title": "", "parts": []}
            self._in_heading = True
            self._heading_anchor = attrd.get("id") or self._pending_id or ""
            self._heading_parts = []

    def handle_endtag(self, tag):
        if self._sidebar_depth:
            if tag == "div":
                self._sidebar_depth -= 1
            return
        if tag in SKIP_TAGS:
            self._skip_depth = max(0, self._skip_depth - 1)
            return
        if re.fullmatch(r"h[1-6]", tag) and self._in_heading:
            self._in_heading = False
            # Sphinx appends a "¶" permalink to every heading.
            title = "".join(self._heading_parts).replace("¶", "")
            self.cur["title"] = re.sub(r"\s+", " ", title)
            self.cur["anchor"] = self._heading_anchor
            self._pending_id = ""

    def handle_data(self, data):
        if self._skip_depth or self._sidebar_depth:
            return
        if self._in_heading:
            self._heading_parts.append(data)
        else:
            self.cur["parts"].append(data)

    def close(self):
        super().close()
        self._flush()


def parse_sections(html: str) -> list[dict]:
    parser = SectionParser()
    parser.feed(html)
    parser.close()

    return parser.sections


def source_files(docs_dir: Path) -> list[Path]:
    """Pick one copy of each page, best copy first.

    pve-docs ships the same prose three times over: as `chapter-foo.html`, as
    a `foo-plain.html` fragment, and again inside the single-page
    `pve-admin-guide.html`. Indexing all of them buries the reader in
    triplicate hits, so we drop the omnibus guide outright and order the rest
    so that the nicely-titled chapter pages are seen first - the dedup pass in
    build_index() then keeps whichever copy arrives first. Sphinx adds index,
    search and genindex pages that hold no prose.
    """
    if not docs_dir.is_dir():
        return []
    picked = []
    for p in sorted(docs_dir.glob("*.html")):
        if p.name in SKIP_PAGES or p.name.startswith("pve-admin-guide"):
            continue
        picked.append(p)

    def rank(p: Path) -> tuple[int, str]:
        if p.name.startswith("chapter-"):
            return (0, p.name)
        if p.name.endswith("-plain.html"):
            return (2, p.name)

        return (1, p.name)

    picked.sort(key=rank)

    return picked


def fingerprint(title: str, text: str) -> str:
    key = re.sub(r"\W+", " ", (title + " " + text[:400]).lower()).strip()

    return hashlib.sha1(key.encode()).hexdigest()


def build_index(product: str) -> dict:
    cache_dir(product).mkdir(parents=True, exist_ok=True)
    (cache_dir(product) / "online").mkdir(parents=True, exist_ok=True)
    files = source_files(PRODUCTS[product].docs_dir)
    n_sections = 0
    n_dupes = 0
    seen: set[str] = set()
    tmp = index_path(product).with_suffix(".tmp")
    with tmp.open("w") as fh:
        for path in files:
            try:
                sections = parse_sections(path.read_text(errors="replace"))
            except Exception:
                continue
            page = path.name[: -len(".html")]
            for i, sec in enumerate(sections):
                if len(sec["text"]) < 40 and not sec["title"]:
                    continue
                fp = fingerprint(sec["title"], sec["text"])
                if fp in seen:
                    n_dupes += 1
                    continue
                seen.add(fp)
                doc_id = f"{page}#{sec['anchor']}" if sec["anchor"] else f"{page}:{i}"
                rec = {
                    "id": doc_id,
                    "page": page,
                    "title": sec["title"],
                    "text": sec["text"][:20000],
                    "path": str(path),
                }
                fh.write(json.dumps(rec) + "\n")
                n_sections += 1
    tmp.replace(index_path(product))

    manifest = current_versions(product)
    manifest.update(
        {
            "sections": n_sections,
            "duplicates_dropped": n_dupes,
            "pages": len(files),
            "built_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "built_at_epoch": int(time.time()),
        }
    )
    manifest_path(product).write_text(json.dumps(manifest, indent=2))

    return manifest


def ensure_index(product: str, force: bool = False, quiet: bool = False) -> dict:
    cur = current_versions(product)
    manifest = load_manifest(product)
    ok, reason = index_is_current(product, cur, manifest)
    if ok and not force:
        return manifest
    docs_dir = PRODUCTS[product].docs_dir
    if not docs_dir.is_dir():
        print(
            f"WARNING: {docs_dir} not found - is {PRODUCTS[product].docs_pkg} installed?",
            file=sys.stderr,
        )
        return manifest
    if not quiet:
        print(f"[docs:{product}] rebuilding index ({reason})...", file=sys.stderr)

    return build_index(product)


# --------------------------------------------------------------------------
# search
# --------------------------------------------------------------------------

def tokenize(s: str) -> list[str]:
    return [t for t in re.findall(r"[a-z0-9_.\-/]+", s.lower()) if t not in STOPWORDS]


def iter_index(product: str):
    path = index_path(product)
    if not path.exists():
        return
    with path.open() as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except Exception:
                continue


def search(query: str, limit: int, products: list[str]) -> list[tuple[float, dict, str]]:
    """Rank sections with BM25 plus a title boost.

    Plain term counting was tried first and ranked badly: a long, rambling
    chapter that mentions "quorum" twenty times beat the short section
    actually titled "Corosync External Vote Support". BM25 fixes that by
    saturating repeated terms and normalising for section length, and rare
    words (qdevice) end up worth far more than common ones (cluster).

    With several products the corpora are ranked together and each id gets
    a product prefix, so a hit says which manual it came from.
    """
    terms = tokenize(query)
    if not terms:
        return []

    recs = []
    for product in products:
        for rec in iter_index(product):
            if len(products) > 1:
                rec["id"] = f"{product}:{rec['id']}"
            recs.append(rec)
    if not recs:
        return []

    docs = []
    df: dict[str, int] = {}
    for rec in recs:
        title_l = rec["title"].lower()
        text_l = rec["text"].lower()
        counts = {}
        for t in set(terms):
            c = text_l.count(t) + 3 * title_l.count(t)
            if c:
                counts[t] = c
                df[t] = df.get(t, 0) + 1
        docs.append((rec, title_l, text_l, counts, max(1, len(text_l.split()))))

    n = len(docs)
    avg_len = sum(d[4] for d in docs) / n
    k1, b = 1.2, 0.6

    results = []
    for rec, title_l, text_l, counts, dl in docs:
        if not counts:
            continue
        score = 0.0
        for t, tf in counts.items():
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * dl / avg_len))
        # Covering every term beats covering one term loudly.
        score *= 1 + 0.6 * (len(counts) - 1)
        # An exact phrase match is the strongest signal we have.
        q = " ".join(terms)
        if q in title_l:
            score *= 2.5
        elif q in text_l:
            score *= 1.4
        if rec["page"].startswith("chapter-"):
            score *= 1.1
        results.append((score, rec, snippet(text_l, rec["text"], terms)))
    results.sort(key=lambda r: -r[0])

    return results[:limit]


def snippet(text_l: str, text: str, terms: list[str], width: int = 260) -> str:
    pos = -1
    for t in terms:
        p = text_l.find(t)
        if p != -1 and (pos == -1 or p < pos):
            pos = p
    if pos == -1:
        pos = 0
    start = max(0, pos - width // 3)
    out = text[start : start + width].strip()

    return ("..." if start else "") + out + ("..." if start + width < len(text) else "")


# --------------------------------------------------------------------------
# online notes
# --------------------------------------------------------------------------

def online_note_path(product: str, version: str) -> Path:
    return cache_dir(product) / "online" / f"release-notes-{version}.md"


def online_status(product: str, cur: dict) -> tuple[Path | None, bool, str]:
    if PRODUCTS[product].notes_url is None:
        return None, True, "local - the installed docs include roadmap.html"
    ver = major_minor(cur.get("version", ""))
    path = online_note_path(product, ver)
    if path.exists():
        age_days = (time.time() - path.stat().st_mtime) / 86400
        return path, True, f"present, {age_days:.0f} day(s) old"

    return path, False, "MISSING - fetch release notes / known issues for this version"


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------

def selected_products(args) -> list[str]:
    if args.product:
        return [args.product]
    products = installed_products()
    if not products:
        print("No Proxmox product installed (pve-manager, proxmox-backup-server, "
              "proxmox-datacenter-manager). Use --product to pick one.", file=sys.stderr)
        sys.exit(1)

    return products


def cmd_status(args) -> int:
    for product in selected_products(args):
        spec = PRODUCTS[product]
        cur = current_versions(product)
        manifest = load_manifest(product)
        ok, reason = index_is_current(product, cur, manifest)
        ver = major_minor(cur.get("version", ""))
        print(f"== {spec.label} ({product})")
        print(f"Version          : {cur.get('version') or 'unknown'} (series {ver})")
        print(f"Running kernel   : {cur.get('kernel')}")
        print(f"{spec.docs_pkg:<17}: {cur.get('docs_pkg') or 'not installed'}")
        print(f"Local docs       : {cur.get('docs_file_count')} pages in {cur.get('docs_dir')}")
        print(f"Index            : {'current' if ok else 'STALE (' + reason + ')'}")
        if manifest:
            print(
                f"  built {manifest.get('built_at')} - "
                f"{manifest.get('sections')} sections from {manifest.get('pages')} pages"
                f" (docs {manifest.get('docs_pkg')})"
            )
        path, present, note = online_status(product, cur)
        print(f"Online notes     : {note}")
        if path:
            print(f"  file: {path}")
        if not ok:
            print(f"\nACTION: run `docs.py --product {product} sync` to rebuild the local index.")
        if not present:
            print(
                f"\nACTION: fetch the release notes and known issues for {spec.label} {ver} from\n"
                f"  {spec.notes_url.format(version=ver)}\n"
                f"  {spec.issues_url.format(version=ver)}\n"
                f"and save a summary to {path}"
            )
        print()

    return 0


def cmd_sync(args) -> int:
    for product in selected_products(args):
        manifest = ensure_index(product, force=args.force)
        print(
            f"{product}: index ready, {manifest.get('sections')} sections from "
            f"{manifest.get('pages')} pages, docs {manifest.get('docs_pkg')}, "
            f"version {manifest.get('version')}"
        )
        path, present, note = online_status(product, current_versions(product))
        if not present:
            print(f"{product}: online notes {note}")

    return 0


def cmd_search(args) -> int:
    products = selected_products(args)
    for product in products:
        ensure_index(product, quiet=True)
    hits = search(" ".join(args.query), args.n, products)
    if not hits:
        print("No matches. Try fewer or more common terms, or check `status`.")
        return 1
    for score, rec, snip in hits:
        title = rec["title"] or "(untitled)"
        print(f"\n### {title}   [{rec['id']}]  score={score:.0f}")
        print(f"    {snip}")
    print(f"\n{len(hits)} result(s). Full text: docs.py show '<id>'   |   HTML: file://<path>#<anchor>")

    return 0


def cmd_show(args) -> int:
    products = selected_products(args)
    wanted = args.doc_id
    prefix, sep, rest = wanted.partition(":")
    if sep and prefix in PRODUCTS:
        products, wanted = [prefix], rest
    for product in products:
        ensure_index(product, quiet=True)
        for rec in iter_index(product):
            if rec["id"] == wanted:
                print(f"# {rec['title']}   [{rec['id']}]")
                print(f"# source: {rec['path']}\n")
                print(rec["text"][: args.chars] if args.chars else rec["text"])
                return 0
    print(f"No section with id {args.doc_id!r}. Use `search` to find one.", file=sys.stderr)

    return 1


def cmd_online_path(args) -> int:
    products = selected_products(args)
    if len(products) > 1:
        print("Several products installed; pick one with --product.", file=sys.stderr)
        return 2
    product = products[0]
    if PRODUCTS[product].notes_url is None:
        print(f"{product} keeps its release notes in the installed docs (roadmap.html).", file=sys.stderr)
        return 1
    ver = args.version or major_minor(current_versions(product).get("version", ""))
    (cache_dir(product) / "online").mkdir(parents=True, exist_ok=True)
    print(online_note_path(product, ver))

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--product", choices=sorted(PRODUCTS))
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)

    p = sub.add_parser("sync")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("search")
    p.add_argument("query", nargs="+")
    p.add_argument("-n", type=int, default=6)
    p.set_defaults(func=cmd_search)

    p = sub.add_parser("show")
    p.add_argument("doc_id")
    p.add_argument("--chars", type=int, default=6000)
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("online-path")
    p.add_argument("--version")
    p.set_defaults(func=cmd_online_path)

    args = ap.parse_args()

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
