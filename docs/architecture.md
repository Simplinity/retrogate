# RetroGate Architecture

## Overview

RetroGate is a local HTTP proxy that allows vintage Macintosh computers
to browse the modern web. It runs on a modern Mac (Apple Silicon) and
acts as a bridge between old HTTP/1.0 clients and today's HTTPS/H2 web.

## Request Flow

```
Old Mac (Netscape 2)                RetroGate (M1/M5)                    Internet
─────────────────────              ──────────────────                   ─────────
GET http://apple.com ──────────▶  1. Receive HTTP/1.0 proxy request
                                  2. [Wayback?] Rewrite URL
                                  3. Fetch via URLSession (TLS 1.3) ──▶ https://apple.com
                                  4. Receive modern HTML5 response  ◀── HTML5 + CSS3 + JS
                                  5. Transcode HTML → HTML 3.2
                                  6. Convert images → JPEG/GIF
◀── simplified HTML 3.2 ─────────  7. Send HTTP/1.0 response
```

## Modules

### ProxyServer (SwiftNIO)
- Binds to 0.0.0.0:8080 (configurable)
- Accepts standard HTTP proxy requests (`GET http://... HTTP/1.0`)
- Handles CONNECT tunneling (for pass-through)
- Responds with HTTP/1.0 (max compat with System 7-era TCP stacks)

### HTMLTranscoder (SwiftSoup)
Three levels:
- **Minimal**: Strip scripts, fix encoding. Page structure untouched.
- **Moderate**: Remove CSS, downgrade semantic tags, keep layout.
- **Aggressive**: Full HTML 3.2 rewrite — table layouts, inline attrs, no CSS.

Key transformations:
- `<script>`, `<canvas>`, `<video>`, `<svg>` → removed
- `<nav>`, `<section>`, `<article>` → `<div>`
- Flexbox/grid → `<table>` layouts
- `style=""` → `bgcolor`, `align`, `width` attributes
- `charset=utf-8` → `charset=iso-8859-1`

### WaybackBridge
- Rewrites URLs: `http://X` → `https://web.archive.org/web/YYYYMMDD/http://X`
- Cleans Wayback toolbar injection from responses
- Uses Availability API to check if pages are archived

### ImageTranscoder (CoreGraphics/AppKit)
- WebP, AVIF, HEIF → JPEG (configurable quality)
- PNG → JPEG (lossy, smaller) or pass-through
- Resizes to max dimensions (default 640×480)
- Passthrough for already-compatible JPEG/GIF

## GUI (SwiftUI)
- Dashboard: on/off, IP:port display, stats
- Wayback Mode: toggle + date picker
- Transcoding: level selector, image quality slider
- Request Log: live table of proxied requests

## Future / Stretch Goals
- FTP gateway (serve downloads to Fetch/Anarchie)
- Bonjour/mDNS broadcast for easy proxy discovery
- PAC file auto-config served from the proxy
- MacBinary encoding for file downloads
- Gopher protocol support
