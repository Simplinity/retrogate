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
        
        // Rewrite archived asset URLs back to their Wayback versions
        // (so images and CSS still load through our proxy)
        for link in try doc.select("a[href]") {
            if let href = try? link.attr("href") {
                let cleaned = cleanWaybackHref(href)
                try link.attr("href", cleaned)
            }
        }
        
        logger.debug("Cleaned Wayback Machine injection from response")
        return try doc.outerHtml()
    }
    
    /// Strip the `/web/YYYYMMDD*/` prefix from Wayback-rewritten hrefs
    /// so links point to original URLs (which our proxy will re-wayback).
    private func cleanWaybackHref(_ href: String) -> String {
        // Wayback rewrites links like: /web/20010101/http://example.com/page
        // We want to extract: http://example.com/page
        let pattern = #"/web/\d+\*?/(https?://.*)"#
        if let range = href.range(of: pattern, options: .regularExpression),
           let captureRange = href.range(of: #"https?://.*"#, options: .regularExpression, range: range) {
            return String(href[captureRange])
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
