# RetroGate Implementation Plan

## Context

RetroGate is a macOS proxy that lets vintage Macs (1984–2005) browse the modern web. The project has a well-structured scaffold with 5 modules, but the core proxy flow is not yet wired — `ProxyHandler` returns a placeholder page instead of actually fetching and transcoding content. Two HTML transcoder methods are stubbed, and the SwiftUI UI is not connected to the actual server.

**Goal**: Complete the proxy so it actually works end-to-end — a vintage Mac sets its HTTP proxy to RetroGate, requests a page, and gets back transcoded HTML 3.2 with compatible images.

---

## Implementation Phases

### Phase 1: Configuration Plumbing
**Files**: `Sources/ProxyServer/ProxyServer.swift`, `Sources/ProxyServer/ProxyHandler.swift`

- Create `ProxyConfiguration` struct (Sendable): transcoding level, wayback enabled/date, maxImageWidth, imageQuality, onRequestLogged callback
- Pass configuration through `ProxyServer` → `ProxyHTTPHandler`
- Restructure `ProxyServer.start()` so it returns after binding (not blocking on closeFuture), store the bound channel, let `stop()` close it

### Phase 2: Core Fetch & Transcode (MVP)
**File**: `Sources/ProxyServer/ProxyHandler.swift`

Replace placeholder response with:
1. Build fetch URL (upgrade http→https, optionally rewrite through WaybackBridge)
2. Bridge NIO→async using `EventLoopPromise.completeWithTask`
3. Fetch via URLSession with 30s timeout
4. Route by Content-Type:
   - **HTML**: Optional wayback cleanup → HTMLTranscoder.transcode() → iso-8859-1 encode (lossy)
   - **Image**: ImageTranscoder.transcode() if needed → JPEG/GIF
   - **Other**: Pass through unchanged
5. Write HTTP/1.0 response back on event loop via `context.eventLoop.execute`
6. Extract `sendHTTPResponse` helper to reduce duplication

### Phase 3: `inlineStyles()` Implementation
**File**: `Sources/HTMLTranscoder/HTMLTranscoder.swift`

- Iterate elements with `style` attribute
- Map CSS properties → HTML 3.2 attributes:
  - `text-align` → `align`, `background-color` → `bgcolor`, `width/height` → attributes, `color` → `<font color>`, `font-weight: bold` → `<b>`, `font-size` → `<font size>`
- Add helpers: `parseInlineStyle()`, `normalizeColor()`, `mapFontSize()`
- Remove `style` attribute after conversion

### Phase 4: `convertToTableLayout()` Implementation
**File**: `Sources/HTMLTranscoder/HTMLTranscoder.swift`

Conservative, heuristic-based approach (CSS is already stripped):
- Convert nav-like `<ul>` (all items are `<li><a>`) → horizontal `<table><tr><td>` row
- Wrap body's direct sibling `<div>` children → single-column `<table>` with rows
- Keep it conservative — bad table conversion is worse than linearized content

### Phase 5: Wire SwiftUI to ProxyServer
**File**: `Sources/RetroGate/RetroGateApp.swift`

- Import ProxyServer, add `server` and `serverTask` properties to ProxyState
- Toggle on: build ProxyConfiguration from state, create server, launch in detached Task
- Toggle off: stop server, cancel task
- Replace hardcoded `localIP` with `getifaddrs`/`getnameinfo` (en0/en1 detection)

### Phase 6: Request Logging
**Files**: `Sources/ProxyServer/ProxyHandler.swift`, `Sources/RetroGate/RetroGateApp.swift`

- Fire `onRequestLogged` callback after each response with method, URL, status, sizes
- Callback dispatches to @MainActor to append to requestLog
- Add request log table view in the UI

### Phase 7: Tests
**Files**: `Tests/RetroGateTests/TranscoderTests.swift`, new `Tests/RetroGateTests/ProxyIntegrationTests.swift`

- `testInlineStyles` — verify CSS→attribute mapping
- `testConvertToTableLayout` — verify nav-list → table conversion
- `testISO8859Encoding` — verify lossy encoding handles Unicode
- Integration: start ProxyServer on random port, send proxy request, verify HTTP/1.0 response

---

## Key Technical Decisions

| Decision | Approach | Why |
|----------|----------|-----|
| NIO↔async bridging | `EventLoopPromise.completeWithTask` | Clean pattern, handles event loop dispatch |
| Server lifecycle | Store bound channel, don't block on closeFuture | Needed for SwiftUI toggle |
| iso-8859-1 encoding | `allowLossyConversion: true` | Vintage browsers need this charset |
| Table layout strategy | Conservative heuristics only | Over-conversion breaks pages worse |
| Config updates | Restart server on changes | Simpler than shared mutable state for v1 |

## Verification

1. `swift build` compiles without errors
2. `swift test` — all existing + new tests pass
3. Manual: run the app, toggle proxy on, configure vintage Mac (or `curl -x`) to use the proxy, load a real page, verify transcoded HTML 3.2 response
