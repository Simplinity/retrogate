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
                                  2. Check dead endpoint redirects
                                  3. [Wayback?] Rewrite URL (id_/im_/cs_/js_ modifiers)
                                  4. Fetch via URLSession (TLS 1.3) ──▶ https://apple.com
                                     (falls back to HTTP on cert errors)
                                  5. Receive modern response         ◀── HTML5 + CSS3 + JS
                                  6. Route by Content-Type:
                                     - HTML → transcode to HTML 3.2
                                     - Image → transcode/dither
                                     - CSS/JS → URL upgrades
                                     - Other → passthrough
                                  7. Encode to iso-8859-1 or MacRoman
◀── simplified HTML 3.2 ─────────  8. Send HTTP/1.0 response
```

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

## GUI (SwiftUI)
- **Dashboard**: on/off toggle, IP:port display, stats
- **Request Log**: live table of proxied requests (method, URL, status, sizes)
- **Wayback Timeline**: snapshot date visualization vs target date
- **Wayback Machine**: toggle, date picker, tolerance slider
- **Vintage Computer**: platform presets (Mac OS 7–10.4, Windows 3.1, Amiga, etc.) with matching screen resolution, color depth, and encoding defaults

Configuration includes: transcoding level, image quality, color depth, output encoding (iso-8859-1 / MacRoman), bypass domains, dead endpoint redirects, HTML minification toggle.

## Future / Stretch Goals
- FTP gateway (serve downloads to Fetch/Anarchie)
- Bonjour/mDNS broadcast for easy proxy discovery
- MacBinary encoding for file downloads
- Gopher protocol support
