# RetroGate - Development Guide

## Project Overview
RetroGate is a macOS proxy server that lets vintage Macs (Mac OS 9 in SheepShaver) browse the modern web. It intercepts HTTP requests, fetches pages via modern TLS, transcodes HTML5 to HTML 3.2, converts images, and integrates with the Wayback Machine for time-travel browsing.

## Build & Run
```bash
swift build
.build/debug/RetroGate
# Proxy listens on 0.0.0.0:8080
# Configure vintage Mac's HTTP proxy to <host-ip>:8080
# SheepShaver: host is reachable at 10.0.2.2 from the VM
```

## Architecture

### Module Overview
- **RetroGateApp** (SwiftUI) — Dashboard, settings, vintage presets (with era metadata), config persistence
- **ProxyServer** (SwiftNIO) — HTTP/1.0 proxy server, shared config via `SharedConfiguration`
- **ProxyHandler** — Request routing, dual-pipeline fetch (live web vs Wayback), virtual host interception
- **HTMLTranscoder** (SwiftSoup) — HTML5 to HTML 3.2 downgrade (3 levels: minimal, moderate, aggressive)
- **WaybackBridge** — Wayback Machine URL rewriting, response cleaning (comment markers + CSS selectors), CDX API
- **ImageTranscoder** (CoreGraphics) — WebP/AVIF/PNG to JPEG/GIF conversion, format detection

### Browsing Mode Architecture
The proxy has two fully separated code paths controlled by `BrowsingMode` enum:

```
BrowsingMode.liveWeb    → fetchViaDirect()    → processContent()
BrowsingMode.wayback()  → fetchViaWayback()   → processContent()
```

- **`.liveWeb`** — Fetches from the live internet. HTTPS upgrade, cert fallback to HTTP, auto-Wayback-fallback for 404/403/410 pages. No Wayback-specific date handling.
- **`.wayback(targetDate:, toleranceMonths:)`** — Fetches from the Internet Archive. URL rewriting via `WaybackBridge`, response caching (archived content is immutable), temporal consistency for sub-resources, date drift guard, `?__wb=YYYYMMDD` per-request override.
- **`processContent()`** — Shared transcoding pipeline. HTML→3.2 downgrade, image conversion, encoding, cookie handling. Uses `isWaybackContent: Bool` (derived from `resolvedWaybackDate != nil`) for Wayback toolbar cleanup — content-aware, not mode-aware.

### Virtual Host System
Requests to `http://retrogate/...` are intercepted before any internet fetch:
- `/` — Start page with search, curated links, Wayback status
- `/search?q=...` — DuckDuckGo HTML gateway (parses `.result__a` + `.result__snippet`)
- `/proxy.pac` — PAC file for auto-proxy-configuration

### Vintage Presets
Each `VintagePreset` carries:
- Transcoding behavior: `htmlLevel`, `imageQuality`, `resolutions`
- Era metadata: `eraRange: ClosedRange<Int>` (e.g., Mac OS 9 → 1999...2002)
- `suggestedWaybackDate` — midpoint of the era, auto-suggested when enabling Wayback mode
- Note: System 6 (1988) and Windows 3.1 (1992) predate the web but can run early browsers (MacWWW, Mosaic). Their `eraRange` starts at 1993.

## Key Design Decisions
- HTTP/1.0 responses only (max vintage compatibility)
- `BrowsingMode` enum replaces flat `waybackEnabled`/`waybackDate`/`waybackToleranceMonths` — invalid states are unrepresentable
- Wayback cleanup is content-aware (`resolvedWaybackDate != nil`), not mode-aware — fixes bug where live-web auto-fallback didn't clean Wayback toolbar
- MacRoman encoding for Mac presets, iso-8859-1 for PC presets
- All `https://` URLs in text responses downgraded to `http://`
- Wayback URL cleaning covers ALL HTML attributes, not just specific selectors
- Wayback toolbar removal via HTML comment markers (`<!-- BEGIN WAYBACK TOOLBAR INSERT -->`) — more reliable than CSS selectors
- Java `<applet>` tags stripped (crashes SheepShaver MRJ), but `<embed>`/`<object>` preserved (QuickTime)
- Tracking redirect URLs resolved (`.click?URL` pattern + 15+ named redirect params)
- HTTPS cert errors fall back to plain HTTP
- Redirects blocked from leaving archive.org during Wayback fetches
- Akamai CDN URLs (`a772.g.akamai.net/...`) are intentionally preserved — Wayback archived CDN URLs, NOT origin URLs; rewriting breaks image loading
- `fetchWithRetry` uses `retryOn502: Bool` parameter (not mode-aware) — Wayback pipeline retries on 502/503, live pipeline doesn't but has cert fallback
- Ephemeral `URLSession` — no shared cookie jar, prevents cross-site cookie leaks

