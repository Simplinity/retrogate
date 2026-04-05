# RetroGate - Development Guide

## Project Overview
RetroGate is a macOS proxy server that lets vintage Macs (Mac OS 9 in SheepShaver) browse the modern web. It intercepts HTTP requests, fetches pages via modern TLS, transcodes HTML5 to HTML 3.2, converts images, and integrates with the Wayback Machine for time-travel browsing.

## Build & Run
```bash
swift build                        # Debug build via SPM
swift test                         # Run all 50 tests
.build/debug/RetroGate             # Launch (proxy on 0.0.0.0:8080)
# Configure vintage Mac's HTTP proxy to <host-ip>:8080
# SheepShaver: host is reachable at 10.0.2.2 from the VM
```

### App Store / Xcode Build
Open `Package.swift` in Xcode, import `RetroGate.xcconfig` for build settings (Hardened Runtime, code signing, bundle ID). Assets and entitlements are in `Sources/RetroGate/`:
- `Info.plist` — bundle metadata, ATS exception, local network usage description
- `RetroGate.entitlements` — sandbox + network.server + network.client
- `PrivacyInfo.xcprivacy` — privacy manifest (FileTimestamp, UserDefaults APIs)
- `Assets.xcassets/AppIcon.appiconset/` — app icon (all sizes)

## Architecture

### Module Overview
- **RetroGateApp** (SwiftUI) — Dashboard, settings, vintage presets (with era metadata), config persistence
- **ProxyServer** (SwiftNIO) — HTTP/1.0 proxy server, shared config via `SharedConfiguration`
- **ProxyHandler** — Request routing, dual-pipeline fetch (live web vs Wayback), virtual host interception, error reporting to UI
- **RedirectTracker** — Detects HTTP↔HTTPS redirect loops (3 visits in 10s window)
- **ResponseCache** — Disk+memory cache for immutable Wayback responses (`~/Library/Caches/RetroGate/`)
- **TemporalCache** — Per-domain resolved Wayback date cache (5-min TTL) for temporal consistency
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
- `supportedColorDepths` + `defaultColorDepth` — per-preset color depth options (System 7+ supports Millions)
- Note: System 6 (1988) and Windows 3.1 (1992) predate the web but can run early browsers (MacWWW, Mosaic). Their `eraRange` starts at 1993.

### Platform Memory
When switching between Mac and PC, the app remembers the last-used preset, resolution, and color depth per platform via `ProxyState.platformMemory`. The `isRestoringPlatform` flag prevents `onChange(of: presetId)` from overriding restored values during platform switches.

### UI Architecture
- **Onboarding**: First-run sheet with setup guide, persisted via `hasCompletedOnboarding` in config
- **Dashboard**: Status bar (green/red dot, IP:port, preset, mode) + full-height request list
- **Error reporting**: `RequestLogData.errorMessage` flows from ProxyHandler → `onRequestLogged` callback → `ProxyState.recentErrors` → dashboard error banner
- **MenuBarExtra**: `.menuBarExtraStyle(.menu)` for native NSMenu dropdown with proxy controls
- **Settings**: 3-tab `TabView` (General, Advanced, About) via SwiftUI `Settings` scene
- **Keyboard shortcuts**: Cmd+Shift+S (start/stop), Cmd+Shift+W (Wayback toggle), Cmd+K (clear log)

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
`~/Library/Application Support/RetroGate/config.json` — Codable JSON with backward-compatible decoder (`init(from:)` uses `decodeIfPresent` for all fields). Fields:
- `port`, `waybackEnabled`, `waybackDateTimestamp`, `waybackToleranceMonths`
- `platform`, `presetId`, `screenWidth`, `screenHeight`, `colorDepth`
- `transcodingBypassDomains`, `minifyHTML`, `deadEndpointRedirects`
- `hasCompletedOnboarding`
- Note: deprecated `"millions"` colorDepth value is mapped to `"thousands"` on load

## SheepShaver Note
VM networking (slirp) drops after a while. Restart SheepShaver to fix.

## Testing
```bash
swift test    # 50 tests across 9 suites
```
Test suites: HTMLTranscoderTests (18), ImageTranscoderTests (7), WaybackBridgeTests (3), ProxyHandlerTests (2), RedirectTrackerTests (5), ResponseCacheTests (4), TemporalCacheTests (5), RequestLogDataTests (2), BrowsingModeTests (2), ColorDepthTests (2).

Not tested: end-to-end proxy networking, settings persistence round-trip, UI state.

## Gotchas
- **SwiftUI locale formatting**: `\(UInt16)` in `Text()` applies locale grouping (8080 → "8.080" in Belgian locale). Always use `String(value)` or `Text(verbatim:)` for port numbers.
- **Package.swift exclude**: The `exclude: [...]` array on the RetroGate target must list `Info.plist`, `RetroGate.entitlements`, `PrivacyInfo.xcprivacy`, `Assets.xcassets` — SPM tries to compile these otherwise.
- **toggleProxy() owns isRunning**: Callers must NOT toggle `isRunning` before calling `toggleProxy()` — the method handles the state transition internally.
- **Sandbox paths**: All file I/O uses `FileManager.default.urls(for: .applicationSupportDirectory/cachesDirectory)` which are sandbox-safe. No hardcoded paths.
- **ATS exception**: `NSAllowsArbitraryLoads = true` is required — the proxy fetches arbitrary HTTP sites. Include justification in App Store review notes.

---

## Feature Roadmap (future)
- [ ] DNS interception mode — no proxy config needed on vintage Mac
- [ ] Settings page accessible from vintage browser (bidirectional sync with SwiftUI app)
- [ ] FTP-to-HTTP bridge for vintage Mac FTP clients
- [ ] Protoweb integration — hand-restored vintage sites before Wayback fallback
- [ ] Server-side rendering with ISMAP as nuclear fallback
- [ ] Multi-protocol suite (IRC, NNTP, AIM revival)
- [ ] Site-specific gateways (Wikipedia, Reddit, search engines)
- [ ] Readability extraction mode (reader view fallback)
- [ ] Configurable rule engine (regex find/replace by URL/UA/Content-Type)
- [ ] Transliteration tables for non-Latin scripts
- [ ] Video transcoding pipeline (yt-dlp + ffmpeg → QuickTime)
