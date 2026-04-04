import Foundation
import SwiftSoup
import Logging

/// Handles Wayback Machine integration.
/// Rewrites outgoing URLs to fetch archived versions, and cleans
/// Wayback Machine's injected toolbar/scripts from responses.
public struct WaybackBridge {
    
    private let logger: Logger
    
    /// The date to fetch archived pages for (YYYYMMDD format for Wayback API)
    public var targetDate: Date
    
    /// Base URL for the Wayback Machine
    private let waybackBase = "https://web.archive.org/web"
    
    public init(targetDate: Date = Date()) {
        self.targetDate = targetDate
        var logger = Logger(label: "app.retrogate.wayback")
        logger.logLevel = .info
        self.logger = logger
    }
    
    /// Format the target date as YYYYMMDD for the Wayback Machine URL scheme.
    private var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: targetDate)
    }
    
    /// Rewrite a URL to fetch from the Wayback Machine.
    /// Uses content-type modifiers so the Wayback Machine returns raw data
    /// instead of wrapping assets in HTML.
    /// e.g., `http://apple.com/img.gif` → `https://web.archive.org/web/19970101im_/http://apple.com/img.gif`
    public func rewriteURL(_ originalURL: URL) -> URL {
        let modifier = Self.waybackModifier(for: originalURL)
        let waybackURL = "\(waybackBase)/\(dateStamp)\(modifier)/\(originalURL.absoluteString)"
        return URL(string: waybackURL) ?? originalURL
    }

    /// Pick the right Wayback Machine modifier based on the URL's file extension.
    ///
    /// **Critical**: HTML pages use `id_` (identity) — raw content with NO URL rewriting.
    /// The old `if_` modifier caused Wayback to rewrite every URL in the page to
    /// `/web/TIMESTAMP/original-url`, which then leaked through to the browser
    /// despite extensive cleaning. With `id_`, URLs stay as the original site wrote them
    /// (e.g., `/mac/business/`), and our proxy re-routes them through Wayback naturally.
    private static func waybackModifier(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gif", "jpg", "jpeg", "png", "bmp", "tif", "tiff", "ico", "webp", "avif":
            return "im_"
        case "css":
            return "cs_"
        case "js":
            return "js_"
        default:
            return "id_" // Identity: raw archived content, no URL rewriting
        }
    }
    
    /// Check if a URL is already a Wayback Machine URL.
    public func isWaybackURL(_ url: URL) -> Bool {
        return url.host == "web.archive.org"
    }
    
    /// Clean Wayback Machine's injected content from an HTML response.
    ///
    /// With `id_` modifier, Wayback serves raw archived content without URL
    /// rewriting — so we only need to strip the injected toolbar/scripts.
    /// The URL cleaning below is a safety net for edge cases only.
    public func cleanWaybackResponse(_ html: String) throws -> String {
        // Phase 1: Strip Wayback toolbar via comment markers (most reliable).
        // The Wayback Machine wraps its injected toolbar/scripts between known
        // HTML comment markers that are stable across years — much more reliable
        // than CSS selectors which change with every Wayback Machine redesign.
        var cleaned = html
        let markerPairs: [(String, String)] = [
            ("<!-- BEGIN WAYBACK TOOLBAR INSERT -->", "<!-- END WAYBACK TOOLBAR INSERT -->"),
            ("<!-- BEGIN INCLUDED RESOURCES -->", "<!-- END INCLUDED RESOURCES -->"),
        ]
        for (beginMarker, endMarker) in markerPairs {
            while let startRange = cleaned.range(of: beginMarker),
                  let endRange = cleaned.range(of: endMarker, range: startRange.lowerBound..<cleaned.endIndex) {
                cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            }
        }

        // Phase 2: CSS selector-based removal (catches anything markers missed).
        let doc = try SwiftSoup.parse(cleaned)

        // Remove Wayback Machine toolbar, scripts, and stylesheets.
        // Even with id_ modifier, Wayback sometimes injects these.
        let selectorsToRemove = [
            "#wm-iana-bar",
            "#donato",
            "#wm-btns",
            "#wm-credit",
            "#wm-ipp-base",
            "#wm-ipp-print",
            "#wm-ipp",
            ".wb-autocomplete-suggestions",
            "[id^=wm-]",
            "script[src*='archive.org']",
            "link[href*='archive.org']",
            "link[href*='web-static.archive.org']",
            "style[data-original-href]",
        ]

        for selector in selectorsToRemove {
            do {
                try doc.select(selector).remove()
            } catch {
                continue
            }
        }

        // NOTE: We intentionally preserve Akamai CDN URLs (a772.g.akamai.net/...).
        // The Wayback Machine crawled and indexed these CDN URLs directly, so they
        // resolve correctly when the browser requests them through our proxy.
        // Converting them to origin URLs (www.apple.com/...) breaks image loading
        // because the origin URLs were often NOT archived separately.

        let urlAttributes = ["href", "src", "action", "background", "data", "codebase", "longdesc", "usemap"]

        // Safety net: clean any residual Wayback URLs that might appear.
        for attr in urlAttributes {
            for el in try doc.select("[\(attr)]") {
                if let value = try? el.attr(attr), value.contains("/web/") {
                    try el.attr(attr, cleanWaybackHref(value))
                }
            }
        }

        // Clean <meta http-equiv="refresh"> redirect URLs (safety net)
        for meta in try doc.select("meta[http-equiv=refresh]") {
            if let content = try? meta.attr("content"), content.contains("/web/") {
                let cleaned = cleanWaybackMetaRefresh(content)
                try meta.attr("content", cleaned)
            }
        }

        // Clean inline style url() references (safety net)
        for el in try doc.select("[style]") {
            if let style = try? el.attr("style"), style.contains("/web/") {
                try el.attr("style", cleanWaybackStyleURLs(style))
            }
        }

        logger.debug("Cleaned Wayback Machine injection from response")
        var html = try doc.outerHtml()

        // Final regex sweep: catch any remaining /web/DIGITS/http:// patterns
        if let regex = try? NSRegularExpression(
            pattern: #"(?:https?://web\.archive\.org)?/web/\d+\w*/(https?://)"#
        ) {
            html = regex.stringByReplacingMatches(
                in: html,
                range: NSRange(html.startIndex..., in: html),
                withTemplate: "$1"
            )
        }

        return html
    }
    
    /// Clean a <meta http-equiv="refresh"> content value.
    /// Input:  "0;url=/web/19991128184310/http://www.microsoft.com/mac/"
    /// Output: "0;url=http://www.microsoft.com/mac/"
    private func cleanWaybackMetaRefresh(_ content: String) -> String {
        // Pattern: number;url=WAYBACK_URL
        let pattern = #"(\d+\s*;\s*url\s*=\s*)(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let prefixRange = Range(match.range(at: 1), in: content),
              let urlRange = Range(match.range(at: 2), in: content) else {
            return content
        }
        let prefix = String(content[prefixRange])
        let url = String(content[urlRange])
        return prefix + cleanWaybackHref(url)
    }

    /// Clean Wayback URLs inside CSS url() references.
    /// Input:  "background: url(/web/19991128im_/http://site.com/bg.gif)"
    /// Output: "background: url(http://site.com/bg.gif)"
    private func cleanWaybackStyleURLs(_ style: String) -> String {
        let pattern = #"url\(\s*['""]?([^)'"]+)['""]?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return style }
        var result = style
        // Process matches in reverse order so ranges stay valid
        let matches = regex.matches(in: style, range: NSRange(style.startIndex..., in: style))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let urlRange = Range(match.range(at: 1), in: result) else { continue }
            let url = String(result[urlRange])
            if url.contains("/web/") {
                let cleaned = cleanWaybackHref(url)
                result.replaceSubrange(fullRange, with: "url(\(cleaned))")
            }
        }
        return result
    }

    /// Strip Wayback Machine URL wrapping so links point to original URLs
    /// (which our proxy will re-wayback on the next request).
    /// Handles both relative (/web/YYYYMMDD/...) and absolute (https://web.archive.org/web/YYYYMMDD/...) forms.
    /// Also handles the "im_" suffix used for image URLs.
    /// Rewrite Akamai CDN URLs to origin URLs.
    /// Pattern: http://a{N}.g.akamai.net/{N}/{N}/{N}/{hex_hash}/{origin_host}/{path}
    /// Example: http://a772.g.akamai.net/7/772/51/c5b2218232a27a/www.apple.com/t/us/en/i/1.gif
    ///        → http://www.apple.com/t/us/en/i/1.gif
    public static func cleanAkamaiURL(_ url: String) -> String? {
        // Match Akamai CDN URL pattern and capture the origin host + path
        let pattern = #"https?://a\d+\.g\.akamai\.net/\d+/\d+/\d+/[a-f0-9]+/([\w.-]+\.\w{2,}/.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let captureRange = Range(match.range(at: 1), in: url) else {
            return nil
        }
        return "http://\(url[captureRange])"
    }

    private func cleanWaybackHref(_ href: String) -> String {
        // Match Wayback URLs in all forms:
        //   https://web.archive.org/web/19990508im_/http://apple.com/...  → http://apple.com/...
        //   //web.archive.org/web/19990508/http://apple.com/...           → http://apple.com/...
        //   /web/19990508cs_/http://apple.com/style.css                   → http://apple.com/style.css
        //   /web/19990508im_/images/foo.gif                               → /images/foo.gif
        // The \w* after digits covers suffixes like "im_", "cs_", "js_", etc.
        let pattern = #"(?:https?://web\.archive\.org|//web\.archive\.org)?/web/\d+\w*/(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
              let captureRange = Range(match.range(at: 1), in: href) else {
            return href
        }
        let captured = String(href[captureRange])
        // Absolute URL — return as-is
        if captured.hasPrefix("http://") || captured.hasPrefix("https://") {
            return captured
        }
        // Relative path from the Wayback Machine — make server-relative
        if captured.hasPrefix("/") {
            return captured
        }
        return "/" + captured
    }
    
    // MARK: - Wayback Machine API
    
    /// Check if a URL is available in the Wayback Machine for the target date.
    /// Uses the Availability API: https://archive.org/wayback/available?url=X&timestamp=Y
    public func checkAvailability(for url: URL) async throws -> WaybackSnapshot? {
        let apiURL = URL(string: "https://archive.org/wayback/available?url=\(url.absoluteString)&timestamp=\(dateStamp)")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)

        let response = try JSONDecoder().decode(WaybackAvailabilityResponse.self, from: data)
        return response.archivedSnapshots.closest
    }

    /// Find nearby snapshots using the CDX API.
    /// Returns up to `limit` snapshots sorted by proximity to the target date.
    public func findNearbySnapshots(for url: URL, limit: Int = 5) async -> [(timestamp: String, dateLabel: String)] {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        // Request more rows than needed to account for deduplication by day
        let fetchLimit = limit * 4
        guard let cdxURL = URL(string: "https://web.archive.org/cdx/search/cdx?url=\(encoded)&output=json&limit=\(fetchLimit)&closest=\(dateStamp)&sort=closest") else {
            return []
        }
        var cdxRequest = URLRequest(url: cdxURL)
        cdxRequest.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: cdxRequest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String]] else {
            return []
        }
        // CDX rows: [urlkey, timestamp, original, mimetype, statuscode, digest, length]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        let display = DateFormatter()
        display.dateStyle = .long
        display.locale = Locale(identifier: "en_US")

        var seen = Set<String>()
        var results: [(timestamp: String, dateLabel: String)] = []
        for row in json.dropFirst() {
            guard row.count >= 3 else { continue }
            let ts = row[1]
            let day = String(ts.prefix(8))
            guard seen.insert(day).inserted else { continue }
            let label: String
            if let d = formatter.date(from: ts) {
                label = display.string(from: d)
            } else {
                label = ts
            }
            results.append((timestamp: day, dateLabel: label))
            if results.count >= limit { break }
        }
        return results
    }
}

// MARK: - API Models

public struct WaybackAvailabilityResponse: Codable {
    public let archivedSnapshots: ArchivedSnapshots
    
    enum CodingKeys: String, CodingKey {
        case archivedSnapshots = "archived_snapshots"
    }
}

public struct ArchivedSnapshots: Codable {
    public let closest: WaybackSnapshot?
}

public struct WaybackSnapshot: Codable {
    public let status: String
    public let available: Bool
    public let url: String
    public let timestamp: String
}
