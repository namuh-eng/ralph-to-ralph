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
import posixpath
import re
import sys
import time
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

# defusedxml protects against billion-laughs / quadratic-blowup entity expansion
# in sitemap.xml files from untrusted doc sites. The stdlib xml.etree parser
# expands internal entities by default and can be DoS'd with a crafted sitemap.
try:
    import defusedxml.ElementTree as ET  # type: ignore
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: failed to import defusedxml. See "
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
MIN_MARKDOWN_CHARS = 300
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

# Common doc subdomains. When the user provides ``https://stripe.com``, the
# actual developer docs may live at ``docs.stripe.com``. We probe these
# before running the main discovery ladder.
DOC_SUBDOMAIN_PREFIXES = ("docs", "developer", "developers")

# Locale-prefix regex: matches ``/nl/``, ``/en-es/``, ``/fr-lu/``, etc.
# Used to filter out localized marketing pages in the BFS crawl.
_LOCALE_PREFIX_RE = re.compile(r"^/[a-z]{2}(-[a-z]{2})?(/|$)", re.IGNORECASE)

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
    pa, pb = urlparse(a), urlparse(b)
    return pa.scheme == pb.scheme and pa.netloc == pb.netloc


def looks_like_doc_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    return any(hint in path for hint in DOC_PATH_HINTS)


_PATH_SAFE_RE = re.compile(r"[^a-zA-Z0-9/._\-]")


def _is_plain_text_url(url: str) -> bool:
    parsed = urlparse(url)
    path = (parsed.path or "").lower()
    return path.endswith(_PLAIN_TEXT_EXTS)


def _is_locale_prefixed(url: str) -> bool:
    """Return True if the URL path starts with a locale prefix like ``/nl/``
    or ``/en-es/`` and does NOT also contain ``/docs/``. This filters out
    localized marketing pages (``stripe.com/nl/guides``) that slip through
    ``DOC_PATH_HINTS`` while preserving genuine locale-prefixed doc URLs
    (``docs.example.com/ja/api``).
    """
    path = urlparse(url).path or ""
    if not _LOCALE_PREFIX_RE.match(path):
        return False
    # If the path also contains /docs/ it's likely a real doc page
    return "/docs/" not in path.lower() and "/docs" != path.lower().rstrip("/")


def url_to_rel_path(url: str) -> str:
    """Map a URL to a filesystem-safe ``.md`` path under ``target-docs/``.

    Defensive against path traversal: ``..`` segments in the URL path are
    dropped (not escaped), so a crafted ``Source:`` URL in an upstream
    ``llms-full.txt`` cannot write outside the output directory.
    """
    parsed = urlparse(url)
    path = parsed.path or "/"
    if path.endswith("/"):
        path = path + "index"
    # Collapse ``.`` / ``..`` segments, then drop any remaining ``..``
    # that posixpath.normpath leaves at the start (e.g. ``/../x`` -> ``/../x``
    # on absolute input, normalized to ``/x``, but relative-style ``../x``
    # would survive — strip those explicitly).
    path = posixpath.normpath(path)
    parts = [p for p in path.split("/") if p and p != ".." and p != "."]
    path = "/".join(parts)
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


