"""Regression test for scripts/scrape-docs.py discovery ladder.

Covers issue #68: the scraper accepted thin llms.txt results without falling
through to sitemap/crawl, causing real-world targets like docs.github.com to
fail the coverage gate even though sitemap+crawl would have produced enough
pages.

Runs without pytest. Stubs heavy native deps (scrapling, trafilatura,
defusedxml) before importing the scraper, then monkey-patches the discovery
and fetch helpers to simulate stage outcomes deterministically.

Run: python3 tests/test_scrape_docs_pipeline.py
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import types
import unittest
from dataclasses import dataclass
from pathlib import Path


def _stub_heavy_imports() -> None:
    """scrape-docs imports scrapling/trafilatura/defusedxml at module load.
    Stub them so the import succeeds in environments without .venv-scrape.
    """
    if "scrapling" not in sys.modules:
        scrapling = types.ModuleType("scrapling")
        fetchers = types.ModuleType("scrapling.fetchers")
        for name in ("Fetcher", "StealthyFetcher", "PlayWrightFetcher"):
            setattr(fetchers, name, type(name, (), {"get": staticmethod(lambda *a, **k: None)}))
        scrapling.fetchers = fetchers
        sys.modules["scrapling"] = scrapling
        sys.modules["scrapling.fetchers"] = fetchers

    if "trafilatura" not in sys.modules:
        trafilatura = types.ModuleType("trafilatura")
        trafilatura.extract = lambda *a, **k: None  # type: ignore
        sys.modules["trafilatura"] = trafilatura

    if "defusedxml" not in sys.modules:
        defusedxml = types.ModuleType("defusedxml")
        et = types.ModuleType("defusedxml.ElementTree")
        et.fromstring = lambda *a, **k: None  # type: ignore
        defusedxml.ElementTree = et
        sys.modules["defusedxml"] = defusedxml
        sys.modules["defusedxml.ElementTree"] = et


_stub_heavy_imports()

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "scrape_docs", REPO / "scripts" / "scrape-docs.py"
)
assert SPEC is not None and SPEC.loader is not None
scrape_docs = importlib.util.module_from_spec(SPEC)
# Register before exec_module: Python 3.12+ dataclasses look the module up in
# sys.modules during class construction.
sys.modules["scrape_docs"] = scrape_docs
SPEC.loader.exec_module(scrape_docs)


@dataclass
class FakeStage:
    name: str
    urls: list[str]
    extract_md: dict[str, str]  # url -> markdown


def _install_fakes(test: unittest.TestCase, stages: dict[str, FakeStage]) -> None:
    """Patch discovery + fetch + extraction helpers to play deterministic stages."""

    test.addCleanup(setattr, scrape_docs, "discover_doc_subdomain", scrape_docs.discover_doc_subdomain)
    test.addCleanup(setattr, scrape_docs, "discover_openapi", scrape_docs.discover_openapi)
    test.addCleanup(setattr, scrape_docs, "discover_llms_full", scrape_docs.discover_llms_full)
    test.addCleanup(setattr, scrape_docs, "discover_llms_txt", scrape_docs.discover_llms_txt)
    test.addCleanup(setattr, scrape_docs, "discover_mint_json", scrape_docs.discover_mint_json)
    test.addCleanup(setattr, scrape_docs, "discover_sitemap", scrape_docs.discover_sitemap)
    test.addCleanup(setattr, scrape_docs, "crawl_from_seed", scrape_docs.crawl_from_seed)
    test.addCleanup(setattr, scrape_docs, "fetch_many", scrape_docs.fetch_many)
    test.addCleanup(setattr, scrape_docs, "html_to_markdown", scrape_docs.html_to_markdown)

    scrape_docs.discover_doc_subdomain = lambda base_url: None
    scrape_docs.discover_openapi = lambda base_url, out_dir: None
    scrape_docs.discover_llms_full = lambda base_url: None
    scrape_docs.discover_llms_txt = lambda base_url: stages["llms.txt"].urls if "llms.txt" in stages else []
    scrape_docs.discover_mint_json = lambda base_url: stages["mint.json"].urls if "mint.json" in stages else []
    scrape_docs.discover_sitemap = lambda base_url: stages["sitemap.xml"].urls if "sitemap.xml" in stages else []

    # crawl returns (url, html, fetcher) tuples
    crawl_pages = stages.get("crawl")
    def _fake_crawl(seed, max_depth, max_pages, concurrency):
        if crawl_pages is None:
            return []
        return [(u, f"<html>{u}</html>", "fake") for u in crawl_pages.urls]
    scrape_docs.crawl_from_seed = _fake_crawl

    # fetch_many returns (successes, failures); successes are (url, html, fetcher)
    def _fake_fetch_many(urls, concurrency):
        successes = [(u, f"<html>{u}</html>", "fake") for u in urls]
        return successes, []
    scrape_docs.fetch_many = _fake_fetch_many

    # html_to_markdown looks up the URL in the stage's extract_md table
    all_md: dict[str, str] = {}
    for stage in stages.values():
        all_md.update(stage.extract_md)
    def _fake_html_to_md(html, url):
        return all_md.get(url, "")
    scrape_docs.html_to_markdown = _fake_html_to_md


def _make_md(url: str, size: int = 600) -> str:
    """Markdown ≥ MIN_MARKDOWN_CHARS so it passes the size filter."""
    return f"# {url}\n\n" + ("body content " * (size // 12))


class DiscoveryLadderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="scrape-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_thin_llms_falls_through_to_sitemap(self):
        """docs.github.com pattern: 19-page llms.txt traps below the 20-page
        gate. Sitemap with 25 pages should win, not llms.txt.
        """
        llms_urls = [f"https://example.com/api/endpoint/{i}" for i in range(19)]
        sitemap_urls = [f"https://example.com/docs/page-{i}" for i in range(25)]
        stages = {
            "llms.txt": FakeStage(
                "llms.txt", llms_urls, {u: _make_md(u) for u in llms_urls}
            ),
            "sitemap.xml": FakeStage(
                "sitemap.xml", sitemap_urls, {u: _make_md(u) for u in sitemap_urls}
            ),
        }
        _install_fakes(self, stages)

        result = scrape_docs.run_pipeline(
            base_url="https://example.com",
            out_dir=self.tmp,
            min_pages=20,
            max_pages=500,
            concurrency=4,
        )
        self.assertEqual(result.discovery, "sitemap.xml")
        self.assertEqual(len(result.pages), 25)
        # Files left on disk should match the winner only — llms.txt's 19
        # files should have been cleaned up by commit().
        md_files = list(self.tmp.glob("**/*.md"))
        self.assertEqual(len(md_files), 25, f"expected 25 surviving .md files, got {len(md_files)}")

    def test_healthy_llms_accepted_short_circuits(self):
        """Healthy llms.txt with ≥ min_pages should be accepted on first match."""
        urls = [f"https://example.com/docs/page-{i}" for i in range(30)]
        stages = {
            "llms.txt": FakeStage("llms.txt", urls, {u: _make_md(u) for u in urls}),
            # mint.json/sitemap should never be probed in this scenario, but
            # provide them anyway to confirm short-circuit doesn't dip deeper.
            "sitemap.xml": FakeStage("sitemap.xml", [f"https://example.com/s/{i}" for i in range(50)], {}),
        }
        _install_fakes(self, stages)

        result = scrape_docs.run_pipeline(
            base_url="https://example.com",
            out_dir=self.tmp,
            min_pages=20,
            max_pages=500,
            concurrency=4,
        )
        self.assertEqual(result.discovery, "llms.txt")
        self.assertEqual(len(result.pages), 30)

    def test_micro_product_falls_back_to_llms(self):
        """6-page product: nothing clears min_pages, but llms.txt cleared the
        ABS_FLOOR. Should be retained as a fallback, not silently dropped.
        """
        urls = [f"https://tiny.example/docs/page-{i}" for i in range(6)]
        stages = {
            "llms.txt": FakeStage("llms.txt", urls, {u: _make_md(u) for u in urls}),
        }
        _install_fakes(self, stages)

        result = scrape_docs.run_pipeline(
            base_url="https://tiny.example",
            out_dir=self.tmp,
            min_pages=20,
            max_pages=500,
            concurrency=4,
        )
        # Below min_pages, but above floor — fallback retains it with tag.
        self.assertIn("llms.txt", result.discovery)
        self.assertIn("below min_pages", result.discovery)
        self.assertEqual(len(result.pages), 6)

    def test_below_floor_discarded(self):
        """A stage with < ABS_FLOOR pages is noise; should be cleaned, not retained."""
        urls = [f"https://example.com/x/{i}" for i in range(3)]
        stages = {
            "llms.txt": FakeStage("llms.txt", urls, {u: _make_md(u) for u in urls}),
        }
        _install_fakes(self, stages)

        result = scrape_docs.run_pipeline(
            base_url="https://example.com",
            out_dir=self.tmp,
            min_pages=20,
            max_pages=500,
            concurrency=4,
        )
        self.assertEqual(result.discovery, "")
        self.assertEqual(len(result.pages), 0)
        md_files = list(self.tmp.glob("**/*.md"))
        self.assertEqual(len(md_files), 0, f"orphans not cleaned: {md_files}")

    def test_largest_fallback_wins(self):
        """When no stage clears min_pages but two stages clear ABS_FLOOR,
        keep the larger one and clean the smaller.
        """
        small = [f"https://example.com/a/{i}" for i in range(7)]
        bigger = [f"https://example.com/b/{i}" for i in range(15)]
        stages = {
            "llms.txt": FakeStage("llms.txt", small, {u: _make_md(u) for u in small}),
            "sitemap.xml": FakeStage("sitemap.xml", bigger, {u: _make_md(u) for u in bigger}),
        }
        _install_fakes(self, stages)

        result = scrape_docs.run_pipeline(
            base_url="https://example.com",
            out_dir=self.tmp,
            min_pages=20,
            max_pages=500,
            concurrency=4,
        )
        self.assertIn("sitemap.xml", result.discovery)
        self.assertIn("below min_pages", result.discovery)
        self.assertEqual(len(result.pages), 15)
        md_files = list(self.tmp.glob("**/*.md"))
        self.assertEqual(len(md_files), 15, f"expected 15 fallback files, got {len(md_files)}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
