import Foundation
import CryptoKit
import NIOConcurrencyHelpers
import Logging
#if canImport(WaybackBridge)
import WaybackBridge
#endif

/// Rate-limited engine that bulk-fetches a list of URLs into the response cache.
///
/// Used by the Prefetch feature: the user pastes a list of URLs, we fetch each one
/// via archive.org (respecting a 1 req/sec throttle so we don't get banned), and
/// cache the bytes. Next time the user browses any of these URLs, they load instantly.
///
/// Fetch shortcut: we don't go through the full ProxyHandler pipeline, so no HTML
/// transcoding or image conversion happens during prefetch — we only capture the
/// raw bytes exactly as archive.org returned them. The processing happens lazily
/// when the browser actually requests the page.
public actor CacheWarmer {
    public struct Progress: Sendable {
        public let total: Int
        public let completed: Int
        public let cached: Int       // already-in-cache hits
        public let succeeded: Int    // fresh fetches
        public let failed: Int
        public let current: String?  // URL currently being fetched (nil when done)
        public let isCancelled: Bool
        public let succeededKeys: [String]  // cache keys of successful fetches

        public var isFinished: Bool { completed >= total }
    }

    private let responseCache: ResponseCache
    private let session: URLSession
    private let logger: Logger
    private var cancelled = false

    public init(responseCache: ResponseCache, logger: Logger? = nil) {
        self.responseCache = responseCache
        var log = logger ?? Logger(label: "app.retrogate.warmer")
        log.logLevel = .info
        self.logger = log

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    public func cancel() { cancelled = true }

    /// Fetch each URL in order, reporting progress after every item.
    /// Respects `rateLimit` seconds of spacing between archive.org hits
    /// (skipped for items already in cache).
    public func warm(
        urls: [URL],
        waybackDate: Date,
        rateLimit: TimeInterval = 1.0,
        onProgress: @Sendable @escaping (Progress) async -> Void
    ) async {
        cancelled = false
        let bridge = WaybackBridge(targetDate: waybackDate)
        var completed = 0, cached = 0, succeeded = 0, failed = 0
        var succeededKeys: [String] = []

        // Seed progress so the UI shows 0/total right away.
        await onProgress(Progress(
            total: urls.count,
            completed: 0, cached: 0, succeeded: 0, failed: 0,
            current: urls.first?.absoluteString,
            isCancelled: false,
            succeededKeys: []
        ))

        for url in urls {
            if cancelled { break }
            let fetchURL = bridge.rewriteURL(url)
            let lookupURL = fetchURL.absoluteString

            // Skip if already cached — no network, no throttle cost.
            if responseCache.get(url: lookupURL) != nil {
                cached += 1
                completed += 1
                await onProgress(Progress(
                    total: urls.count, completed: completed,
                    cached: cached, succeeded: succeeded, failed: failed,
                    current: completed < urls.count ? urls[completed].absoluteString : nil,
                    isCancelled: false,
                    succeededKeys: succeededKeys
                ))
                continue
            }

            // Fresh fetch from archive.org.
            var request = URLRequest(url: fetchURL)
            request.timeoutInterval = 30
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            if let host = fetchURL.host {
                request.setValue(host, forHTTPHeaderField: "Host")
            }

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   http.statusCode >= 200, http.statusCode < 400,
                   let ct = http.value(forHTTPHeaderField: "Content-Type") {
                    let resolved = ProxyHTTPHandler.extractWaybackTimestamp(from: http.url?.absoluteString)
                        ?? ProxyHTTPHandler.formatWaybackStamp(waybackDate)
                    responseCache.set(
                        url: lookupURL,
                        data: data,
                        contentType: ct,
                        originalURL: url.absoluteString,
                        waybackDate: resolved
                    )
                    succeeded += 1
                    succeededKeys.append(cacheKey(fetchURL))
                } else {
                    failed += 1
                    logger.debug("Prefetch \(url.absoluteString): non-2xx from archive.org")
                }
            } catch {
                failed += 1
                logger.debug("Prefetch \(url.absoluteString) failed: \(error.localizedDescription)")
            }

            completed += 1
            await onProgress(Progress(
                total: urls.count, completed: completed,
                cached: cached, succeeded: succeeded, failed: failed,
                current: completed < urls.count ? urls[completed].absoluteString : nil,
                isCancelled: false,
                succeededKeys: succeededKeys
            ))

            // Rate limit only after a real network hit (cache hits were instant).
            if !cancelled && completed < urls.count {
                let ns = UInt64(max(0, rateLimit) * 1_000_000_000)
                if ns > 0 { try? await Task.sleep(nanoseconds: ns) }
            }
        }

        // Final progress with cancellation flag so UI can react.
        await onProgress(Progress(
            total: urls.count, completed: completed,
            cached: cached, succeeded: succeeded, failed: failed,
            current: nil,
            isCancelled: cancelled,
            succeededKeys: succeededKeys
        ))
    }

    /// Parse a user-pasted list: one URL per line, trimmed, blank/comment lines skipped.
    /// Returns the parseable URLs and a count of lines that couldn't be turned into URLs.
    public nonisolated static func parseURLList(_ text: String) -> (urls: [URL], rejected: Int) {
        var urls: [URL] = []
        var rejected = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Accept bare hostnames by adding http:// prefix
            if !line.contains("://") { line = "http://" + line }
            if let url = URL(string: line), url.scheme != nil, url.host != nil {
                urls.append(url)
            } else {
                rejected += 1
            }
        }
        return (urls, rejected)
    }

    // Internal helper mirroring ResponseCache's SHA-256-prefix key derivation,
    // so we can look up the just-inserted entry by the same key.
    /// Mirror of ResponseCache's SHA-256-prefix key scheme so we can look up
    /// the just-inserted entry. Kept local to avoid widening ResponseCache's API.
    private nonisolated func cacheKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