def discover_doc_subdomain(base_url: str) -> str | None:
    """Probe common doc subdomains and return the best one if it has content.

    Many SaaS products host their developer docs on a subdomain
    (``docs.stripe.com``, ``developer.mozilla.org``). When the user provides
    the main domain (``https://stripe.com``), we'd miss the real docs entirely
    because ``same_host`` blocks cross-subdomain discovery.

    We probe each candidate for ``llms-full.txt``, ``llms.txt``, and
    ``sitemap.xml``. The first candidate that returns any of these becomes
    the effective base URL for the rest of the pipeline.
    """
    parsed = urlparse(base_url)
    domain = parsed.netloc
    # Skip if the URL already has a doc-subdomain prefix
    for prefix in DOC_SUBDOMAIN_PREFIXES:
        if domain.startswith(f"{prefix}."):
            return None
    for prefix in DOC_SUBDOMAIN_PREFIXES:
        candidate = f"{parsed.scheme}://{prefix}.{domain}"
        for probe_path in ("llms-full.txt", "llms.txt", "sitemap.xml"):
            probe_url = f"{candidate}/{probe_path}"
            try:
                r = requests.get(
                    probe_url,
                    timeout=8,
                    allow_redirects=True,
                    headers={
                        "User-Agent": (
                            "Mozilla/5.0 (compatible; ralph-to-ralph-scraper/1.0; "
                            "+https://github.com/anthropics/claude-code)"
                        ),
                    },
                )
            except Exception:
                break  # subdomain likely doesn't exist, skip remaining probes
            if r.status_code < 400 and len(r.text) > 500:
                log(
                    f"  doc subdomain discovered: {candidate} "
                    f"(via {probe_path}, {len(r.text)} bytes)"
                )
                return candidate
    return None


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
        # llms.txt is markdown. Extract URLs from both bare form
        # (``https://example.com/foo``) and angle-bracket form
        # (``<https://example.com/foo>``), which is the CommonMark
        # autolink syntax and is valid in llms.txt.
        seen_in_file: set[str] = set()
        for match in re.finditer(
            r"<(https?://[^>\s]+)>|(https?://[^\s\)\]<>\"']+)", text
        ):
            href = (match.group(1) or match.group(2)).rstrip(".,;)")
            if not href or href in seen_in_file:
                continue
            seen_in_file.add(href)
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
        # 10MB hard cap before parsing — defusedxml stops entity expansion,
        # but a legitimate sitemap that's tens of MB still wastes RAM and
        # almost certainly includes mostly non-doc URLs we'd filter anyway.
        if len(text) > 10_000_000:
            log(f"  sitemap {sm_url} too large ({len(text)} bytes), skipping")
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
                    if _is_locale_prefixed(href):
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


