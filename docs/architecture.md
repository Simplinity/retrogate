# RetroGate Architecture

## Overview

RetroGate is a local HTTP proxy that allows vintage Macintosh computers
to browse the modern web. It runs on a modern Mac (Apple Silicon) and
acts as a bridge between old HTTP/1.0 clients and today's HTTPS/H2 web.

When Wayback Machine mode is active, every successfully-fetched response
is also written to a persistent disk cache with a SQLite metadata index,
so subsequent visits skip archive.org entirely.

## Request Flow

```
Old Mac (Netscape 2)               RetroGate (M1/M5)                      Internet
─────────────────────             ──────────────────                     ─────────
GET http://apple.com ─────────▶   1. Receive HTTP/1.0 proxy request
                                  2. Check dead endpoint redirects
                                  3. [Wayback?] Rewrite URL (id_/im_/cs_/js_)
                                  4. [Wayback?] Cache lookup
                                     └─ hit  → serve from disk  (0 ms)
                                     └─ miss + offline → local 404
                                     └─ miss → fetch via URLSession ──▶ archive.org / live site
                                  5. Receive modern response          ◀── HTML5 + CSS3 + JS
                                  6. [Wayback + non-error + in-tolerance?]
                                     store bytes in ResponseCache
                                     and index HTML body into FTS5
                                  7. Route by Content-Type:
                                     - HTML → transcode to HTML 3.2
                                     - Image → transcode/dither
                                     - CSS/JS → URL upgrades
                                     - Other → passthrough
                                  8. Encode to iso-8859-1 or MacRoman
◀── simplified HTML 3.2 ────────  9. Send HTTP/1.0 response
```

Error pages returned by Wayback ("Page Not Archived") and drift-guard
rejections are **not** cached — the `set()` happens only after both checks
pass, so a retry doesn't resurrect a stale error.

## Modules

### ProxyServer (SwiftNIO)
- Binds to 0.0.0.0:8080 (configurable host/port)
- Accepts standard HTTP proxy requests (`GET http://... HTTP/1.0`)
- Responds with HTTP/1.0 (max compat with System 7-era TCP stacks)
- NIO-to-async bridging via `EventLoopPromise.completeWithTask`
- Thread-safe config via `SharedConfiguration` (NIOLock)
- HTTPS upgrade with cert-error fallback (untrusted, expired, unknown root)
- Dead endpoint redirects (e.g. old domains → archive.org)
- Transcoding bypass domains (passthrough for specified hosts)
- Virtual host at `http://retrogate/` serving start page, search gateway, and PAC file

### HTMLTranscoder (SwiftSoup)
Three levels:
- **Minimal**: Strip scripts, vendor-prefix CSS injection, fix encoding.
- **Moderate**: Remove CSS, downgrade semantic tags, keep layout.
- **Aggressive**: Full HTML 3.2 rewrite — table layouts, inline attrs, no CSS.

Key transformations:
- `<script>`, `<canvas>`, `<video>`, `<svg>` → removed
- `<nav>`, `<section>`, `<article>` → `<div>`
- Nav-like `<ul>` (all items are links) → horizontal `<table>` row
- Body's direct `<div>` children (3+) → single-column `<table>`
- `style=""` → `bgcolor`, `align`, `width`, `<font>` attributes
- `charset=utf-8` → `charset=iso-8859-1`
- JavaScript redirects (`window.location`) → `<meta http-equiv="refresh">`
- `<noscript>` unwrapping (modern lazy-loading fallbacks)
- Optional HTML minification (comment removal, whitespace collapse)

### WaybackBridge
- Rewrites URLs: `http://X` → `https://web.archive.org/web/YYYYMMDD{modifier}/http://X`
- Content-type modifiers: `id_` (HTML), `im_` (images), `cs_` (CSS), `js_` (JS)
- Cleans Wayback toolbar injection (comment markers, CSS, meta refresh)
- Availability API to check if pages are archived
- CDX API for finding nearby snapshots
- Akamai CDN URL cleaning
- Wayback URL leak detection and recovery in responses

