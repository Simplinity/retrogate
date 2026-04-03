# RetroGate

**Browse the modern web on vintage Macs.**

RetroGate is a macOS proxy server that bridges the gap between classic Macintosh computers (1984–2005) and today's internet. It runs on a modern Mac (Apple Silicon) on your local network and handles all the heavy lifting — TLS, HTML5, modern image formats — so your old Mac doesn't have to.

🌐 **retrogate.app**

## What it does

1. **TLS Bridge** — Old Macs can't do TLS 1.2/1.3. RetroGate fetches HTTPS sites and serves them back as plain HTTP.
2. **HTML Transcoder** — Converts modern HTML5/CSS3/JS pages into clean HTML 3.2 that Netscape 2, MacWeb, and iCab can actually render.
3. **Image Transcoder** — Converts WebP/AVIF to JPEG/GIF, resizes images to vintage-friendly dimensions.
4. **Wayback Machine Mode** — Set a date, and RetroGate fetches every page from the Wayback Machine. Browse the web as it was in 1997.
5. **FTP Gateway** *(planned)* — Serve files over FTP for classic Mac FTP clients like Fetch.

## Supported vintage browsers

- MacWeb 1.x–2.x (System 6/7)
- Netscape Navigator 1.x–4.x
- Internet Explorer for Mac 2.x–5.x
- iCab 2.x–3.x
- Cyberdog
- Classilla (Mac OS 9)

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon
- Swift 5.9+
- A vintage Mac on the same network (Ethernet via bridge, or LocalTalk→Ethernet adapter)

## Building

```bash
cd retrogate
swift build
swift run RetroGate
```

Or open in Xcode:
```bash
open Package.swift
```

## Usage

1. Launch RetroGate on your modern Mac
2. Note the IP address and port (default: `8080`)
3. On your vintage Mac, set the HTTP proxy to `<modern-mac-ip>:8080`
4. Browse!

## Architecture

```
Sources/
├── RetroGate/         # SwiftUI app + CLI entry point
├── ProxyServer/       # SwiftNIO HTTP proxy listener
├── HTMLTranscoder/    # HTML5 → HTML 3.2 conversion
├── WaybackBridge/     # Wayback Machine integration
└── ImageTranscoder/   # Image format conversion & resizing
```

## License

MIT