def write_page(
    out_dir: Path,
    url: str,
    markdown: str,
    fetcher: str = "",
) -> FetchedPage:
    rel_path = url_to_rel_path(url)
    # Defense-in-depth path confinement: even if ``url_to_rel_path`` is ever
    # relaxed or misused, refuse to write outside ``out_dir``. This guards
    # against crafted ``Source:`` URLs in untrusted ``llms-full.txt`` dumps.
    out_root = out_dir.resolve()
    target = (out_dir / rel_path).resolve()
    try:
        target.relative_to(out_root)
    except ValueError as exc:
        raise ValueError(
            f"refusing to write outside out_dir: url={url!r} target={target}"
        ) from exc
    target.parent.mkdir(parents=True, exist_ok=True)
    body = f"<!-- Source: {url} -->\n\n{markdown.strip()}\n"
    target.write_text(body, encoding="utf-8")
    return FetchedPage(
        url=url,
        rel_path=rel_path,
        markdown=markdown,
        fetcher=fetcher,
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


# llms-full.txt files follow the llms.txt spec: each section starts with a
# ``# Title`` heading followed immediately by a ``Source: <url>`` line. We
# parse on that boundary and split the monolithic dump into per-page files
# so the build loop can ``cat`` a single route instead of grepping a 1MB
# wall of text.
_LLMS_FULL_BOUNDARY = re.compile(
    r"^# (?P<title>[^\n]+)\nSource:\s*(?P<url>https?://\S+)\s*$",
    re.MULTILINE,
)


def split_llms_full_dump(text: str) -> list[tuple[str, str, str]]:
    """Split an llms-full.txt dump into per-page ``(url, title, body)`` tuples.

    Returns an empty list if the dump doesn't match the expected structure
    (fewer than 5 boundaries), so callers can fall back to writing the whole
    file unsplit.
    """
    matches = list(_LLMS_FULL_BOUNDARY.finditer(text))
    if len(matches) < 5:
        return []
    sections: list[tuple[str, str, str]] = []
    for i, m in enumerate(matches):
        title = m.group("title").strip()
        # ``\S+`` in the boundary regex greedily absorbs trailing sentence
        # punctuation; strip it so we don't produce filenames like
        # ``page_.md`` from a ``Source: https://x/page.`` line.
        url = m.group("url").strip().rstrip(".,;:")
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[start:end].strip()
        if not body:
            continue
        sections.append((url, title, body))
    return sections


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
    # ``has_api_reference`` is informational only — it surfaces in coverage.json
    # so the inspect prompts can decide whether to spend extra effort on the
    # API reference, but it does NOT gate ``passed``. Bumping it to a gate
    # would bias against products without a /api or /reference URL convention.
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
    # JS reference as one ~1MB ``llms/js.txt`` file). Restrict the bypass
    # to pages sourced from plain-text/markdown URLs so a single bloated
    # HTML marketing page can't trivially game the gate.
    huge_dump = any(
        p.bytes_in >= HUGE_DUMP_BYTES and _is_plain_text_url(p.url)
        for p in pages
    )
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


def _delete_orphan_files(out_dir: Path, pages: list[FetchedPage]) -> None:
    """Remove files written by a ladder stage that didn't meet the threshold.

    Without this cleanup, a falling-through stage leaves valid-looking ``.md``
    files in ``out_dir``. The next stage's ``write_page`` calls would land
    alongside them and the inspect agent would see both — confusing because
    the orphan files aren't in ``INDEX.md``.
    """
    for page in pages:
        path = (out_dir / page.rel_path).resolve()
        try:
            path.relative_to(out_dir.resolve())
        except ValueError:
            continue
        if path.exists() and path.is_file():
            try:
                path.unlink()
            except OSError as exc:
                log(f"  warn: could not remove orphan {path}: {exc}")


def _run_url_list_stage(
    name: str,
    urls: list[str],
    out_dir: Path,
    max_pages: int,
    concurrency: int,
    min_pages: int,
    result: ScrapeResult,
) -> bool:
    """Fetch a flat URL list, write pages, and decide whether to accept the
    stage. Returns ``True`` if the stage met the page threshold (caller should
    return). Returns ``False`` if the stage fell through; in that case the
    orphan files have already been cleaned and ``result.pages`` /
    ``result.failures`` are reset.
    """
    successes, failures = fetch_many(urls[:max_pages], concurrency)
    result.failures.extend(failures)
    stage_pages: list[FetchedPage] = []
    for url, html, fetcher_name in successes:
        md = html_to_markdown(html, url)
        if not md:
            result.failures.append((url, "trafilatura returned empty"))
            continue
        if len(md) < MIN_MARKDOWN_CHARS:
            result.failures.append((url, f"extracted markdown too short ({len(md)} chars)"))
            continue
        try:
            page = write_page(out_dir, url, md, fetcher=fetcher_name)
        except ValueError as exc:
            result.failures.append((url, f"write refused: {exc}"))
            continue
        stage_pages.append(page)
    result.pages.extend(stage_pages)
    if len(result.pages) >= min(min_pages, 5):
        result.discovery = name
        return True
    log(f"  {name} yielded only {len(result.pages)} pages, falling through")
    _delete_orphan_files(out_dir, stage_pages)
    result.pages.clear()
    result.failures.clear()
    return False


def run_pipeline(
    base_url: str,
    out_dir: Path,
    min_pages: int,
    max_pages: int,
    concurrency: int,
) -> ScrapeResult:
    out_dir.mkdir(parents=True, exist_ok=True)
    result = ScrapeResult()

    # Auto-discover doc subdomains: many SaaS products host docs on a separate
    # subdomain (docs.stripe.com, developer.mozilla.org). If the user gave the
    # main domain, check common doc subdomains first and switch if one has
    # content. This is the difference between 235 marketing pages and 473 real
    # API docs for Stripe.
    doc_sub = discover_doc_subdomain(base_url)
    if doc_sub:
        log(f"  switching base_url from {base_url} to {doc_sub}")
        base_url = doc_sub

    # OpenAPI is additive: save if found, regardless of which discovery wins.
    # Remove any stale spec from a previous failed run so a re-run with
    # ``--force`` doesn't end up with two openapi.* files on disk.
    for ext in ("json", "yaml", "yml"):
        stale = out_dir / f"openapi.{ext}"
        if stale.exists():
            stale.unlink()
    openapi_path = discover_openapi(base_url, out_dir)
    if openapi_path:
        log(f"  openapi spec written: {openapi_path}")
        result.openapi_path = openapi_path

    # 1. llms-full.txt
    full_url = discover_llms_full(base_url)
    if full_url:
        text = fetch_text(full_url)
        if text:
            # Always keep the monolithic dump around for broad cross-doc
            # grep, but also split it into per-page files so the build loop
            # can cat a single route. Fall back to the unsplit dump if the
            # file doesn't match the standard ``# Title\nSource: ...`` shape.
            write_full_dump(out_dir, full_url, text)
            sections = split_llms_full_dump(text)
            if sections:
                log(f"  split llms-full.txt into {len(sections)} per-page files")
                for url, title, body in sections:
                    md = f"# {title}\n\n{body}"
                    try:
                        page = write_page(out_dir, url, md, fetcher="requests")
                    except ValueError as exc:
                        result.failures.append((url, f"write refused: {exc}"))
                        continue
                    result.pages.append(page)
                result.discovery = "llms-full.txt (split)"
                return result
            # Unsplittable dump -- fall back to treating the whole file as
            # the only "page".
            result.pages = [
                FetchedPage(
                    url=full_url,
                    rel_path="full-docs.md",
                    markdown=text,
                    fetcher="requests",
                    bytes_in=len(text.encode("utf-8")),
                )
            ]
            result.discovery = "llms-full.txt"
            return result

    # 2. llms.txt
    llms_urls = discover_llms_txt(base_url)
    if llms_urls and len(llms_urls) >= 5:
        if _run_url_list_stage(
            "llms.txt", llms_urls, out_dir, max_pages, concurrency, min_pages, result
        ):
            return result

    # 3. mint.json
    mint_urls = discover_mint_json(base_url)
    if mint_urls and len(mint_urls) >= 5:
        if _run_url_list_stage(
            "mint.json", mint_urls, out_dir, max_pages, concurrency, min_pages, result
        ):
            return result

    # 4. sitemap.xml
    sitemap_urls = discover_sitemap(base_url)
    if sitemap_urls and len(sitemap_urls) >= 5:
        if _run_url_list_stage(
            "sitemap.xml", sitemap_urls, out_dir, max_pages, concurrency, min_pages, result
        ):
            return result

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
        seed_pages: list[FetchedPage] = []
        for url, html, fetcher_name in crawled:
            md = html_to_markdown(html, url)
            if not md:
                result.failures.append((url, "trafilatura returned empty"))
                continue
            if len(md) < MIN_MARKDOWN_CHARS:
                result.failures.append((url, f"extracted markdown too short ({len(md)} chars)"))
                continue
            try:
                page = write_page(out_dir, url, md, fetcher=fetcher_name)
            except ValueError as exc:
                result.failures.append((url, f"write refused: {exc}"))
                continue
            seed_pages.append(page)
        result.pages.extend(seed_pages)
        if result.pages:
            result.discovery = f"crawl({seed})"
            return result
        # Seed yielded crawled HTML but trafilatura extracted nothing usable —
        # clean the empty/orphan files before trying the next seed.
        _delete_orphan_files(out_dir, seed_pages)

    return result


# --- CLI -----------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Deterministic doc scraper for the ralph-to-ralph inspect phase",
    )
    p.add_argument("url", help="Target product base URL (e.g. https://resend.com)")
    p.add_argument(
        "--docs-url",
        default=None,
        help="Explicit docs URL (e.g. https://docs.stripe.com). Skips subdomain probing.",
    )
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
    # --docs-url overrides the positional URL for doc discovery. The positional
    # URL is still used as the "target" label in logs/coverage, but all fetching
    # uses the docs URL. This lets onboarding pin the docs location
    # (e.g. docs.stripe.com) independently of the product URL (stripe.com).
    base_url = (args.docs_url or args.url).rstrip("/")
    out_dir = Path(args.out)
    coverage_path = out_dir / "coverage.json"

    if coverage_path.exists() and not args.force:
        try:
            existing = json.loads(coverage_path.read_text())
        except json.JSONDecodeError:
            existing = None
        # Don't trust coverage.json alone — also verify INDEX.md is on disk.
        # Otherwise a user who deleted target-docs/*.md but left coverage.json
        # would silently start the inspect loop with an empty corpus.
        index_present = (out_dir / "INDEX.md").exists()
        if isinstance(existing, dict) and existing.get("passed") and index_present:
            log(f"coverage already satisfied at {coverage_path}, skipping scrape")
            log("(pass --force to re-scrape)")
            return 0
        if isinstance(existing, dict) and existing.get("passed") and not index_present:
            log(
                f"coverage.json says passed but {out_dir / 'INDEX.md'} is missing"
                " — re-scraping"
            )

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