### ImageTranscoder (CoreGraphics/AppKit)
- WebP, AVIF, HEIF, SVG → JPEG (configurable quality)
- Resizes to max dimensions (default 640x480)
- Passthrough for already-compatible JPEG/GIF under size limits
- Format detection by magic bytes

Color depth modes:
- **Millions** (24-bit): full color, default
- **Thousands** (16-bit): 5 bits per channel
- **256 Colors**: standard GIF palette
- **16 Colors**: Bayer 4x4 ordered dithering, VGA palette
- **Monochrome**: 1-bit, Floyd-Steinberg dithering

### Response Cache Stack

Everything under `~/Library/Caches/RetroGate/` — the Wayback-response
cache with full management, retention, bundling, prefetching, and
full-text search.

```
~/Library/Caches/RetroGate/
├── blobs/<key>     ← SHA-256-prefix keyed bytes files
│                     (format: [4-byte ct-length][content-type][bytes])
└── index.sqlite    ← metadata sidecar + FTS5 index
```

#### ResponseCache
- Two-tier cache: 200-entry in-memory LRU in front of disk
- Keys are SHA-256(wayback URL), first 16 hex chars — ~collision-proof for local scale
- Storage versioning (`storageVersion` in `UserDefaults`) — bump to wipe on format break
- `updateLimits(maxSizeMB:maxAgeDays:)` pushes retention config + runs a sweep
- Automatic eviction sweep every 50 new inserts (no-op when both limits are 0)
- Stores metadata in `CacheIndex` and indexes HTML content into FTS5 on `set()`
- `remove(url:)`, `clear()`, `rebuildFTSIndex()` for UI-driven ops

#### CacheIndex (SQLite)
Schema tables:
- `entries` — URL, domain, wayback_date, content_type, size, first_cached_at, last_accessed_at, hit_count, pinned, note
- `tags` — (key, tag) pairs for future tagging UI
- `capsules` — id, name, created_at, description
- `capsule_members` — (capsule_id, key) with FK cascades
- `entries_fts` — FTS5 virtual table, porter + unicode61 tokenizer, `snippet()` for highlights

Key characteristics:
- WAL journal mode, FULLMUTEX open flag, `PRAGMA foreign_keys=ON`
- Upsert preserves `hit_count`, `pinned`, `note`, `first_cached_at` on re-fetch
- `recordHit(key:)` is atomic — verified under 500-thread concurrent test
- `deleteMany(keys:)` does FTS-delete + entries-delete in a single transaction
- `searchFTS(query:)` returns `FTSHit(key, snippet, rank)` sorted by relevance
- Capsule CRUD + membership, `exportCapsule` / `importBundle` coordinated by `CapsuleBundler`

#### CacheEvictionPolicy
Pure, synchronous decision struct — no SQLite, no I/O, easy to test.

Given `[Candidate(key, sizeBytes, lastAccessedAt, pinned)]` plus `maxSizeBytes`
and `maxAgeMs`, returns the set of keys to delete:

1. **Age pass**: delete entries with `lastAccessedAt < now - maxAgeMs`
2. **Size pass**: if remaining total > cap, evict least-recently-accessed
   non-pinned entries until under cap

Pinned entries are never candidates. Either limit = 0 means "no limit" for
that axis. Both = 0 means the policy is a no-op (default).

#### CacheWarmer (Swift actor)
Rate-limited bulk prefetch:
- Takes `[URL]` + target wayback date + rate-limit seconds
- For each URL: compute wayback URL via `WaybackBridge`, check cache, fetch if miss
- Cache hits skip the rate-limit throttle (already-cached == no network)
- Reports structured `Progress(total, completed, cached, succeeded, failed, current, succeededKeys)`
- `cancel()` sets a flag checked between items — no mid-fetch interruption
- Static parser `parseURLList(_)` accepts one-URL-per-line with `#` comments and bare hostnames

#### CapsuleBundler
Export/import `.retrogate-capsule` directory bundles:

```
<name>.retrogate-capsule/
├── manifest.json    ← format version, capsule info, entry list (one EntryInfo per blob)
└── blobs/<key>      ← copied from ResponseCache's blobs dir
```

