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
    /// e.g., `http://apple.com` → `https://web.archive.org/web/19970101/http://apple.com`
    public func rewriteURL(_ originalURL: URL) -> URL {
        let waybackURL = "\(waybackBase)/\(dateStamp)/\(originalURL.absoluteString)"
        return URL(string: waybackURL) ?? originalURL
    }
    
    /// Check if a URL is already a Wayback Machine URL.
    public func isWaybackURL(_ url: URL) -> Bool {
        return url.host == "web.archive.org"
    }
    
    /// Clean Wayback Machine's injected content from an HTML response.
    /// The Wayback Machine injects a toolbar (`<div id="wm-iana-bar">`) and
    /// several scripts into every archived page. We strip all of that.
    public func cleanWaybackResponse(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        
        // Remove Wayback Machine toolbar and related elements
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
            "style[data-original-href]",
        ]
        
        for selector in selectorsToRemove {
            do {
                try doc.select(selector).remove()
            } catch {
                // Selector might not match — that's fine
                continue
            }
        }
        
        // Rewrite all URLs (links, images, CSS) so they go through
        // the proxy as plain http:// instead of https://web.archive.org/...
        for link in try doc.select("a[href]") {
            if let href = try? link.attr("href") {
                try link.attr("href", cleanWaybackHref(href))
            }
        }
        for img in try doc.select("img[src]") {
            if let src = try? img.attr("src") {
                try img.attr("src", cleanWaybackHref(src))
            }
        }
        for link in try doc.select("link[href]") {
            if let href = try? link.attr("href") {
                try link.attr("href", cleanWaybackHref(href))
            }
        }
        for el in try doc.select("[background]") {
            if let bg = try? el.attr("background") {
                try el.attr("background", cleanWaybackHref(bg))
            }
        }

        logger.debug("Cleaned Wayback Machine injection from response")
        return try doc.outerHtml()
    }
    
    /// Strip Wayback Machine URL wrapping so links point to original URLs
    /// (which our proxy will re-wayback on the next request).
    /// Handles both relative (/web/YYYYMMDD/...) and absolute (https://web.archive.org/web/YYYYMMDD/...) forms.
    /// Also handles the "im_" suffix used for image URLs.
    private func cleanWaybackHref(_ href: String) -> String {
        // Match: https://web.archive.org/web/YYYYMMDDHHMMSSim_/http://...
        // or:    /web/YYYYMMDDHHMMSSim_/http://...
        // The \w* after digits covers suffixes like "im_", "cs_", "js_", etc.
        let pattern = #"(?:https?://web\.archive\.org)?/web/\d+\w*/(https?://.*)"#
        if let range = href.range(of: pattern, options: .regularExpression) {
            // Extract the original URL (the captured group)
            let innerPattern = #"(https?://(?!web\.archive\.org).*)"#
            if let captureRange = href.range(of: innerPattern, options: .regularExpression, range: range) {
                return String(href[captureRange])
            }
        }
        return href
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
