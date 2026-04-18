# Changelog

All notable changes to RetroGate are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and RetroGate adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — 2026-04-18

A full cache-management feature set and a few UX refinements.

### Added

- **Cache tab** under Monitor with hero stats (entries, on-disk size, hits,
  oldest entry), sortable columns, bulk actions (pin, unpin, delete, clear
  all), and live filter bar (URL search, domain, content-type, tag,
  pinned-only).
- **Retention policy** with optional max size (MB) and max age (days);
  pin-aware LRU eviction runs on startup, after limit changes, and every 50
  inserts.
- **Offline mode** toggle — cache-miss in Wayback mode returns a local 404
  instead of calling archive.org. Useful for demos, trains, and rate-limit
  avoidance. A gold dot next to "Cache" in the sidebar signals when it's on.
- **Detail drawer** for single-selected cache entries with metadata grid,
  editable tags (normalized: lowercase, trimmed, deduped), editable note,
  and inline Pin/Delete buttons.
- **Capsules** — named collections of cache entries you can create from a
  selection, rename, filter by, and export as a `.retrogate-capsule`
  directory bundle. Import merges a bundle back into your cache.
- **Prefetch** — paste a URL list (one per line, `#` for comments, bare
  hostnames allowed) and RetroGate warms the cache at a polite 1 req/sec.
  Progress is live; cancel is safe. Optionally wraps successful fetches
  into a new capsule on finish.
- **Full-text search** over cached HTML via SQLite FTS5 with Porter
  stemming. Supports phrases, `AND`/`OR`/`NEAR`, prefix wildcards. Matching
  rows show highlighted snippets inline. One-time Build Index button
  backfills content already in cache.
- **Dashboard "Time Saved"** stat card — aggregates lifetime cache hits and
  estimated round-trips avoided.
- **Sortable Request Log** and **Sortable Wayback Timeline** with hero
  stats (errors, bandwidth, avg size; delta-accuracy report card) and
  filter bars (URL, domain, status bucket, method, errors-only, delta
  category).
- **Sidebar Settings** — General and Advanced now live in the main window
  under "Configure" instead of a modal Settings window. ⌘, navigates to
  General.
- **Section-footer explanations** for Minify HTML, Transcoding Bypass
  Domains, and Dead Endpoint Redirects.

### Changed

- The default "About RetroGate" menu item now opens a dedicated window
  showing the same view as the in-app About page, so both paths look
  identical.
- About view restyled: hairline dividers replaced with generous vertical
  spacing between the three semantic blocks.
- Cache directory layout bumped to v2 (`blobs/` subdir + `index.sqlite`
  sidecar). The old hash-only blobs are wiped on first launch after
  upgrade; all pages re-cache transparently.
- `com.apple.security.files.user-selected.read-write` entitlement added
  for capsule export/import via save/open panels.
- `Package.resolved` is now tracked for reproducible dependency versions.

### Fixed

- Wayback "Page Not Archived" responses are no longer written to the cache —
  previously they were stored before the error check ran.
- Memory LRU is now a proper LRU (previously `removeAll()` at capacity).
- Cache keys use SHA-256 (first 16 hex chars) instead of DJB2, reducing
  collision risk at scale.

### Removed

- `RetroGate.xcconfig` — unused duplicate of `project.yml` values.
- Modal `Settings` window — replaced by sidebar items and ⌘,-navigation.

## [1.1.0] — 2026-04-12

### Added

- macOS 13 (Ventura) support — lowered deployment target from 14 to 13.
- Update checker — on launch, compares the running version against GitHub
  releases and offers a "Download" button when a newer version is out.

### Changed

- About view reads the version string from `CFBundleShortVersionString`
  instead of a hardcoded literal.

## [1.0.0] — 2026-04-05

Initial public release.

### Added

- SwiftNIO-based HTTP proxy for vintage browsers.
- HTML 5 → HTML 3.2 transcoder with three levels (Minimal, Moderate,
  Aggressive).
- Image transcoding (WebP/AVIF → JPEG/GIF) with palette reduction and
  Floyd-Steinberg / Bayer dithering for low-color displays.
- Wayback Machine integration with date picker, tolerance guard, and
  per-domain temporal consistency cache.
- Vintage preset library covering Mac System 6 through Mac OS X and
  Windows 3.1 through XP.
- Dashboard, Request Log, Wayback Timeline tabs.
- Built-in start page at `http://retrogate/` with DuckDuckGo search
  gateway and curated links.
- PAC file at `http://retrogate/proxy.pac` for one-click browser
  configuration.
- Menu bar extra with quick start/stop and stats.

[1.2.0]: https://github.com/Simplinity/retrogate/releases/tag/v1.2.0
[1.1.0]: https://github.com/Simplinity/retrogate/releases/tag/v1.1.0
[1.0.0]: https://github.com/Simplinity/retrogate/releases/tag/v1.0.0