- Directory format chosen over zip: no zip dependency, sandbox-safe, Finder-inspectable
- Forward-compat via `formatVersion` — unknown fields ignored, missing required fields throw
- Import preserves existing entry state (hit_count, pin, note) via `index.upsert()` merge semantics
- Tolerates missing blobs during export (logs warning, writes manifest anyway)

#### HTMLPlainifier
Produces the plain-text string fed into FTS5:
- Decodes bytes as iso-8859-1 → utf-8 → macOSRoman (first that works)
- Parses with SwiftSoup, removes `<script>`, `<style>`, `<noscript>`, `<template>`
- Extracts `.text()` and collapses runs of whitespace to single spaces
- Clips output at 256 KB of characters (~50k English words)

## GUI (SwiftUI)

- **Dashboard**: on/off toggle, IP:port display, stats, top domains, content breakdown
- **Request Log**: live table of proxied requests (method, URL, status, sizes)
- **Cache**: cache management — hero stats, retention controls, capsules, filters,
  content search, table with sortable columns, bulk actions. See next section.
- **Wayback Timeline**: snapshot date visualization vs target date
- **Wayback Machine**: toggle, date picker, tolerance slider
- **Vintage Computer**: platform presets with matching screen resolution, color depth, encoding

### Cache Tab Layout (top → bottom)

1. **Offline banner** — toggle + status; gold when active. Bound to `cacheOfflineMode`.
   Also drives the gold dot next to "Cache" in the sidebar.
2. **Hero stats** — 4 tiles: Entries, On Disk, Hits (lifetime), Oldest entry age.
3. **Retention bar** — MB cap, age cap, Sweep-now button. Bindings call
   `ProxyState.applyCacheLimits()` which persists to disk and calls
   `ResponseCache.updateLimits(maxSizeMB:maxAgeDays:)`.
4. **Capsules bar** — horizontal scrollable chip row + New-from-selection / Import… /
   Prefetch… buttons. Right-click a chip for Rename / Export / Delete.
5. **Filters bar** — URL substring, domain dropdown (from cache), content-type dropdown,
   pinned-only toggle. All filters stack; Clear-filters link appears when active.
6. **Content search bar** — FTS5 query field with live match count, index coverage
   indicator, and Build-Index button (backfill via `ResponseCache.rebuildFTSIndex`).
7. **Toolbar** — Refresh, Pin/Unpin/Delete for selection, Clear All (with confirm).
8. **Table** — columns: pin, URL (with inline snippet when FTS active), domain,
   snapshot date, type, size, hits, cached (relative time). All sortable except when
   FTS is active, in which case rank-ordering wins.

### Sheets
- **Create/Rename Capsule** — form with name + optional description.
- **Prefetch** — three phases: `idle` (textarea + rate spinner), `running`
  (progress bar, live counters, cancel), `finished` (summary + optional capsule-name
  field to wrap the successful fetches into a new capsule).

## Configuration

`ProxyConfiguration` (Sendable struct, stored in a `SharedConfiguration` box with NIOLock):

- `browsingMode` (liveWeb | wayback(date, toleranceMonths))
- `transcodingLevel`, `maxImageWidth`, `imageQuality`, `outputEncoding`, `colorDepth`
- `transcodingBypassDomains`, `minifyHTML`, `deadEndpointRedirects`
- `cacheOfflineMode` — when true, cache misses in wayback mode return a local 404
  and `prefetchWaybackImages` is skipped

Persistence in `~/Library/Application Support/RetroGate/config.json` adds:
- `cacheMaxSizeMB` (0 = unlimited)
- `cacheMaxAgeDays` (0 = never auto-delete)
- `cacheOfflineMode`

Storage-format key `retrogate.cache.format.version` in `UserDefaults` — mismatch
wipes the whole cache dir before opening the new index.

## Future / Stretch Goals
- FTP gateway (serve downloads to Fetch/Anarchie)
- Bonjour/mDNS broadcast for easy proxy discovery
- MacBinary encoding for file downloads
- Gopher protocol support
- User-facing tag editor (schema already present, UI not exposed)
- Per-entry note editor (schema present)
- Search-result deep-linking that re-opens a page via the proxy at its exact snapshot date
