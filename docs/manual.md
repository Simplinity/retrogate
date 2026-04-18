# RetroGate: The Manual

### *A Portal Through Time for Your Beige Plastic Friends*

---

## A Manifesto

Somewhere in a landfill, a PowerBook 520 is crying.

Not because it's broken — it still boots, still runs, still has that satisfying *bong* — but because the entire internet has left it behind. Every website now requires JavaScript frameworks that weigh more than the PowerBook's entire hard drive. Every image is in a format invented two decades after its last system update. Every page assumes you have more RAM than this machine has atoms.

**RetroGate exists because we refuse to accept this.**

We believe that a Macintosh Plus deserves to browse Wikipedia. That a Windows 95 machine should be able to search DuckDuckGo. That Mac OS 9 — the last truly great Classic Mac OS, fight me — should be able to reach the entire World Wide Web, including the parts that didn't exist when it was alive.

RetroGate is a proxy server that sits between your vintage computer and the modern internet. It translates. It transcodes. It strips away twenty years of web bloat and delivers the content your old machine actually asked for, in a format it can actually understand.

It also has a Wayback Machine mode, because sometimes the best way to browse the web on a 1999 computer is to browse the 1999 web.

This is not nostalgia. This is *infrastructure*.

---

## Table of Contents

1. [Getting Started (The 90-Second Setup)](#1-getting-started)
2. [The Dashboard (Mission Control)](#2-the-dashboard)
3. [Choosing Your Vintage Machine](#3-choosing-your-vintage-machine)
4. [Wayback Machine Mode (Time Travel)](#4-wayback-machine-mode)
5. [The Cache (Your Personal Time Capsule)](#5-the-cache)
6. [The Built-In Start Page](#6-the-built-in-start-page)
7. [The Request Log (Snooping on Your Own Traffic)](#7-the-request-log)
8. [The Wayback Timeline (Temporal Forensics)](#8-the-wayback-timeline)
9. [What RetroGate Does to Your Pages](#9-what-retrogate-does-to-your-pages)
10. [Image Transcoding & Dithering](#10-image-transcoding--dithering)
11. [Advanced Settings (Here Be Dragons)](#11-advanced-settings)
12. [The Menu Bar (For Minimalists)](#12-the-menu-bar)
13. [Keyboard Shortcuts (For Power Users)](#13-keyboard-shortcuts)
14. [Dead Services & Redirect Magic](#14-dead-services--redirect-magic)
15. [SheepShaver Users (Read This)](#15-sheepshaver-users)
16. [Troubleshooting (When Things Go Sideways)](#16-troubleshooting)
17. [FAQ (Frequently Argued Questions)](#17-faq)

---

## 1. Getting Started

RetroGate takes about 90 seconds to set up. The hardest part is typing an IP address on a vintage keyboard, which — depending on your keyboard — might take the remaining 85 of those seconds.

### Step 1: Launch RetroGate

Open the app. The proxy server starts automatically. You'll see a gold antenna icon gently pulsing in the hero card, which is RetroGate's way of saying *"I'm ready, send me your decrepit HTTP requests."*

### Step 2: Note the Proxy Address

The dashboard shows your proxy address, something like:

```
192.168.0.130:8080
```

There's a handy copy button next to it. It looks like two overlapping documents, because that's the universal icon for "copy" and we are not here to reinvent semiotics.

### Step 3: Configure Your Vintage Browser

On your vintage Mac or PC, open your browser's proxy settings and enter:

- **HTTP Proxy:** the IP address shown in RetroGate
- **Port:** 8080 (or whatever you've configured)

If you're running **SheepShaver**, the host machine is reachable at `10.0.2.2` from inside the VM.

### Step 4: Browse

Type a URL. Any URL. Watch in awe as a website built with React, Tailwind, and the hopes and dreams of a thousand npm packages gets lovingly downgraded into something your Quadra 605 can render.

### The PAC File Shortcut

Don't want to manually configure proxy settings? Point your browser's auto-proxy-configuration to:

```
http://retrogate/proxy.pac
```

This serves a PAC file that routes all HTTP traffic through RetroGate automatically. It's the lazy option, and we respect that.

---

## 2. The Dashboard

The Dashboard is your command center. It tells you everything about what RetroGate is doing without you having to wonder.

### The Hero Card

At the top, a status card shows:

- **Proxy status** — "Proxy running" or "Proxy running in **Wayback** mode" (or, if something has gone wrong, "Proxy stopped," at which point you should press the play button)
- **Your proxy address** — with a copy button
- **Current preset** — e.g., "Mac OS 9"
- **Screen resolution** — e.g., "1024 × 768"

The animated antenna icon pulses gently when the proxy is running. It does not pulse when stopped. We considered making it droop sadly, but decided that was too emotionally manipulative.

### The Four Stat Cards

Below the hero, four cards give you the numbers:

| Card | What It Shows |
|------|---------------|
| **Requests** | Total requests served this session, plus page count |
| **Bandwidth** | Total bytes delivered to your vintage browser |
| **Saved** | How much bandwidth transcoding saved you (as a percentage and in bytes). This number tends to be impressive. You're welcome. |
| **Uptime** | How long the proxy has been running |

### The Detail Cards

Four more cards round out the bottom:

- **Top Domains** — Your top 5 most-visited domains, with gold bar charts. Useful for realizing you've been reading the same Wikipedia article for three hours.
- **Content Mix** — A stacked bar chart showing the breakdown of HTML pages, images, CSS, and other content. In Wayback mode, expect a lot of images. In 1999, people really loved their GIF animations.
- **Image Transcoding** — How many images were converted, their original vs. transcoded size, and the compression ratio. This card exists so you can appreciate the sheer violence RetroGate inflicts on modern WebP files.
- **Wayback Mode / Status** — Shows your target date, tolerance, and era when in Wayback mode. Also displays error count and recent errors.

---

## 3. Choosing Your Vintage Machine

Navigate to **Configure → Vintage Computer** in the sidebar.

RetroGate ships with 10 presets spanning two platforms. Each preset configures the transcoding level, image quality, output encoding, and screen resolution automatically — because you have better things to do than figure out whether Mac OS 8 used MacRoman or ISO-8859-1. (It used MacRoman. They all used MacRoman. Except the PCs. The PCs used ISO-8859-1. See? You didn't want to know that.)

### Mac Presets

| Preset | Year | Era | Default Resolution | Default Colors | HTML Level |
|--------|------|-----|-------------------|----------------|------------|
| **System 6** | 1988 | 1993–1995 | 512 × 342 | B&W (1-bit) | Aggressive |
| **System 7** | 1991 | 1994–1997 | 640 × 480 | 256 Colors | Aggressive |
| **Mac OS 8** | 1997 | 1997–1999 | 832 × 624 | Thousands | Moderate |
| **Mac OS 9** | 1999 | 1999–2002 | 1024 × 768 | Millions | Moderate |
| **Mac OS X** | 2001 | 2001–2005 | 1024 × 768 | Thousands | Minimal |

### PC Presets

| Preset | Year | Era | Default Resolution | Default Colors | HTML Level |
|--------|------|-----|-------------------|----------------|------------|
| **Windows 3.1** | 1992 | 1994–1996 | 640 × 480 | 16 Colors | Aggressive |
| **Windows 95** | 1995 | 1995–1998 | 800 × 600 | 256 Colors | Moderate |
| **Windows 98** | 1998 | 1998–2001 | 800 × 600 | Thousands | Moderate |
| **Windows 2000** | 2000 | 2000–2003 | 1024 × 768 | Thousands | Minimal |
| **Windows XP** | 2001 | 2001–2006 | 1024 × 768 | Thousands | Minimal |

> **Historical note:** System 6 (1988) and Windows 3.1 (1992) technically predate the World Wide Web. But they *can* run early browsers like MacWWW and Mosaic, so their eras start at 1993 — the year Tim Berners-Lee's invention escaped the physics lab and entered the real world. We're being generous.

### Color Depth

Each preset supports a range of color depths. Choose the one that matches your vintage display:

- **B&W (1-bit)** — For the Mac Plus, SE, and Classic. Images are dithered using the Floyd-Steinberg algorithm, producing that gorgeous halftone newspaper look that makes everything feel important.
- **16 Colors** — Standard VGA palette. Images are dithered with a Bayer 4×4 ordered pattern. Hello, Windows 3.1.
- **256 Colors** — The sweet spot of the mid-90s. GIF palette quantization. Everything looks like a slightly compressed photograph of a photograph.
- **Thousands (16-bit)** — 32,768 colors. Good enough for most things, slightly banded on gradients. The "I have a nice monitor but not *that* nice" option.
- **Millions (24-bit)** — Full color JPEG. For the Mac OS 9 users who splurged on that 17-inch Apple Studio Display. You earned this.

### Platform Memory

When you switch between Mac and PC, RetroGate remembers your last-used preset, resolution, and color depth for each platform. So you can toggle between "Mac OS 9 at 1024×768 in Millions" and "Windows 98 at 800×600 in Thousands" without reconfiguring everything. It's the little things.

---

## 4. Wayback Machine Mode

Navigate to **Configure → Wayback Machine** in the sidebar, or press **Cmd+Shift+W**.

This is where RetroGate transcends "proxy server" and becomes "time machine."

### How It Works

When Wayback mode is enabled, RetroGate fetches pages from the **Internet Archive's Wayback Machine** instead of the live internet. This means you're not just transcoding modern pages for a vintage browser — you're browsing the actual web *as it existed in the past*.

Want to see what Apple.com looked like in 1999? What Google looked like before it had a logo? What GeoCities looked like before Yahoo killed it? This is your feature.

### Configuration

- **Target Date** — Pick any date. When you select a vintage preset, RetroGate auto-suggests the midpoint of that OS's era (e.g., Mac OS 9 → June 2000).
- **Date Tolerance** — How far from your target date the Wayback Machine is allowed to stray. Options: 1, 3, 6, 9, or 12 months, or "Any date" for maximum coverage.

### Temporal Consistency

When you load a page, RetroGate resolves the *actual* snapshot date from the Wayback Machine and then loads all sub-resources (images, CSS) from that same date. This prevents the cursed scenario where your page is from 1999 but the images are from 2003 and the CSS is from 2007 and nothing makes sense.

### Date Drift Guard

If the Wayback Machine's closest snapshot is too far from your target date, RetroGate shows a warning with links to nearby available snapshots. You can jump to any of them by clicking the link — each one uses a `?__wb=YYYYMMDD` parameter to override the target date for that specific request.

### Auto-Fallback (Live Web Mode)

Even when you're *not* in Wayback mode, RetroGate has your back. If a live website returns a 403, 404, 410, or 451 error, RetroGate automatically checks the Wayback Machine for an archived version. Because sometimes the page you want exists — it's just been deleted, paywalled, or geoblocked. The internet remembers even when webmasters don't.

### Response Caching

Every Wayback response is stashed on disk automatically. Archived content is immutable by definition — a page from June 15, 1999 will be the same page from June 15, 1999 tomorrow, next week, and after the heat death of the universe. Second visits are instant.

The **Cache** tab in the sidebar is where you live with this. Browse, filter, search, pin, bundle, export, import, prefetch — see [Section 5: The Cache](#5-the-cache) for the full breakdown.

---

## 5. The Cache

Navigate to **Monitor → Cache** in the sidebar.

The Wayback Machine is a miracle of human civilization. It is also *slow*. Every request to `web.archive.org` takes two to five seconds, because it's reconstructing the web from tape archives older than some of your coworkers. Multiply that by every image on a 1999 GeoCities page and you can boil water between clicks.

RetroGate's cache fixes this by saving every successful archive response to your local disk. Second visit? Instant. Third visit? Still instant. Next year, on a different vintage Mac? Still instant. Archived content doesn't change, so there's no reason to fetch it twice.

**Everything in this chapter is about the Wayback cache.** Live-web responses are not cached — live sites change, and a proxy that served you stale news from three weeks ago would be a disservice.

### Where the Cache Lives

```
~/Library/Containers/com.brunowernimont.retrogate/Data/
  Library/Caches/RetroGate/
  ├── blobs/           ← one file per cached response, SHA-256-keyed
  └── index.sqlite     ← metadata sidecar (URL, domain, snapshot date, etc.)
```

The blobs are raw bytes with a tiny 4-byte header. The sidecar is a proper SQLite database with an FTS5 full-text index bolted on. Open it with any SQLite tool; it won't bite.

### Tour of the Cache Tab

From top to bottom:

1. **Offline Mode banner** — flip this to serve from cache only (see below)
2. **Hero stats** — four tiles with the headline numbers
3. **Retention bar** — max size, auto-delete age, Sweep now
4. **Capsules bar** — your named collections, plus Import and Prefetch buttons
5. **Filters bar** — URL search, domain dropdown, type dropdown, pinned-only toggle
6. **Content search bar** — full-text search across HTML pages
7. **Toolbar** — Refresh, bulk Pin/Unpin/Delete, Clear All
8. **Table** — one row per cached response, sortable by every column

### The Hero Stats

| Tile | What It Shows |
|------|---------------|
| **Entries** | Total cached responses on disk |
| **On Disk** | Total bytes (HTML + images + CSS + JS — everything that got cached) |
| **Hits** | Lifetime count of cache hits: how many round-trips to archive.org you've avoided |
| **Oldest** | Age of the oldest cached entry, so you know how long your personal archive has been growing |

### Retention (Or: How Long You Keep Things)

By default, nothing is ever deleted. Your cache grows forever. This is fine — 100,000 cached pages are usually a gigabyte or two, and you didn't buy that hard drive for moral support.

If you'd rather not hoard, the Retention bar has two knobs:

- **Max size** in MB — RetroGate evicts least-recently-used non-pinned entries until it's under the cap
- **Auto-delete after** N days — entries untouched for that long get swept away

Set either or both; `0` means "no limit" for that axis. **Sweep now** runs the policy on demand, useful after changing a value.

Eviction is **LRU-aware** and **pin-aware**: we delete the least-recently-accessed non-pinned entries first. A pinned entry is never evicted, period — not for age, not for size, not ever. (If your pinned collection alone exceeds the size cap, the cap quietly loses the argument.)

Automatic sweeps also run every 50 new inserts, so in practice the cache trims itself without you thinking about it.

### Offline Mode

The banner at the top has a switch. Flip it on and RetroGate stops reaching out to archive.org entirely. Cache hit? Served instantly. Cache miss? A friendly 404 explaining you're offline.

Use it when:

- **You're on a train, plane, or cabin with no WiFi** — and the pages you care about are already cached
- **archive.org is rate-limiting you** — which happens during heavy sessions
- **You're demoing RetroGate** — and want to prove the cache works without the network doing any of the work

A tiny gold dot appears next to "Cache" in the sidebar whenever offline mode is on, so you remember.

### Selecting, Pinning, Deleting

Rows behave like any macOS list: click to select, Shift-click to extend, Cmd-click to add/remove individually.

The leftmost column is a clickable pin icon — tap it to pin or unpin that row. Pinned rows survive every eviction policy and every Sweep. They're your "definitely keep this forever" flag.

The toolbar at the bottom runs bulk operations:

- **Refresh** — re-read the index (handy after heavy browsing)
- **Pin / Unpin** — for every selected row
- **Delete** — removes both the blob file and the index row
- **Clear All** — nukes the entire cache, including pinned entries, with a confirmation prompt because this is the kind of button that makes you feel briefly awful if you misclick

Right-click a row for the same options plus **Copy URL** (handy for sharing a specific archive link with your nerd friends).

### Filters

Filters narrow the table without touching the underlying cache:

- **Filter by URL** — substring, case-insensitive. Type "apple" to see only URLs containing "apple"
- **Domain** — dropdown populated from whatever domains are actually in your cache
- **Type** — HTML, Images, CSS, JavaScript, Other, or All
- **Pinned only** — a toggle button for "show me my curated keepers"

Filters **stack**. Searching "imgs" in Images on apple.com pinned-only is a perfectly valid query. When any filter is active, a "Clear filters" link appears on the right.

### Capsules (Named Collections)

Capsules are named bundles of cache entries. Think of them as playlists for archived web pages.

**Create one from a selection:**

1. Select the rows you want
2. Click **New from selection** in the Capsules bar
3. Type a name ("Apple 1997", "Y2K News Week", whatever makes you happy)
4. Optionally, a description

The capsule appears as a chip in the Capsules bar with its member count. Click it to filter the table to just that capsule. Click **All** to deselect.

**Right-click a capsule chip** for:

- **Rename…** — change the name or description
- **Export…** — save the capsule as a `.retrogate-capsule` bundle (see below)
- **Delete Capsule** — removes the collection but keeps the underlying entries in your cache. The blobs aren't touched.

### Exporting & Importing Capsules

Capsules travel. Export one and you get a folder named `<capsule>.retrogate-capsule`:

```
Apple 1997.retrogate-capsule/
  ├── manifest.json         ← capsule metadata + entry list
  └── blobs/
      ├── a8f3d2c...
      └── ...
```

The manifest is human-readable JSON; the blobs are raw cached bytes. Show Package Contents in Finder and you can inspect everything. No zip, no proprietary format, no mystery — just files.

**Import** someone else's capsule with the Import… button in the Capsules bar: pick their `.retrogate-capsule` folder, and the blobs and metadata merge into your cache. The capsule appears in your chip list, pre-selected so you can see what just arrived.

Things that come along: the full entry metadata (URL, snapshot date, content-type), notes, and pin flags. Things that don't: hit counts and last-accessed timestamps — those reflect *your* relationship with the page, not the sender's.

### Prefetch (Warming the Cache)

Prefetch pre-loads a list of pages without you manually visiting each one. You paste URLs, RetroGate fetches them in the background at a polite 1-per-second pace.

Use it for:

- **"I'm going on a flight Tuesday"** — load up your reading list the night before
- **Curating a capsule** — prefetch, then bundle the results
- **Not getting banned** — archive.org notices aggressive fetching; 1/sec is gentle

Click **Prefetch…** in the Capsules bar to open the sheet. Rules:

- One URL per line
- Lines starting with `#` are comments (skipped)
- Bare hostnames get `http://` prefixed automatically
- Already-cached URLs are skipped instantly (no rate-limit tick)

Progress is live: done/total, fetched-from-net vs. already-cached, failed. Hit **Cancel** at any time to stop cleanly (no mid-fetch interruption — the current request completes first).

When it finishes, the sheet offers to wrap the successful fetches into a new capsule. Type a name, click Done, and you've got a ready-to-export bundle.

### Full-Text Search

RetroGate indexes the plain text of every cached HTML page into a SQLite FTS5 full-text index. This lets you search **inside** pages, not just URLs.

Type into **Search page contents** and the table filters to matching rows, ordered by relevance. Each matching row shows a short snippet with the matching words **bolded**.

Query syntax is standard FTS5:

| Query | Matches |
|-------|---------|
| `system 7` | Pages containing both words anywhere |
| `"system 7"` | The exact phrase |
| `macintosh OR windows` | Either |
| `apple NEAR/5 macintosh` | "apple" within 5 words of "macintosh" |
| `pow*` | Prefix wildcard: "power", "powerbook", "powerful", etc. |

The tokenizer uses Porter stemming, so `run` also matches `running` and `runs`. English-specific, but works surprisingly well on most text.

**Build Index** next to the search field runs a full rebuild over every HTML blob currently on disk. You want to click this once after upgrading to the search-enabled version; going forward, new pages get indexed automatically as they cache. The little coverage indicator tells you how many HTML entries are indexed vs. cached (orange = incomplete).

Noisy markup (`<script>`, `<style>`, `<noscript>`) is stripped before indexing, and whitespace is collapsed, so searches match actual words — not JavaScript source or CSS rules. Documents longer than 256 KB of text are clipped (~50,000 words, which is generous; your average 1999 page is about 500 words).

### How All of This Works Together

A typical session:

1. Turn on Wayback mode, pick a date, browse around
2. Everything you hit gets cached automatically
3. Later, open the Cache tab and find the pages you want to keep
4. Pin the keepers, or create a capsule to bundle them
5. Export the capsule to share with a friend or keep as a backup
6. Set a Max size if you want the cache to cap itself
7. Turn on Offline Mode before a long flight

Or: paste a URL list into Prefetch, wrap the results in a capsule, name it "Research for my blog post," and come back next week to find it all instant.

---

## 6. The Built-In Start Page

Point your vintage browser to:

```
http://retrogate/
```

This is RetroGate's portal page — a lovingly crafted start page in HTML 3.2 that actually looks good in Internet Explorer 3.

### What's On It

- **A search box** — Powered by DuckDuckGo (see below)
- **Popular sites** — Apple, Microsoft, Google, Wikipedia, Hacker News, BBC, CNN
- **Retro sites** — 68kMLA Forum, Macintosh Repository, Macintosh Garden, System 7 Today, the Wayback Machine itself, OldWeb.today
- **Reference** — Wikipedia, Weather.gov, IMDb
- **Wayback status** — Shows whether Wayback mode is active and what date you're targeting

### The Search Gateway

```
http://retrogate/search?q=your+query+here
```

RetroGate wraps DuckDuckGo's HTML endpoint in a vintage-friendly interface. Search results show titles, snippets, and URLs — up to 20 results per query. DuckDuckGo's tracking redirect URLs are automatically unwrapped so your vintage browser goes straight to the destination.

You can also search directly from the start page's search box. It's like Google in 1998, except it actually respects your privacy.

---

## 7. The Request Log

Navigate to **Monitor → Request Log** in the sidebar.

This is the full, unfiltered firehose of every request your vintage browser makes through RetroGate.

### Columns

| Column | Description |
|--------|-------------|
| **Time** | When the request happened |
| **Method** | GET, POST, etc. (it's almost always GET — vintage browsers were simple creatures) |
| **URL** | The full URL, truncated in the middle if it's too long |
| **Status** | HTTP status code. Green if under 400, red if 400+. |
| **Size** | Response size after transcoding |

Right-click any entry to copy the URL. If a request had an error, you'll see a tiny gold warning triangle and the error message in the context menu.

---

## 8. The Wayback Timeline

Navigate to **Monitor → Wayback Timeline** in the sidebar.

This tab shows only HTML pages served from the Wayback Machine and compares your *target* date with the *actual* archive date.

### The Delta Column

The most interesting column is **Delta**, which tells you how far the actual snapshot strayed from your target:

- 🟢 **Green** — Within 7 days. "Exact" if it's a perfect match.
- 🟡 **Gold** — 8 to 90 days off. Close enough.
- 🔴 **Red** — More than 90 days off. The Wayback Machine did its best.

This is useful for spotting when a site's earliest snapshot postdates your target era, or when the Archive has a gap in its crawl history.

---

## 9. What RetroGate Does to Your Pages

RetroGate doesn't just forward web pages. It *translates* them from the language of 2026 to the language your browser speaks. Here's what happens at each transcoding level:

### Aggressive (HTML 3.2) — System 6, System 7, Windows 3.1

The full time-warp treatment. Your page comes out looking like it was authored in 1996:

- All CSS is stripped — every last rule
- HTML5 semantic tags (`<nav>`, `<article>`, `<section>`, `<header>`, `<footer>`, etc.) are replaced with `<div>`s
- `<strong>` becomes `<b>`, `<em>` becomes `<i>` (the 90s didn't have semantic emphasis)
- Inline CSS properties are converted to HTML 3.2 attributes: `style="background-color: red"` becomes `bgcolor="#ff0000"`
- CSS font sizes (px, pt, em, rem, keywords) are mapped to HTML's 1–7 font scale
- Navigation lists are converted to table-based layouts
- Body content is wrapped in layout tables (because in HTML 3.2, tables *are* the layout engine)
- CSS colors are normalized to hex: `rgb(255, 0, 128)` → `#ff0080`, `navy` → `#000080`

### Moderate (CSS Stripped) — Mac OS 8, Mac OS 9, Windows 95, Windows 98

A gentler approach. The HTML stays modern-ish, but CSS gets removed:

- All `<style>` blocks and `<link rel="stylesheet">` references are stripped
- HTML5 semantic tags are downgraded to `<div>`s
- `<strong>` → `<b>`, `<em>` → `<i>`
- Everything from Minimal (see below) is also applied

### Minimal (CSS Preserved) — Mac OS X, Windows 2000, Windows XP

The lightest touch. For browsers that can handle *most* of the modern web:

- JavaScript is stripped (your vintage browser can't run it anyway)
- `<noscript>` content is preserved and unwrapped (finally useful!)
- `<meta charset="utf-8">` is replaced with your target encoding
- CSP, SRI, and CORS attributes are stripped (`integrity=`, `crossorigin=`, Content-Security-Policy meta tags)
- `@font-face` web fonts are stripped from CSS (your browser doesn't have Roboto, and it never will)
- JavaScript redirects (`window.location = "..."`) are converted to `<meta http-equiv="refresh">` tags
- CSS vendor prefixes are injected for older browsers (`-webkit-`, `-moz-`, `-ms-`)
- Java `<applet>` tags are stripped (they crash SheepShaver's MRJ), but `<embed>` and `<object>` are preserved (QuickTime still works!)

### Applied at All Levels

No matter the transcoding level, every page gets:

- **HTTPS → HTTP downgrade** — All `https://` URLs in the HTML become `http://`, because your vintage browser doesn't speak TLS
- **Cookie `Secure` flag stripping** — Modern cookies marked `Secure` won't work over HTTP, so RetroGate strips that flag
- **Unicode smart character cleanup** — Curly quotes become straight quotes, em-dashes become `--`, ellipses become `...`, non-breaking spaces become regular spaces, arrows become ASCII art (`←` → `<-`), and trademark symbols become `(TM)`. Your vintage encoding can't handle Unicode, but RetroGate makes sure the meaning survives.
- **Character encoding conversion** — UTF-8 content is converted to MacRoman (Mac presets) or ISO-8859-1 (PC presets)
- **Tracking redirect resolution** — URLs like `tracker.com/click?url=http://real-site.com` are resolved to the actual destination. RetroGate checks 15+ common redirect parameter names (`redirect`, `next`, `url`, `dest`, `goto`, `callback`, etc.)

---

## 10. Image Transcoding & Dithering

Modern websites serve images in WebP, AVIF, and other formats that didn't exist when your browser was young. RetroGate converts them all to JPEG or GIF.

### Format Selection

RetroGate inspects your browser's `Accept` header to decide the output format:

- If your browser accepts JPEG → JPEG at the configured quality
- If your color depth is 256 or fewer → GIF (with palette quantization)
- If your color depth is B&W → GIF with Floyd-Steinberg dithering

SVG images are rendered to raster (PNG/JPEG/GIF) because vector graphics are a concept your browser finds deeply confusing.

### Dithering Modes

For low-color displays, RetroGate applies dithering to make images look as good as possible with limited palettes:

| Color Depth | Dithering Algorithm | Result |
|-------------|-------------------|--------|
| **B&W (1-bit)** | Floyd-Steinberg error diffusion | Gorgeous halftone — like reading a newspaper, but on a $4000 computer from 1986 |
| **16 Colors** | Bayer 4×4 ordered dithering | Classic VGA crosshatch pattern. Very Windows 3.1. |
| **256 Colors** | GIF palette quantization | The mid-90s sweet spot. If it was good enough for the Dancing Baby, it's good enough for you. |
| **Thousands+** | None needed | Full-color JPEG. Living the dream. |

### Image Resizing

All images are resized to fit your configured screen resolution. A 4000×3000 pixel photograph from a modern DSLR review site will be thoughtfully shrunk to 600 pixels wide for your 640×480 display. The original bytes never even reach your vintage machine.

### Image Prefetching

When RetroGate processes an HTML page, it scans for all image URLs and prefetches them in parallel in the background. By the time your vintage browser requests each image, it's already cached and ready. This makes page loads dramatically faster, especially in Wayback mode where each image request would otherwise be a separate round-trip to the Internet Archive.

### Broken Image Handling

When an image fails to load (404, timeout, etc.), RetroGate returns a transparent 1×1 GIF instead of an error page. This preserves your page layout instead of littering it with broken image icons.

---

## 11. Advanced Settings

Open **Settings** (Cmd+,) to access the advanced configuration.

### General Tab

- **Port** — Change the proxy port (default: 8080). Press Apply to restart the server.
- **Minify HTML** — Strips comments, collapses whitespace, and removes blank lines. Reduces page size by 20–40%. Your modem-era connection will thank you. Note: this doesn't change how the page looks, only how much data crosses the wire.

### Advanced Tab

- **Transcoding Bypass Domains** — Some websites are already retro-friendly. They use simple HTML, minimal JavaScript, and don't need aggressive transcoding. List those domains here (one per line) and RetroGate will only do encoding conversion and HTTPS downgrading — no HTML surgery.

  Default bypass list: `68kmla.org`, `system7today.com`, `macintoshgarden.org`

  Subdomains are matched automatically: entering `68kmla.org` also matches `www.68kmla.org`.

- **Dead Endpoint Redirects** — Custom redirects for dead services (format: `hostname=redirect-url`). See [Section 14](#14-dead-services--redirect-magic) for details.

---

## 12. The Menu Bar

RetroGate puts a small antenna icon in your macOS menu bar. Click it for a quick-access dropdown:

- Proxy status and port
- Start/Stop toggle
- Wayback Machine toggle
- Current preset info
- Request stats (count + bandwidth)
- Quick access to open the main window

The icon pulses when the proxy is running. It's like a heartbeat for your proxy server, except less alarming.

---

## 13. Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **⌘⇧S** | Start/Stop proxy server |
| **⌘⇧W** | Toggle Wayback Machine mode |
| **⌘K** | Clear the request log |
| **⌘,** | Open Settings |

These work from the main window. Memorize them and you'll never need to click anything again, which is good, because clicking is so *2025*.

---

## 14. Dead Services & Redirect Magic

The internet of 1999 had services that no longer exist. When your vintage browser tries to reach its default homepage — say, `home.netscape.com` — it gets nothing. A void. Digital silence.

RetroGate fixes this by redirecting dead services to their Wayback Machine archives (or modern equivalents):

| Dead Service | Where RetroGate Sends You |
|-------------|--------------------------|
| `home.netscape.com` | Wayback Machine archive |
| `channels.netscape.com` | Wayback Machine archive |
| `search.netscape.com` | Wayback Machine archive |
| `home.microsoft.com` | Wayback Machine archive |
| `www.msn.com` | Wayback Machine archive |
| `windowsupdate.microsoft.com` | Wayback Machine archive |
| `itools.mac.com` | Wayback Machine archive |
| `homepage.mac.com` | Wayback Machine archive |
| `www.mac.com` | Wayback Machine archive |
| `www.real.com` | Wayback Machine archive |
| `www.icq.com` | Wayback Machine archive |
| `www.excite.com` | Wayback Machine archive |
| `www.altavista.com` | Wayback Machine archive |
| `www.geocities.com` | Wayback Machine archive |

You can add your own redirects in **Settings → Advanced → Dead Endpoint Redirects** using the format `hostname=url`.

### Redirect Loop Detection

Some websites get stuck in infinite HTTP↔HTTPS redirect loops. RetroGate detects when the same URL is requested 6+ times within 10 seconds and breaks the cycle with a helpful error page. Your vintage browser doesn't need to spend eternity bouncing between `http://` and `https://`.

### Tracking Redirect Resolution

Modern URLs are often wrapped in tracking redirects: `tracker.com/click?redirect=http://actual-site.com`. RetroGate detects and resolves these automatically, sending your browser straight to the real destination. It checks 15+ common redirect parameter names including `redirect`, `url`, `next`, `dest`, `goto`, `callback`, `continue`, `target`, `returnUrl`, `redirect_uri`, and `RelayState`.

---

## 15. SheepShaver Users

If you're running classic Mac OS in **SheepShaver**, a few things to know:

- **Host IP**: Your Mac host is reachable at `10.0.2.2` from inside the VM. Configure this as your HTTP proxy address.
- **Networking drops**: SheepShaver's slirp networking is, shall we say, *temperamental*. If browsing suddenly stops working, restart SheepShaver. This is not a RetroGate bug. This is a SheepShaver feature. (It's a bug. It's definitely a bug.)
- **Java applets**: RetroGate strips `<applet>` tags because they crash SheepShaver's MRJ (Mac OS Runtime for Java). QuickTime embeds (`<embed>` and `<object>`) are preserved because QuickTime is eternal.

---

## 16. Troubleshooting

### "Pages aren't loading"

1. Is the proxy running? Check the dashboard — the antenna should be pulsing.
2. Is your vintage browser configured with the correct IP and port?
3. If using SheepShaver, restart it. Seriously, just restart it.

### "Pages look weird"

Check your preset matches your actual vintage machine. If you're running Mac OS 9 with the System 6 preset, you're going to have a bad time — everything will be in 1-bit dithered GIFs on a machine that can display millions of colors.

### "The Wayback Machine is slow"

That's not RetroGate — that's the Internet Archive. It serves billions of archived pages from a non-profit's server room. It's doing its best. RetroGate caches every response to disk, so subsequent visits are instant. For even faster access, paste your reading list into **Prefetch…** on the Cache tab and let it warm everything up overnight — see [Section 5: The Cache](#5-the-cache).

### "My cache is full / my disk is filling up"

Open the Cache tab, type a number into **Max size** (MB), and click **Sweep now**. Least-recently-used non-pinned entries get evicted until you're under the cap. Alternatively, **Clear All** wipes the whole thing and starts fresh — your pages are all still on archive.org, it's just a second round-trip away.

### "Search doesn't find pages I know are cached"

You might need to build the search index. Click **Build Index** in the Cache tab's Content Search row. Pages cached from this version onward index automatically, but pages cached before the search feature shipped need a one-time backfill. The orange "Index: N/M HTML pages" hint tells you when you're out of sync.

### "I keep getting 'Redirect loop detected'"

A website is bouncing you between HTTP and HTTPS. RetroGate detects this and stops the loop after 6 bounces. There's not much to do — the site genuinely doesn't work over plain HTTP. Try the Wayback Machine version instead.

### "Images are missing"

Some images are served from CDNs that block non-browser requests, or the original server is simply gone. In Wayback mode, some images weren't captured by the Internet Archive's crawler. RetroGate returns a transparent pixel instead of an error, so at least your layout isn't broken.

### "Text characters look wrong"

Make sure your preset platform matches your actual machine. Mac presets output MacRoman encoding, PC presets output ISO-8859-1. If you're seeing garbled characters, you might have a Mac preset on a PC browser (or vice versa).

---

## 17. FAQ

**Q: Does RetroGate work with actual vintage hardware, or just emulators?**
A: Both. If your vintage Mac or PC can make HTTP requests through a proxy, RetroGate will handle the rest. SheepShaver, Basilisk II, QEMU, PCem, 86Box, or genuine beige hardware — RetroGate doesn't discriminate.

**Q: Can I run RetroGate on a Raspberry Pi?**
A: No. RetroGate is a macOS app built with SwiftUI, SwiftNIO, and CoreGraphics. It requires macOS 14+. It's a proxy that runs on your Mac and serves your vintage machines over the network.

**Q: Why can't I just use the Wayback Machine directly on my vintage browser?**
A: Because the Wayback Machine's website itself is a modern web application. It uses JavaScript, modern CSS, and HTTPS — none of which your vintage browser supports. RetroGate acts as an intermediary, fetching from the Wayback Machine with modern TLS and delivering clean archived content in vintage-compatible HTML.

**Q: Will this work with HTTPS sites?**
A: Yes. Your vintage browser sends a plain HTTP request to RetroGate. RetroGate then makes the HTTPS request on its behalf, using modern TLS. If the HTTPS connection fails (expired cert, etc.), RetroGate falls back to plain HTTP automatically.

**Q: What's the maximum page size?**
A: RetroGate caps responses at 10 MB. If a page exceeds this, you'll get a friendly warning. In practice, no page from 1999 was anywhere near this limit. In 2026, some JavaScript bundles exceed it. We don't talk about those.

**Q: Can I use this to browse the modern web on vintage hardware permanently?**
A: You can certainly try. Some modern sites transcode surprisingly well. Others... less so. Sites that are mostly text (Wikipedia, news articles, forums) work great. Sites that are mostly JavaScript-rendered SPAs (Twitter, modern Reddit, Gmail) will give you a blank page with perhaps a sad `<noscript>` message. Enable `<noscript>` preservation is on by default, so at least you'll see *something*.

**Q: Is this legal?**
A: RetroGate is a proxy server on your local network. It's no different from any other HTTP proxy. The Wayback Machine integration uses the Internet Archive's public API and respects robots.txt. You're fine.

**Q: Where is the cache stored? / How big can it get?**
A: `~/Library/Containers/com.brunowernimont.retrogate/Data/Library/Caches/RetroGate/`. By default it grows without bound — 100,000 cached pages are typically a gigabyte or two, and "I want to keep every page I've ever visited forever" is a completely valid stance. Set a max size in the Cache tab if you'd rather cap it.

**Q: Does the cache survive a restart?**
A: Yes. Restarts, reboots, and upgrades all preserve it. The only ways to wipe it are **Clear All** in the Cache tab, or upgrading to a future version that bumps the storage format (which we announce in release notes).

**Q: Does RetroGate cache live-web pages too?**
A: No, only Wayback responses. Live sites change — caching today's CNN homepage and serving it tomorrow would be a disservice. Archived content doesn't have that problem; a snapshot from June 1999 is still the snapshot from June 1999 next week.

**Q: Can I share a capsule with someone?**
A: Yes. Right-click a capsule chip, pick Export…, and you get a `.retrogate-capsule` folder you can zip, AirDrop, email, or stick on a USB key. The other person opens their Cache tab, clicks Import…, and picks the folder. Done. (The format is human-readable JSON plus raw bytes, so it'll still work with a future version of RetroGate even if we change things internally.)

**Q: Why "RetroGate"?**
A: Because it's a *gate* between the *retro* internet and the modern one. Also because every good project needs a name that sounds vaguely like a political scandal. RetroGate: the controversy of making old computers useful again.

---

## Appendix: The Supported Color Depths in Loving Detail

Because someone will ask.

| Depth | Colors | Encoding | Dithering | Historical Context |
|-------|--------|----------|-----------|-------------------|
| B&W | 2 | GIF | Floyd-Steinberg | The original Macintosh (1984). 512×342 pixels. One bit per pixel. Every pixel was either black or white, and we were *grateful*. |
| 16 Colors | 16 | GIF | Bayer 4×4 | Standard VGA. The palette that launched a thousand Windows 3.1 screenshots. Includes such classics as "dark cyan" and "bright magenta." |
| 256 Colors | 256 | GIF | Palette quantization | The golden age of pixel art. Every image looked slightly posterized. Every desktop wallpaper was 640×480 and took up half your hard drive. |
| Thousands | 32,768 | JPEG | 5-bit quantization | 16-bit color. Good enough for photographs, obvious on gradients. The "we're getting there" era of display technology. |
| Millions | 16.7M | JPEG | None | 24-bit true color. The end of the rainbow. Your 1999 CRT could display all of them, and your 2026 OLED still can't do much better for web content. |

---

*RetroGate is made with love, SwiftNIO, and an irrational attachment to beige plastic.*

*If you made it this far, you're our kind of person. Now go browse something.*
