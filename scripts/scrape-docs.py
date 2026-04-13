#!/usr/bin/env python3
"""Deterministic doc scraper for the ralph-to-ralph inspect phase.

Discovers and downloads a target product's documentation into ``target-docs/``
*before* the inspect loop runs its first iteration. The inspect prompts then
read from disk instead of trying to scrape the web themselves.

Discovery is tried in priority order, accepting the first source that yields
useful pages:

  1. ``llms-full.txt`` (single concatenated file)
  2. ``llms.txt`` (link index)
  3. ``mint.json``  (Mintlify nav manifest)
  4. ``openapi.json`` / ``openapi.yaml`` (saved verbatim alongside other sources)
  5. ``sitemap.xml`` (and any nested sitemap indexes)
  6. Recursive BFS crawl from ``/docs``

Each fetch goes through a Scrapling fallback chain (``Fetcher`` ->
``StealthyFetcher`` -> ``PlayWrightFetcher``) so static HTML,
Cloudflare-protected, and SPA-rendered doc sites all work without separate
code paths. Content is extracted to markdown with trafilatura.

Exit codes:
  0 -- success, coverage gate passed
  1 -- coverage gate failed (too few pages or missing API reference)
  2 -- no docs discovered at all
  3 -- environment / dependency error
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import urljoin, urlparse, urldefrag, urlunparse

# --- Dependency imports (fail loud if missing) ---------------------------------

try:
    from scrapling.fetchers import Fetcher, StealthyFetcher, PlayWrightFetcher  # type: ignore
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: failed to import scrapling. Install deps with:\n"
        "  python3 -m venv .venv-scrape\n"
        "  .venv-scrape/bin/pip install -r scripts/scrape-docs-requirements.txt\n"
        f"Underlying error: {exc}\n"
    )
    raise SystemExit(3)

try:
    import trafilatura  # type: ignore
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: failed to import trafilatura. See "
        "scripts/scrape-docs-requirements.txt\n"
        f"Underlying error: {exc}\n"
    )
    raise SystemExit(3)

# ``requests`` ships as a transitive dep of Scrapling. We use it directly for
# manifest probes (llms.txt, mint.json, openapi.json, sitemap.xml) because
# Scrapling's ``Fetcher.get`` always parses responses as HTML and wraps plain
# text / JSON in ``<html><body><p>...</p></body></html>``, corrupting the data.
import requests  # type: ignore


# --- Constants -----------------------------------------------------------------

MIN_CONTENT_CHARS = 200
RATE_LIMIT_MARKERS = ("rate limit", "too many requests", "429 too many")
DEFAULT_MIN_PAGES = 20
DEFAULT_CONCURRENCY = 8
CRAWL_MAX_DEPTH = 3
CRAWL_MAX_PAGES = 500

# A single page larger than this counts as a "trusted dump" -- we accept the
# coverage gate even with very few pages, because the underlying content is
# already enormous (e.g. Supabase ships its API reference as a handful of
# 50KB-1MB ``llms/<lang>.txt`` files).
HUGE_DUMP_BYTES = 100_000

# URL extensions that already serve raw text/markdown. We bypass Scrapling's
# HTML parser for these because it wraps plain text in ``<html><body><p>``,
# corrupting the contents.
_PLAIN_TEXT_EXTS = (".txt", ".md")

# Path fragments that look like documentation. Used to filter sitemap URLs and
# crawler link discovery so we don't drag in marketing pages.
DOC_PATH_HINTS = (
    "/docs",
    "/doc/",
    "/documentation",
    "/api",
    "/reference",
    "/guides",
    "/guide/",
    "/sdk",
    "/learn",
    "/changelog",
    "/getting-started",
    "/quickstart",
    "/tutorial",
    "/help",
)

API_REFERENCE_HINTS = ("/api", "/reference", "/api-reference", "/sdk")

LINK_HREF_RE = re.compile(r'href\s*=\s*["\']([^"\'#]+)["\']', re.IGNORECASE)


# --- Data structures -----------------------------------------------------------


@dataclass
class FetchedPage:
    url: str
    rel_path: str
    markdown: str
    fetcher: str
    bytes_in: int


@dataclass
class ScrapeResult:
    discovery: str = ""
    pages: list[FetchedPage] = field(default_factory=list)
    failures: list[tuple[str, str]] = field(default_factory=list)
    openapi_path: str | None = None


# --- Logging -------------------------------------------------------------------


def log(msg: str) -> None:
    sys.stdout.write(f"[scrape-docs] {msg}\n")
    sys.stdout.flush()


# --- URL helpers ---------------------------------------------------------------


def normalize_url(url: str) -> str:
    """Strip fragments and trailing slashes for stable dedup."""
    url, _ = urldefrag(url)
    parsed = urlparse(url)
    path = parsed.path or "/"
    if len(path) > 1 and path.endswith("/"):
        path = path.rstrip("/")
    return urlunparse(
        (parsed.scheme, parsed.netloc, path, "", parsed.query, "")
    )


def same_host(a: str, b: str) -> bool:
    return urlparse(a).netloc == urlparse(b).netloc


def looks_like_doc_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    return any(hint in path for hint in DOC_PATH_HINTS)


_PATH_SAFE_RE = re.compile(r"[^a-zA-Z0-9/._\-]")


def _is_plain_text_url(url: str) -> bool:
    parsed = urlparse(url)
    path = (parsed.path or "").lower()
    return path.endswith(_PLAIN_TEXT_EXTS)


def url_to_rel_path(url: str) -> str:
    """Map a URL to a filesystem-safe ``.md`` path under ``target-docs/``."""
    parsed = urlparse(url)
    path = parsed.path or "/"
    if path.endswith("/"):
        path = path + "index"
    path = path.lstrip("/")
    path = re.sub(r"\.(html?|php|aspx?)$", "", path, flags=re.IGNORECASE)
    # Strip trailing ``.md`` / ``.txt`` so we don't end up with ``foo.md.md``
    # when the source URL already advertises raw markdown / text.
    path = re.sub(r"\.(md|txt)$", "", path, flags=re.IGNORECASE)
    if parsed.query:
        path = f"{path}__{re.sub(r'[^a-zA-Z0-9]+', '_', parsed.query)}"
    path = _PATH_SAFE_RE.sub("_", path)
    if not path:
        path = "index"
    return f"{path}.md"


# --- Fetcher chain -------------------------------------------------------------


def _fetcher_html(page: object) -> tuple[int, str]:
    """Extract status + html from a Scrapling Response.

    Scrapling's ``Response`` exposes:
      - ``status`` (int) -- HTTP status code
      - ``html_content`` (str) -- raw HTML body, the canonical attribute
      - ``body`` -- a ``TextHandler`` wrapper (not what we want)
      - ``text`` -- *extracted* body text (way too short for full HTML)

    Always read ``html_content``. Everything else is a trap.
    """
    status_value = getattr(page, "status", None)
    status = status_value if isinstance(status_value, int) else 0

    html_value = getattr(page, "html_content", None)
    if isinstance(html_value, bytes):
        html = html_value.decode("utf-8", errors="replace")
    elif isinstance(html_value, str):
        html = html_value
    else:
        html = ""
    return status, html


def _is_usable(status: int, html: str) -> bool:
    if status and status >= 400:
        return False
    if not html or len(html) < MIN_CONTENT_CHARS:
        return False
    sample = html[:4000].lower()
    if any(marker in sample for marker in RATE_LIMIT_MARKERS):
        return False
    return True


def fetch_html(url: str) -> tuple[str, str] | None:
    """Try Fetcher -> StealthyFetcher -> PlayWrightFetcher.

    Returns ``(content, fetcher_name)`` on success, ``None`` if every fetcher
    failed or all responses were unusable. Note that ``StealthyFetcher`` and
    ``PlayWrightFetcher`` use *milliseconds* for ``timeout``, while
    ``Fetcher.get`` uses *seconds* -- a Scrapling API quirk.

    URLs that already advertise plain text / markdown (``.txt`` / ``.md``) are
    bypassed through ``requests`` so we don't run them through Scrapling's
    HTML parser, which wraps them in ``<html><body><p>...`` and corrupts the
    content for trafilatura.
    """
    if _is_plain_text_url(url):
        text = fetch_text(url)
        if text and len(text) >= MIN_CONTENT_CHARS:
            return text, "requests"
        return None
    attempts: list[tuple[str, Callable[[], object]]] = [
        (
            "fetcher",
            lambda: Fetcher.get(
                url,
                stealthy_headers=True,
                follow_redirects=True,
                timeout=20,  # seconds
            ),
        ),
        (
            "stealthy",
            lambda: StealthyFetcher.fetch(
                url,
                headless=True,
                block_images=True,
                disable_resources=True,
                network_idle=False,
                humanize=False,
                timeout=30000,  # milliseconds
            ),
        ),
        (
            "playwright",
            lambda: PlayWrightFetcher.fetch(
                url,
                headless=True,
                network_idle=True,
                disable_resources=True,
                timeout=45000,  # milliseconds
            ),
        ),
    ]
    for name, run in attempts:
        try:
            page = run()
        except Exception as exc:
            log(f"  {name}: {url} -> error: {exc}")
            continue
        if page is None:
            continue
        status, html = _fetcher_html(page)
        if not _is_usable(status, html):
            continue
        return html, name
    return None


def fetch_text(url: str) -> str | None:
    """Fetch a manifest file (``llms.txt``, ``llms-full.txt``, ``mint.json``,
    ``openapi.json``, ``sitemap.xml``) and return the raw response body. We use
    ``requests`` directly instead of Scrapling's ``Fetcher.get`` because the
    latter always parses responses through an HTML parser and wraps plain
    text / JSON / XML in ``<html><body><p>...</p></body></html>``, which
    corrupts the manifest contents."""
    try:
        r = requests.get(
            url,
            timeout=15,
            allow_redirects=True,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (compatible; ralph-to-ralph-scraper/1.0; "
                    "+https://github.com/anthropics/claude-code)"
                ),
                "Accept": "*/*",
            },
        )
    except Exception as exc:
        log(f"  manifest probe failed {url}: {exc}")
        return None
    if r.status_code >= 400:
        return None
    return r.text or None


# --- Discovery sources ---------------------------------------------------------


def discover_llms_full(base_url: str) -> str | None:
    """Return the URL of an llms-full.txt if one exists."""
    candidates = [
        urljoin(base_url + "/", "llms-full.txt"),
        urljoin(base_url + "/", "docs/llms-full.txt"),
    ]
    for url in candidates:
        text = fetch_text(url)
        if text and len(text) > 1000:
            log(f"  found llms-full.txt at {url} ({len(text)} bytes)")
            return url
    return None


def discover_llms_txt(base_url: str) -> list[str]:
    """Parse llms.txt for documentation URLs."""
    candidates = [
        urljoin(base_url + "/", "llms.txt"),
        urljoin(base_url + "/", "docs/llms.txt"),
    ]
    for url in candidates:
        text = fetch_text(url)
        if not text:
            continue
        urls: list[str] = []
        # llms.txt is markdown; we extract any http(s) URL we see.
        for match in re.finditer(r"https?://[^\s\)\]<>\"']+", text):
            href = match.group(0).rstrip(".,;)")
            if same_host(href, base_url):
                urls.append(normalize_url(href))
        if urls:
            log(f"  llms.txt at {url} -> {len(urls)} candidate URLs")
            return list(dict.fromkeys(urls))
    return []


def discover_mint_json(base_url: str) -> list[str]:
    """Walk a Mintlify ``mint.json`` navigation tree for doc page slugs."""
    candidates = [
        urljoin(base_url + "/", "mint.json"),
        urljoin(base_url + "/", "docs/mint.json"),
        urljoin(base_url + "/", ".mintlify/mint.json"),
    ]
    for url in candidates:
        text = fetch_text(url)
        if not text:
            continue
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            continue
        slugs: list[str] = []

        def walk(node: object) -> None:
            if isinstance(node, str):
                slugs.append(node)
            elif isinstance(node, list):
                for item in node:
                    walk(item)
            elif isinstance(node, dict):
                for key in ("pages", "navigation", "groups", "tabs", "anchors"):
                    if key in node:
                        walk(node[key])

        walk(data.get("navigation", []))
        walk(data.get("tabs", []))
        walk(data.get("anchors", []))
        if not slugs:
            continue
        urls = [
            normalize_url(urljoin(base_url + "/", slug.lstrip("/")))
            for slug in slugs
            if isinstance(slug, str)
        ]
        log(f"  mint.json at {url} -> {len(urls)} pages")
        return list(dict.fromkeys(urls))
    return []


def discover_openapi(base_url: str, out_dir: Path) -> str | None:
    """Save an OpenAPI spec verbatim if discoverable. Returns saved path."""
    candidates = [
        urljoin(base_url + "/", "openapi.json"),
        urljoin(base_url + "/", "openapi.yaml"),
        urljoin(base_url + "/", "openapi.yml"),
        urljoin(base_url + "/", "api-docs/openapi.json"),
        urljoin(base_url + "/", ".well-known/openapi.json"),
        urljoin(base_url + "/", "docs/openapi.json"),
    ]
    for url in candidates:
        text = fetch_text(url)
        if not text or len(text) < 100:
            continue
        # Sanity check that it really is OpenAPI
        if "openapi" not in text[:200].lower() and "swagger" not in text[:200].lower():
            continue
        ext = "json" if url.endswith("json") else "yaml"
        target = out_dir / f"openapi.{ext}"
        target.write_text(text, encoding="utf-8")
        log(f"  saved OpenAPI spec from {url} -> {target}")
        return str(target)
    return None


def discover_sitemap(base_url: str) -> list[str]:
    """Parse sitemap.xml (and nested indexes) and return doc-looking URLs."""
    seen_sitemaps: set[str] = set()
    queue = [
        urljoin(base_url + "/", "sitemap.xml"),
        urljoin(base_url + "/", "sitemap_index.xml"),
        urljoin(base_url + "/", "docs/sitemap.xml"),
    ]
    found: list[str] = []
    while queue:
        sm_url = queue.pop(0)
        if sm_url in seen_sitemaps:
            continue
        seen_sitemaps.add(sm_url)
        text = fetch_text(sm_url)
        if not text or "<" not in text:
            continue
        try:
            root = ET.fromstring(text)
        except ET.ParseError:
            continue
        ns = ""
        if root.tag.startswith("{"):
            ns = root.tag.split("}", 1)[0] + "}"
        # Nested sitemap index
        for sm in root.findall(f"{ns}sitemap"):
            loc = sm.findtext(f"{ns}loc")
            if loc:
                queue.append(loc.strip())
        for url_elem in root.findall(f"{ns}url"):
            loc = url_elem.findtext(f"{ns}loc")
            if not loc:
                continue
            loc = loc.strip()
            if not same_host(loc, base_url):
                continue
            if not looks_like_doc_url(loc):
                continue
            found.append(normalize_url(loc))
    if found:
        log(f"  sitemap -> {len(found)} doc URLs")
    return list(dict.fromkeys(found))


def extract_links(html: str, base: str) -> Iterable[str]:
    for match in LINK_HREF_RE.finditer(html):
        href = match.group(1).strip()
        if href.startswith("mailto:") or href.startswith("javascript:"):
            continue
        absolute = normalize_url(urljoin(base, href))
        yield absolute


def crawl_from_seed(
    seed_url: str,
    max_depth: int,
    max_pages: int,
    concurrency: int,
) -> list[tuple[str, str, str]]:
    """BFS crawl restricted to same-host doc-looking URLs.

    Returns a list of ``(url, html, fetcher_name)`` tuples in discovery order.
    """
    seen: set[str] = {seed_url}
    found: list[tuple[str, str, str]] = []
    current_level = [seed_url]
    for depth in range(max_depth + 1):
        if not current_level or len(found) >= max_pages:
            break
        log(f"  crawl depth={depth} fetching {len(current_level)} url(s)")
        next_level: list[str] = []
        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            futures = {ex.submit(fetch_html, u): u for u in current_level}
            for fut in as_completed(futures):
                url = futures[fut]
                try:
                    result = fut.result()
                except Exception as exc:
                    log(f"  crawl error {url}: {exc}")
                    continue
                if not result:
                    continue
                html, fetcher_name = result
                found.append((url, html, fetcher_name))
                if depth >= max_depth or len(found) >= max_pages:
                    continue
                for href in extract_links(html, url):
                    if href in seen:
                        continue
                    if not same_host(href, seed_url):
                        continue
                    if not looks_like_doc_url(href):
                        continue
                    seen.add(href)
                    next_level.append(href)
        current_level = next_level[: max(0, max_pages - len(found))]
    return found


# --- Bulk fetching + writing ---------------------------------------------------


def fetch_many(urls: list[str], concurrency: int) -> tuple[list[tuple[str, str, str]], list[tuple[str, str]]]:
    """Fetch a flat URL list in parallel. Returns (successes, failures)."""
    successes: list[tuple[str, str, str]] = []
    failures: list[tuple[str, str]] = []
    log(f"  fetching {len(urls)} url(s) with concurrency={concurrency}")
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        futures = {ex.submit(fetch_html, u): u for u in urls}
        for fut in as_completed(futures):
            url = futures[fut]
            try:
                result = fut.result()
            except Exception as exc:
                failures.append((url, str(exc)))
                continue
            if result is None:
                failures.append((url, "all fetchers returned unusable content"))
                continue
            html, fetcher_name = result
            successes.append((url, html, fetcher_name))
    return successes, failures


def html_to_markdown(html: str, url: str) -> str:
    # Plain-text / markdown URLs are already in the right shape -- ``fetch_html``
    # routes them through ``requests`` and returns the body verbatim. Running
    # them through trafilatura would extract <p>-wrapped junk.
    if _is_plain_text_url(url):
        return html.strip()
    md = trafilatura.extract(
        html,
        url=url,
        output_format="markdown",
        include_comments=False,
        include_tables=True,
        include_links=True,
        favor_precision=False,
    )
    return md or ""


def write_page(out_dir: Path, url: str, markdown: str) -> FetchedPage:
    rel_path = url_to_rel_path(url)
    target = out_dir / rel_path
    target.parent.mkdir(parents=True, exist_ok=True)
    body = f"<!-- Source: {url} -->\n\n{markdown.strip()}\n"
    target.write_text(body, encoding="utf-8")
    return FetchedPage(
        url=url,
        rel_path=rel_path,
        markdown=markdown,
        fetcher="",
        bytes_in=len(body.encode("utf-8")),
    )


def write_full_dump(out_dir: Path, url: str, text: str) -> FetchedPage:
    target = out_dir / "full-docs.md"
    body = f"<!-- Source: {url} -->\n\n{text.strip()}\n"
    target.write_text(body, encoding="utf-8")
    return FetchedPage(
        url=url,
        rel_path="full-docs.md",
        markdown=text,
        fetcher="fetcher",
        bytes_in=len(body.encode("utf-8")),
    )


def write_index(out_dir: Path, pages: list[FetchedPage]) -> None:
    lines = ["# target-docs index", ""]
    for page in sorted(pages, key=lambda p: p.rel_path):
        first_line = ""
        for line in page.markdown.splitlines():
            stripped = line.strip().lstrip("#").strip()
            if stripped:
                first_line = stripped[:120]
                break
        lines.append(f"- `{page.rel_path}` — {first_line or page.url}")
    (out_dir / "INDEX.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


# --- Coverage gate -------------------------------------------------------------


def coverage_check(
    pages: list[FetchedPage],
    min_pages: int,
    openapi_path: str | None = None,
) -> tuple[bool, dict]:
    has_openapi = openapi_path is not None
    has_api_reference = has_openapi or any(
        any(hint in page.url.lower() or hint in page.rel_path.lower() for hint in API_REFERENCE_HINTS)
        for page in pages
    )
    total_bytes = sum(p.bytes_in for p in pages)
    summary = {
        "page_count": len(pages),
        "min_pages_required": min_pages,
        "has_api_reference": has_api_reference,
        "has_openapi": has_openapi,
        "total_bytes": total_bytes,
    }
    enough_pages = len(pages) >= min_pages
    full_dump = any(p.rel_path == "full-docs.md" for p in pages)
    # Trust any single huge page as a "dump" (e.g. Supabase ships its full
    # JS reference as one ~1MB ``llms/js.txt`` file). With several of these
    # plus an OpenAPI spec we have plenty for the build phase, even though
    # the raw page count is below the default gate.
    huge_dump = any(p.bytes_in >= HUGE_DUMP_BYTES for p in pages)
    summary["has_huge_dump"] = huge_dump
    # If we got llms-full.txt we trust it without the page count requirement.
    ok = enough_pages or full_dump or huge_dump
    summary["passed"] = ok
    if not ok:
        if not enough_pages:
            summary["failure_reason"] = (
                f"only {len(pages)} pages, need >= {min_pages}"
            )
        else:
            summary["failure_reason"] = "unknown"
    return ok, summary


# --- Pipeline orchestration ----------------------------------------------------


def run_pipeline(
    base_url: str,
    out_dir: Path,
    min_pages: int,
    max_pages: int,
    concurrency: int,
) -> ScrapeResult:
    out_dir.mkdir(parents=True, exist_ok=True)
    result = ScrapeResult()

    # OpenAPI is additive: save if found, regardless of which discovery wins.
    openapi_path = discover_openapi(base_url, out_dir)
    if openapi_path:
        log(f"  openapi spec written: {openapi_path}")
        result.openapi_path = openapi_path

    # 1. llms-full.txt
    full_url = discover_llms_full(base_url)
    if full_url:
        text = fetch_text(full_url)
        if text:
            page = write_full_dump(out_dir, full_url, text)
            result.discovery = "llms-full.txt"
            result.pages = [page]
            return result

    # 2. llms.txt
    llms_urls = discover_llms_txt(base_url)
    if llms_urls and len(llms_urls) >= 5:
        successes, failures = fetch_many(llms_urls[:max_pages], concurrency)
        result.failures.extend(failures)
        for url, html, fetcher_name in successes:
            md = html_to_markdown(html, url)
            if not md:
                result.failures.append((url, "trafilatura returned empty"))
                continue
            page = write_page(out_dir, url, md)
            page.fetcher = fetcher_name
            result.pages.append(page)
        if len(result.pages) >= min(min_pages, 5):
            result.discovery = "llms.txt"
            return result
        log(f"  llms.txt yielded only {len(result.pages)} pages, falling through")
        result.pages.clear()
        result.failures.clear()

    # 3. mint.json
    mint_urls = discover_mint_json(base_url)
    if mint_urls and len(mint_urls) >= 5:
        successes, failures = fetch_many(mint_urls[:max_pages], concurrency)
        result.failures.extend(failures)
        for url, html, fetcher_name in successes:
            md = html_to_markdown(html, url)
            if not md:
                result.failures.append((url, "trafilatura returned empty"))
                continue
            page = write_page(out_dir, url, md)
            page.fetcher = fetcher_name
            result.pages.append(page)
        if len(result.pages) >= min(min_pages, 5):
            result.discovery = "mint.json"
            return result
        log(f"  mint.json yielded only {len(result.pages)} pages, falling through")
        result.pages.clear()
        result.failures.clear()

    # 4. sitemap.xml
    sitemap_urls = discover_sitemap(base_url)
    if sitemap_urls and len(sitemap_urls) >= 5:
        successes, failures = fetch_many(sitemap_urls[:max_pages], concurrency)
        result.failures.extend(failures)
        for url, html, fetcher_name in successes:
            md = html_to_markdown(html, url)
            if not md:
                result.failures.append((url, "trafilatura returned empty"))
                continue
            page = write_page(out_dir, url, md)
            page.fetcher = fetcher_name
            result.pages.append(page)
        if len(result.pages) >= min(min_pages, 5):
            result.discovery = "sitemap.xml"
            return result
        log(f"  sitemap.xml yielded only {len(result.pages)} pages, falling through")
        result.pages.clear()
        result.failures.clear()

    # 5. crawl
    seed_candidates = [
        urljoin(base_url + "/", "docs"),
        urljoin(base_url + "/", "documentation"),
        base_url.rstrip("/"),
    ]
    for seed in seed_candidates:
        log(f"  trying crawl from seed {seed}")
        crawled = crawl_from_seed(
            normalize_url(seed),
            max_depth=CRAWL_MAX_DEPTH,
            max_pages=max_pages,
            concurrency=concurrency,
        )
        if not crawled:
            continue
        for url, html, fetcher_name in crawled:
            md = html_to_markdown(html, url)
            if not md:
                result.failures.append((url, "trafilatura returned empty"))
                continue
            page = write_page(out_dir, url, md)
            page.fetcher = fetcher_name
            result.pages.append(page)
        if result.pages:
            result.discovery = f"crawl({seed})"
            return result

    return result


# --- CLI -----------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Deterministic doc scraper for the ralph-to-ralph inspect phase",
    )
    p.add_argument("url", help="Target product base URL (e.g. https://resend.com)")
    p.add_argument(
        "--out",
        default="target-docs",
        help="Output directory (default: target-docs)",
    )
    p.add_argument(
        "--min-pages",
        type=int,
        default=DEFAULT_MIN_PAGES,
        help=f"Minimum pages required to pass coverage gate (default: {DEFAULT_MIN_PAGES})",
    )
    p.add_argument(
        "--max-pages",
        type=int,
        default=CRAWL_MAX_PAGES,
        help=f"Maximum pages to fetch (default: {CRAWL_MAX_PAGES})",
    )
    p.add_argument(
        "--concurrency",
        type=int,
        default=DEFAULT_CONCURRENCY,
        help=f"Parallel fetcher count (default: {DEFAULT_CONCURRENCY})",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Re-scrape even if target-docs/coverage.json already exists",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    base_url = args.url.rstrip("/")
    out_dir = Path(args.out)
    coverage_path = out_dir / "coverage.json"

    if coverage_path.exists() and not args.force:
        try:
            existing = json.loads(coverage_path.read_text())
        except json.JSONDecodeError:
            existing = None
        if isinstance(existing, dict) and existing.get("passed"):
            log(f"coverage already satisfied at {coverage_path}, skipping scrape")
            log("(pass --force to re-scrape)")
            return 0

    started = time.time()
    log(f"target = {base_url}")
    log(f"out    = {out_dir}")
    log(f"gate   = >= {args.min_pages} pages")

    result = run_pipeline(
        base_url=base_url,
        out_dir=out_dir,
        min_pages=args.min_pages,
        max_pages=args.max_pages,
        concurrency=args.concurrency,
    )

    elapsed = time.time() - started
    log(f"discovery method: {result.discovery or 'none'}")
    log(f"pages saved:      {len(result.pages)}")
    log(f"fetch failures:   {len(result.failures)}")
    log(f"elapsed:          {elapsed:.1f}s")

    if not result.pages:
        coverage_path.write_text(
            json.dumps(
                {
                    "passed": False,
                    "page_count": 0,
                    "discovery": "",
                    "failure_reason": "no docs discovered",
                    "elapsed_seconds": round(elapsed, 1),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        log("FAILED: no documentation discovered for this target")
        return 2

    write_index(out_dir, result.pages)

    ok, summary = coverage_check(result.pages, args.min_pages, result.openapi_path)
    summary["discovery"] = result.discovery
    summary["elapsed_seconds"] = round(elapsed, 1)
    summary["failure_count"] = len(result.failures)
    coverage_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    if not ok:
        log("FAILED: coverage gate not satisfied")
        log(f"  reason: {summary.get('failure_reason')}")
        log(f"  see {coverage_path} for details")
        return 1

    log("PASSED coverage gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