## Config File
`~/Library/Application Support/RetroGate/config.json` — JSON with port, waybackEnabled, waybackDateTimestamp, waybackToleranceMonths, platform, presetId, screenWidth, screenHeight, transcodingBypassDomains, minifyHTML.

## SheepShaver Note
VM networking (slirp) drops after a while. Restart SheepShaver to fix.

---

## Feature Roadmap (TODO)

### Quick Wins (high impact, easy)
- [x] 1. `<noscript>` content preservation — unwrap instead of delete
- [x] 2. CSP / SRI / CORS stripping — remove `integrity=`, `crossorigin=`, CSP meta tags
- [x] 3. Cookie `Secure` flag stripping — strip from Set-Cookie headers
- [x] 4. Archive.org rate limiting + retry with exponential backoff (3 retries, 0.5s/1s/2s)
- [x] 5. Broader redirect parameter extraction — 15+ redirect param names
- [x] 6. Accept header-based image format selection — inspect browser's Accept header, don't hardcode JPEG
- [x] 7. `@font-face` web font stripping from CSS responses
- [x] 8. JavaScript redirect detection — `window.location` → `<meta refresh>` conversion
- [x] 9. `<strong>` to `<b>`, `<em>` to `<i>` conversion
- [x] 10. Unicode smart character cleanup — curly quotes, em-dashes, ellipses, etc.

### Medium Features (good impact, moderate effort)
- [x] 11. Temporal consistency — track resolved Wayback date per page, load sub-resources from same date
- [x] 12. Automatic Wayback fallback for live-web 404s — if direct fetch returns 403/404/410, try Wayback Machine
- [x] 13. Redirect loop/carousel detection — track recent URLs, detect HTTP<->HTTPS loops, break them
- [ ] 15. Readability extraction mode — Mozilla Readability-style "reader view" as fallback for garbage transcoding
- [x] 16. SVG-to-raster conversion — convert SVG images to PNG/GIF for vintage browsers
- [x] 17. Built-in search gateway at `http://retrogate/search` — wrap DuckDuckGo in vintage HTML
- [x] 18. Response caching — cache Wayback responses locally (archived content never changes)
- [x] 19. MacRoman output encoding for Mac presets (not just iso-8859-1)
- [x] 20. `Host:` header injection for HTTP/1.0 browsers that don't send it
- [ ] 21. Floyd-Steinberg dithering for 1-bit GIF output (Mac Plus/SE/Classic)
- [ ] 22. Image dithering option for low-color displays

### Ambitious Features (differentiating, more work)
- [x] 25. PAC file generation — Proxy Auto-Configuration for vintage browsers
- [x] 27. Built-in start page / portal at `http://retrogate/` — curated links, search, weather
- [x] 32. Wayback toolbar removal via comment markers (more reliable than CSS selectors)
- [x] 33. Domain whitelist for transcoding bypass — retro-friendly sites skip transcoding
- [x] 36. Chunked Transfer-Encoding de-chunking for HTTP/1.0 clients
- [x] 37. HTML minification for bandwidth savings on slow connections

---

## V2 Roadmap (Future)
- [ ] 14. Site-specific gateway extensions — purpose-built handlers for Wikipedia, Reddit, search engines
- [ ] 23. Configurable rule engine — declarative regex find/replace rules by URL/UA/Content-Type
- [ ] 24. DNS interception mode — point vintage Mac's DNS at host, no proxy config needed
- [ ] 26. Settings page accessible from vintage browser — configure RetroGate from inside Mac OS 9
- [ ] 28. Dead service endpoint redirection — Windows Update, Netscape start pages, etc. to revivals
- [ ] 29. FTP-to-HTTP bridge — web-based FTP browser for vintage Mac FTP clients
- [ ] 30. Protoweb integration — check hand-restored vintage sites before falling back to Wayback
- [ ] 31. Video transcoding pipeline — yt-dlp + ffmpeg for QuickTime-compatible video
- [ ] 34. Browser-specific presets (MacWeb 2, Netscape 2, IE 3, etc.) keyed on User-Agent
- [ ] 35. CSS vendor prefix injection for medium-vintage browsers (Firefox 3.5-16, old Safari)
- [ ] 38. Transliteration tables for non-Latin scripts
- [ ] 39. Server-side rendering with ISMAP as nuclear fallback option
- [ ] 40. Multi-protocol suite (IRC, NNTP, AIM revival)
