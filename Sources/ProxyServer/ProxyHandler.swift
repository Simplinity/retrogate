import NIO
import NIOHTTP1
import Logging
import Foundation
import HTMLTranscoder
import ImageTranscoder
import WaybackBridge
import SwiftSoup

/// Handles incoming HTTP proxy requests from vintage browsers.
///
/// Classic proxy flow:
/// 1. Old browser sends: `GET http://example.com/path HTTP/1.0`
/// 2. We fetch https://example.com/path using URLSession (modern TLS)
/// 3. We transcode the HTML, convert images
/// 4. We return simplified HTTP/1.0 response
final class ProxyHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private let sharedConfig: SharedConfiguration
    private let temporalCache: TemporalCache
    private let redirectTracker: RedirectTracker
    private let responseCache: ResponseCache
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    private static let maxResponseSize = 10 * 1024 * 1024 // 10 MB

    /// Ephemeral URLSession — no shared cookie jar, no persistent cache.
    /// Prevents cookies from site A leaking into requests for site B,
    /// and archive.org cookies mixing with live site cookies.
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false  // Don't auto-attach cookies
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// 1×1 transparent GIF — returned for missing archived images
    private static let transparentGIF = Data([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00,
        0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x21,
        0xF9, 0x04, 0x01, 0x00, 0x00, 0x01, 0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C,
        0x01, 0x00, 0x3B
    ])

    init(logger: Logger, sharedConfig: SharedConfiguration, temporalCache: TemporalCache, redirectTracker: RedirectTracker, responseCache: ResponseCache) {
        self.logger = logger
        self.sharedConfig = sharedConfig
        self.temporalCache = temporalCache
        self.redirectTracker = redirectTracker
        self.responseCache = responseCache
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            logger.info("\(head.method) \(head.uri)")

        case .body(var body):
            if requestBody == nil {
                requestBody = body
            } else {
                requestBody?.writeBuffer(&body)
            }

        case .end:
            guard let head = requestHead else { return }
            handleProxyRequest(context: context, head: head)
            requestHead = nil
            requestBody = nil
        }
    }

    private func handleProxyRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard var originalURL = URL(string: head.uri) else {
            sendError(context: context, status: .badRequest, message: "Invalid URL")
            return
        }

        // Intercept requests to http://retrogate/... — our virtual host for
        // built-in pages (start page, search gateway, PAC file, etc.)
        if originalURL.host?.lowercased() == "retrogate" {
            let config = self.sharedConfig.value
            handleRetroGateVirtualHost(context: context, head: head, url: originalURL, config: config)
            return
        }

        // NOTE: We intentionally do NOT rewrite Akamai CDN URLs to origin URLs.
        // Apple (and other sites) served everything through Akamai in the late 90s/2000s.
        // The Wayback Machine crawled and archived the CDN URLs, NOT the origin URLs.
        // Rewriting a772.g.akamai.net/.../www.apple.com/img.jpg → www.apple.com/img.jpg
        // breaks image loading because the origin URL isn't in the archive.

        // Safety net: detect leaked Wayback URLs in the request URI.
        // If the HTML cleaning missed a link, the browser sends requests like:
        //   http://www.microsoft.com/web/19991128184310/http://www.microsoft.com/mac/default.asp
        //   http://www.microsoft.com/web/19991128im_/images/logo.gif
        // Extract the real URL and route the request correctly.
        // NOTE: We match against head.uri (raw string), NOT originalURL.path,
        // because URL.path mangles embedded "://" into ":/" which breaks matching.
        do {
            let uri = head.uri
            let leakPattern = #"/web/\d+\w*/(.*)"#
            if let regex = try? NSRegularExpression(pattern: leakPattern),
               let match = regex.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
               let captureRange = Range(match.range(at: 1), in: uri) {
                let captured = String(uri[captureRange])
                if captured.hasPrefix("http://") || captured.hasPrefix("https://") {
                    // Absolute URL embedded in path — use directly
                    if let cleanedURL = URL(string: captured) {
                        logger.info("Recovered leaked Wayback URL: \(uri) → \(cleanedURL.absoluteString)")
                        originalURL = cleanedURL
                    }
                } else {
                    // Relative path — rebuild with the request's host
                    let relativePath = captured.hasPrefix("/") ? captured : "/\(captured)"
                    if let host = originalURL.host,
                       let cleanedURL = URL(string: "http://\(host)\(relativePath)") {
                        logger.info("Recovered leaked Wayback URL (relative): \(uri) → \(cleanedURL.absoluteString)")
                        originalURL = cleanedURL
                    }
                }
            }
        }

        // Snapshot config at request time so UI changes take effect immediately
        let config = self.sharedConfig.value

        // Dead endpoint redirection: if the host matches a known dead service,
        // redirect the vintage browser to a revival/archive alternative.
        if let host = originalURL.host?.lowercased(),
           let redirect = Self.resolveDeadEndpoint(host: host, config: config) {
            logger.info("Dead endpoint redirect: \(host) → \(redirect)")
            sendRedirect(context: context, location: redirect)
            return
        }

        // Redirect loop detection: if we've seen this exact URL recently,
        // it's likely an HTTP↔HTTPS bounce or a multi-site carousel.
        // Break the cycle with an error page instead of looping forever.
        if redirectTracker.recordAndCheck(url: head.uri) {
            logger.warning("Redirect loop detected for \(head.uri)")
            sendError(context: context, status: .loopDetected,
                      message: "Redirect loop detected — the same URL was requested multiple times in quick succession. This usually happens when a site redirects between HTTP and HTTPS.<br><br><b>URL:</b> \(head.uri)")
            return
        }

        // Resolve tracking redirect URLs. Two patterns:
        // 1. Bare URL as query string: io.apple.com/.click?http://real-url
        // 2. Named redirect parameters: ?redirect=http://real-url&foo=bar
        var resolvedURL = originalURL
        if let query = originalURL.query {
            let decoded = query.removingPercentEncoding ?? query
            // Pattern 1: entire query is a URL
            if (decoded.hasPrefix("http://") || decoded.hasPrefix("https://")),
               let dest = URL(string: decoded) {
                resolvedURL = dest
            }
            // Pattern 2: named redirect parameter
            else if let components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) {
                let redirectParams = ["redirect", "redir", "next", "url", "u", "dest",
                                      "destination", "forward", "return", "goto",
                                      "callback", "continue", "target", "returnUrl",
                                      "return_url", "redirect_uri", "RelayState"]
                for param in redirectParams {
                    if let value = components.queryItems?.first(where: { $0.name.lowercased() == param.lowercased() })?.value,
                       let decodedValue = value.removingPercentEncoding ?? Optional(value),
                       (decodedValue.hasPrefix("http://") || decodedValue.hasPrefix("https://")),
                       let dest = URL(string: decodedValue) {
                        resolvedURL = dest
                        break
                    }
                }
            }
        }

        // Bridge NIO → async: spawn a Task, write the response back on the event loop
        let promise = context.eventLoop.makePromise(of: Void.self)
        let logger = self.logger
        let temporalCache = self.temporalCache
        let responseCache = self.responseCache

        // Extract the browser's Accept header so the image transcoder knows
        // which formats the vintage browser supports (some only handle GIF).
        let acceptHeader = head.headers["Accept"].first ?? "*/*"

        promise.completeWithTask {
            do {
                let result: (Data, String, Int, [(String, String)], String?)

                switch config.browsingMode {
                // ── Live Web ───────────────────────────────────────────
                // Fetch from the live internet: HTTPS upgrade, cert fallback,
                // auto-Wayback-fallback for 404s. No date handling needed.
                case .liveWeb:
                    var fetchURL = resolvedURL
                    if var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
                       components.scheme == "http" {
                        components.scheme = "https"
                        fetchURL = components.url ?? resolvedURL
                    }
                    result = try await Self.fetchViaDirect(
                        fetchURL: fetchURL,
                        originalURL: resolvedURL,
                        acceptHeader: acceptHeader,
                        configuration: config,
                        temporalCache: temporalCache,
                        logger: logger
                    )

                // ── Wayback Machine ────────────────────────────────────
                // Fetch from the Internet Archive: URL rewriting, temporal
                // consistency, response caching, date drift guard.
                case .wayback(let targetDate, let toleranceMonths):
                    // Check for per-request date override (?__wb=YYYYMMDD).
                    // When present, the user explicitly chose this date (e.g., from our
                    // "Available snapshots" links), so we skip the date drift guard.
                    var waybackDate = targetDate
                    var cleanURL = resolvedURL
                    var hasExplicitDateOverride = false
                    if var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
                       let wbParam = components.queryItems?.first(where: { $0.name == "__wb" })?.value {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "yyyyMMdd"
                        if let d = fmt.date(from: wbParam) {
                            waybackDate = d
                            hasExplicitDateOverride = true
                        }
                        components.queryItems = components.queryItems?.filter { $0.name != "__wb" }
                        if components.queryItems?.isEmpty == true { components.queryItems = nil }
                        cleanURL = components.url ?? resolvedURL
                    }

                    // Temporal consistency: use the cached resolved date ONLY for sub-resources
                    // (images, CSS, JS) so they load from the same snapshot as their parent page.
                    // HTML page navigations ALWAYS use the user's configured target date to prevent
                    // cascading temporal drift (clicking links would otherwise compound date offsets,
                    // e.g. Dec 1999 → Mar 2000 → Sep 2001 as each page resolves to a different date).
                    let isSubResource = Self.isSubResourceURL(cleanURL)
                    if isSubResource,
                       let domain = cleanURL.host,
                       let cachedDateStamp = temporalCache.get(domain: domain) {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "yyyyMMdd"
                        if let cachedDate = fmt.date(from: cachedDateStamp) {
                            waybackDate = cachedDate
                            logger.debug("Using cached Wayback date \(cachedDateStamp) for sub-resource on \(domain)")
                        }
                    }

                    // Rewrite URL for Wayback Machine. Keep the original http:// URL
                    // for the archive path — sites from the 90s were HTTP-only; the
                    // Wayback Machine connection itself is HTTPS, so TLS is still used.
                    var fetchURL = cleanURL
                    let bridge = WaybackBridge(targetDate: waybackDate)
                    if !bridge.isWaybackURL(fetchURL) {
                        fetchURL = bridge.rewriteURL(fetchURL)
                    }

                    result = try await Self.fetchViaWayback(
                        fetchURL: fetchURL,
                        originalURL: cleanURL,
                        waybackDate: waybackDate,
                        toleranceMonths: toleranceMonths,
                        acceptHeader: acceptHeader,
                        configuration: config,
                        temporalCache: temporalCache,
                        responseCache: responseCache,
                        skipDriftGuard: hasExplicitDateOverride,
                        logger: logger
                    )
                }

                let (data, contentType, statusCode, extraHeaders, resolvedWaybackDate) = result

                // Log the request
                config.onRequestLogged?(RequestLogData(
                    method: String(describing: head.method),
                    url: head.uri,
                    statusCode: statusCode,
                    originalSize: data.count,
                    transcodedSize: data.count,
                    waybackDate: resolvedWaybackDate,
                    contentType: contentType
                ))

                // Write response back on the event loop
                context.eventLoop.execute {
                    self.sendResponse(context: context, data: data, contentType: contentType, statusCode: statusCode, extraHeaders: extraHeaders)
                }

                // Prefetch sub-resources for Wayback HTML pages.
                // Fires parallel background requests so images are cached
                // before the vintage browser asks for them.
                if contentType.contains("text/html"),
                   case .wayback(let targetDate, _) = config.browsingMode {
                    Self.prefetchWaybackImages(
                        htmlData: data,
                        pageURL: resolvedURL,
                        waybackDate: targetDate,
                        temporalCache: temporalCache,
                        responseCache: responseCache,
                        logger: logger
                    )
                }
            } catch {
                context.eventLoop.execute {
                    logger.error("Fetch failed for \(head.uri): \(error)")
                    self.sendError(context: context, status: .badGateway, message: "Failed to fetch: \(error.localizedDescription)")
                }
            }
        }

        promise.futureResult.whenFailure { error in
            self.sendError(context: context, status: .internalServerError, message: "Internal error: \(error.localizedDescription)")
        }
    }

    // MARK: - Wayback Machine Pipeline
    //
    // Fetches pages from the Internet Archive's Wayback Machine.
    // Handles: response caching, error detection, CDX snapshot suggestions,
    // temporal consistency, and date drift guard.
    // This code path is ONLY active when browsingMode == .wayback.

    private static func fetchViaWayback(
        fetchURL: URL,
        originalURL: URL,
        waybackDate: Date,
        toleranceMonths: Int,
        acceptHeader: String,
        configuration: ProxyConfiguration,
        temporalCache: TemporalCache,
        responseCache: ResponseCache,
        skipDriftGuard: Bool,
        logger: Logger
    ) async throws -> (Data, String, Int, [(String, String)], String?) {
        var request = URLRequest(url: fetchURL)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let host = fetchURL.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        // Block redirects that leave archive.org — prevents fetching live sites
        // which may have cert errors or serve modern HTML.
        let delegate = WaybackRedirectGuard()

        // Check cache — archived content is immutable, so we can cache indefinitely.
        let cacheKey = fetchURL.absoluteString
        let data: Data
        let response: URLResponse
        if let cached = responseCache.get(url: cacheKey) {
            logger.debug("Wayback cache hit: \(originalURL.absoluteString)")
            data = cached.data
            response = HTTPURLResponse(
                url: fetchURL, statusCode: 200,
                httpVersion: "HTTP/1.0",
                headerFields: ["Content-Type": cached.contentType]
            )!
        } else {
            // Fetch with retry + exponential backoff (archive.org is unreliable).
            let (fetchedData, fetchedResponse) = try await Self.fetchWithRetry(
                request: request, delegate: delegate,
                retryOn502: true, fetchURL: fetchURL, logger: logger
            )
            data = fetchedData
            response = fetchedResponse

            // Cache successful responses
            if let httpResp = fetchedResponse as? HTTPURLResponse,
               httpResp.statusCode >= 200 && httpResp.statusCode < 400,
               let ct = httpResp.value(forHTTPHeaderField: "Content-Type") {
                responseCache.set(url: cacheKey, data: fetchedData, contentType: ct)
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.notHTTP
        }

        // Size limit
        if data.count > maxResponseSize {
            let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.contains("text/html") {
                return (Self.errorPage("Page Too Large",
                    "The page <b>\(originalURL.absoluteString)</b> is \(data.count / 1024 / 1024) MB."),
                    "text/html; charset=iso-8859-1", 200, [], nil)
            }
        }

        // Detect Wayback Machine error pages (404, redirect away from archive).
        if Self.isWaybackErrorResponse(httpResponse, data: data) {
            let bridge = WaybackBridge(targetDate: waybackDate)
            let snapshots = await bridge.findNearbySnapshots(for: originalURL)
            let linksHTML = Self.snapshotLinksHTML(snapshots, originalURL: originalURL)
            return (Self.errorPage("Page Not Archived",
                "The Wayback Machine does not have <b>\(originalURL.absoluteString)</b> for your chosen date.\(linksHTML)"),
                "text/html; charset=iso-8859-1", 404, [], nil)
        }

        // Temporal consistency: extract resolved snapshot date, cache for sub-resources.
        var resolvedWaybackDate: String? = nil
        if let finalURL = httpResponse.url?.absoluteString,
           let domain = originalURL.host {
            let tsPattern = #"/web/(\d{4,14})\w*/"#
            if let regex = try? NSRegularExpression(pattern: tsPattern),
               let match = regex.firstMatch(in: finalURL, range: NSRange(finalURL.startIndex..., in: finalURL)),
               let range = Range(match.range(at: 1), in: finalURL) {
                let resolvedStamp = String(String(finalURL[range]).prefix(8))
                resolvedWaybackDate = resolvedStamp
                temporalCache.set(domain: domain, dateStamp: resolvedStamp)
            }
        }

        // Date drift guard: reject snapshots too far from the target date.
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        if !skipDriftGuard,
           toleranceMonths > 0,
           contentType.contains("text/html"),
           !Self.isSubResourceURL(originalURL),
           let stamp = resolvedWaybackDate {
            if let driftError = Self.checkDateDrift(
                stamp: stamp, targetDate: waybackDate,
                toleranceMonths: toleranceMonths,
                originalURL: originalURL
            ) {
                return (driftError, "text/html; charset=iso-8859-1", 404, [], stamp)
            }
        }

        // Process content (shared with live-web pipeline)
        return try processContent(
            data: data, contentType: contentType, statusCode: httpResponse.statusCode,
            originalURL: originalURL, acceptHeader: acceptHeader,
            configuration: configuration, resolvedWaybackDate: resolvedWaybackDate,
            httpResponse: httpResponse, logger: logger
        )
    }

    // MARK: - Live Web Pipeline
    //
    // Fetches pages from the live internet via HTTPS.
    // Handles: HTTPS upgrade, certificate fallback, 404→Wayback fallback.
    // This code path is ONLY active when browsingMode == .liveWeb.

    private static func fetchViaDirect(
        fetchURL: URL,
        originalURL: URL,
        acceptHeader: String,
        configuration: ProxyConfiguration,
        temporalCache: TemporalCache,
        logger: Logger
    ) async throws -> (Data, String, Int, [(String, String)], String?) {
        var request = URLRequest(url: fetchURL)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let host = fetchURL.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        // Fetch with HTTPS cert fallback (no redirect guard, no 502 retry).
        let (data, response) = try await Self.fetchWithRetry(
            request: request, delegate: nil,
            retryOn502: false, fetchURL: fetchURL, logger: logger
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.notHTTP
        }

        // Size limit
        if data.count > maxResponseSize {
            let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.contains("text/html") {
                return (Self.errorPage("Page Too Large",
                    "The page <b>\(originalURL.absoluteString)</b> is \(data.count / 1024 / 1024) MB."),
                    "text/html; charset=iso-8859-1", 200, [], nil)
            }
        }

        var statusCode = httpResponse.statusCode
        var contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        var responseData = data
        var resolvedWaybackDate: String? = nil

        // Automatic Wayback fallback: if the live site returns 403/404/410/451,
        // silently try the Wayback Machine. Huge swathes of the old web are gone
        // but archived — this recovers them without the user enabling Wayback mode.
        let goneStatuses: Set<Int> = [403, 404, 410, 451]
        if goneStatuses.contains(statusCode) && contentType.contains("text/html") {
            logger.info("Live site returned \(statusCode) for \(originalURL) — trying Wayback")
            let bridge = WaybackBridge()  // Use latest available snapshot
            let waybackURL = bridge.rewriteURL(originalURL)
            var wbRequest = URLRequest(url: waybackURL)
            wbRequest.timeoutInterval = 15
            wbRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

            if let (wbData, wbResponse) = try? await Self.urlSession.data(for: wbRequest, delegate: WaybackRedirectGuard()),
               let wbHTTP = wbResponse as? HTTPURLResponse,
               wbHTTP.statusCode >= 200 && wbHTTP.statusCode < 400,
               let wbFinalURL = wbHTTP.url?.absoluteString,
               wbFinalURL.contains("/web/") {
                responseData = wbData
                statusCode = 200
                contentType = wbHTTP.value(forHTTPHeaderField: "Content-Type") ?? "text/html"
                if let domain = originalURL.host {
                    resolvedWaybackDate = Self.extractWaybackTimestamp(from: wbFinalURL)
                    if let stamp = resolvedWaybackDate {
                        temporalCache.set(domain: domain, dateStamp: stamp)
                    }
                }
            } else {
                // Both live and Wayback failed — show clean error
                return (Self.errorPage("\(statusCode) — Page Not Found",
                    """
                    The page <b>\(originalURL.absoluteString)</b> could not be found on the live web.
                    <p>The Wayback Machine was also checked but does not have an archived copy.</p>
                    <p><b>Suggestions:</b></p>
                    <ul>
                    <li>Check the URL for typos</li>
                    <li>Try the site's home page: <a href="http://\(originalURL.host ?? "")">\(originalURL.host ?? "")</a></li>
                    <li>Enable Wayback Mode in RetroGate to browse archived versions</li>
                    </ul>
                    """),
                    "text/html; charset=iso-8859-1", 404, [], nil)
            }
        }

        // Process content (shared with Wayback pipeline)
        return try processContent(
            data: responseData, contentType: contentType, statusCode: statusCode,
            originalURL: originalURL, acceptHeader: acceptHeader,
            configuration: configuration, resolvedWaybackDate: resolvedWaybackDate,
            httpResponse: httpResponse, logger: logger
        )
    }

    // MARK: - Shared Content Processing
    //
    // Content transcoding and format conversion shared by both pipelines.
    // This is where HTML→3.2 downgrade, image transcoding, encoding,
    // and cookie handling happen — identical for Wayback and live web.

    private static func processContent(
        data: Data,
        contentType: String,
        statusCode: Int,
        originalURL: URL,
        acceptHeader: String,
        configuration: ProxyConfiguration,
        resolvedWaybackDate: String?,
        httpResponse: HTTPURLResponse,
        logger: Logger
    ) throws -> (Data, String, Int, [(String, String)], String?) {
        // Extract and clean Set-Cookie headers (strip Secure/SameSite for HTTP proxy)
        let cookies = Self.extractCookies(from: httpResponse)

        // If a request for an image came back as HTML (error page) or with
        // an error status, return a 1×1 transparent GIF to preserve layout.
        let imageExtensions = [".gif", ".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".svg"]
        let looksLikeImage = imageExtensions.contains(where: { originalURL.path.lowercased().hasSuffix($0) })
        if looksLikeImage && (contentType.contains("text/html") || statusCode >= 400) {
            return (Self.transparentGIF, "image/gif", 200, [], resolvedWaybackDate)
        }

        // Route by content type
        if contentType.contains("text/html") {
            // Content needs Wayback cleanup if it actually came from the archive
            // (regardless of whether we're in Wayback mode — the live web pipeline
            // can also fall back to Wayback for 404 pages).
            let isWaybackContent = resolvedWaybackDate != nil

            let bypassTranscoding = Self.shouldBypassTranscoding(
                url: originalURL, bypassDomains: configuration.transcodingBypassDomains
            )
            let transcoded = bypassTranscoding
                ? try transcodeHTMLMinimal(data: data, originalURL: originalURL, configuration: configuration, isWaybackContent: isWaybackContent, logger: logger)
                : try transcodeHTML(data: data, originalURL: originalURL, configuration: configuration, isWaybackContent: isWaybackContent, logger: logger)
            return (transcoded, "text/html; charset=\(configuration.outputEncoding.charsetLabel)", statusCode, cookies, resolvedWaybackDate)

        } else if contentType.starts(with: "image/") {
            let (imageData, mimeType) = transcodeImage(data: data, acceptHeader: acceptHeader, configuration: configuration, logger: logger)
            return (imageData, mimeType, statusCode, cookies, resolvedWaybackDate)

        } else if contentType.contains("text/") || contentType.contains("javascript") || contentType.contains("json") {
            if var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: configuration.outputEncoding.swiftEncoding) {
                text = text.replacingOccurrences(of: "https://", with: "http://")
                if contentType.contains("css") {
                    if configuration.transcodingLevel == .minimal {
                        text = HTMLTranscoder.prefixCSS(text)
                    }
                    if let fontFaceRegex = try? NSRegularExpression(pattern: #"@font-face\s*\{[^}]*\}"#, options: .dotMatchesLineSeparators) {
                        text = fontFaceRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                    }
                }
                let encoded = text.data(using: configuration.outputEncoding.swiftEncoding, allowLossyConversion: true) ?? Data(text.utf8)
                return (encoded, contentType, statusCode, cookies, resolvedWaybackDate)
            }
            return (data, contentType, statusCode, cookies, resolvedWaybackDate)

        } else {
            return (data, contentType, statusCode, cookies, resolvedWaybackDate)
        }
    }

    // MARK: - Pipeline Helpers

    /// Detect if a Wayback Machine response is an error (404, redirect away from archive).
    private static func isWaybackErrorResponse(_ response: HTTPURLResponse, data: Data) -> Bool {
        if let finalURL = response.url?.absoluteString, finalURL.contains("/web/") {
            if let html = String(data: data.prefix(2000), encoding: .utf8),
               html.contains("<title>Wayback Machine</title>") || html.contains("<title>Internet Archive") {
                return true
            }
            return false
        }
        return true
    }

    /// Extract YYYYMMDD timestamp from a Wayback Machine URL.
    private static func extractWaybackTimestamp(from url: String) -> String? {
        let tsPattern = #"/web/(\d{4,14})\w*/"#
        guard let regex = try? NSRegularExpression(pattern: tsPattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else { return nil }
        return String(String(url[range]).prefix(8))
    }

    /// Check if a resolved Wayback date drifts too far from the target. Returns error HTML or nil.
    private static func checkDateDrift(stamp: String, targetDate: Date, toleranceMonths: Int, originalURL: URL) -> Data? {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyyMMdd"
        guard let resolvedDate = dateFmt.date(from: stamp) else { return nil }
        let calendar = Calendar.current
        let monthsDiff = abs(calendar.dateComponents([.month], from: calendar.startOfDay(for: targetDate), to: calendar.startOfDay(for: resolvedDate)).month ?? 0)
        guard monthsDiff > toleranceMonths else { return nil }
        let daysDiff = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: targetDate), to: calendar.startOfDay(for: resolvedDate)).day ?? 0)
        let targetLabel = readableDateLabel(targetDate)
        let actualLabel = readableDateLabel(resolvedDate)
        // CDX lookup is async but we're in a sync context — return without snapshots for now
        return errorPage("Snapshot Too Far From Target Date",
            """
            You asked for <b>\(originalURL.absoluteString)</b> around <b>\(targetLabel)</b>,
            but the closest snapshot is from <b>\(actualLabel)</b> (\(daysDiff) days away).
            <p>Adjust date tolerance in RetroGate settings, or try a different date.</p>
            """)
    }

    /// Build "Available snapshots" links HTML from CDX results.
    private static func snapshotLinksHTML(_ snapshots: [(timestamp: String, dateLabel: String)], originalURL: URL) -> String {
        guard !snapshots.isEmpty else { return "" }
        var html = "<p><b>Available snapshots:</b></p><ul>"
        for snap in snapshots {
            let linkURL = originalURL.query != nil
                ? "\(originalURL.absoluteString)&__wb=\(snap.timestamp)"
                : "\(originalURL.absoluteString)?__wb=\(snap.timestamp)"
            html += "<li><a href=\"\(linkURL)\">\(snap.dateLabel)</a></li>"
        }
        return html + "</ul>"
    }

    /// Build a standard RetroGate error page.
    private static func errorPage(_ title: String, _ body: String) -> Data {
        let html = """
        <html><body bgcolor="#FFFFFF">
        <h2>\(title)</h2>
        \(body)
        <hr><p><i>RetroGate Proxy</i></p>
        </body></html>
        """
        return html.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(html.utf8)
    }

    /// Extract and clean Set-Cookie headers from an HTTP response.
    private static func extractCookies(from httpResponse: HTTPURLResponse) -> [(String, String)] {
        guard let headerFields = httpResponse.allHeaderFields as? [String: String],
              let merged = headerFields.first(where: { $0.key.lowercased() == "set-cookie" })?.value else { return [] }
        let splitPattern = #",\s+(?=[A-Za-z0-9_]+=)"#
        let parts: [String]
        if let regex = try? NSRegularExpression(pattern: splitPattern) {
            var result: [String] = []
            var lastEnd = merged.startIndex
            for match in regex.matches(in: merged, range: NSRange(merged.startIndex..., in: merged)) {
                if let range = Range(match.range, in: merged) {
                    result.append(String(merged[lastEnd..<range.lowerBound]))
                    lastEnd = range.upperBound
                }
            }
            result.append(String(merged[lastEnd...]))
            parts = result
        } else {
            parts = [merged]
        }
        return parts.map { cookie in
            let stripped = cookie
                .replacingOccurrences(of: " Secure;", with: "")
                .replacingOccurrences(of: " Secure", with: "")
                .replacingOccurrences(of: "; SameSite=None", with: "")
                .replacingOccurrences(of: "; SameSite=Lax", with: "")
                .replacingOccurrences(of: "; SameSite=Strict", with: "")
            return ("Set-Cookie", stripped)
        }
    }

    private static func transcodeHTML(
        data: Data,
        originalURL: URL,
        configuration: ProxyConfiguration,
        isWaybackContent: Bool,
        logger: Logger
    ) throws -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }

        // Clean Wayback Machine toolbar/scripts if content came from the archive.
        // This is content-aware, not mode-aware — the live web pipeline's auto-
        // Wayback-fallback also needs cleanup when it serves archived pages.
        if isWaybackContent {
            let bridge = WaybackBridge()
            html = (try? bridge.cleanWaybackResponse(html)) ?? html
        }

        // Transcode HTML5 → HTML 3.2
        let transcoder = HTMLTranscoder(level: configuration.transcodingLevel, maxImageWidth: configuration.maxImageWidth)
        html = (try? transcoder.transcode(html, baseURL: originalURL)) ?? html

        // Downgrade all https:// URLs to http:// so the vintage browser never
        // attempts TLS (IE5/Netscape 4 can't negotiate modern cipher suites).
        // The proxy fetches via HTTPS on the backend, so security is preserved.
        html = html.replacingOccurrences(of: "https://", with: "http://")

        // Smart Unicode → ASCII cleanup BEFORE encoding.
        // Without this, curly quotes become garbled "â€™" etc.
        html = Self.cleanUnicode(html)

        // Minify HTML to save bandwidth on slow vintage connections
        if configuration.minifyHTML {
            html = Self.minifyHTML(html)
        }

        // Encode for the vintage browser's charset (MacRoman for Macs, iso-8859-1 for PCs)
        let enc = configuration.outputEncoding
        return html.data(using: enc.swiftEncoding, allowLossyConversion: true) ?? Data(html.utf8)
    }

    private static func transcodeImage(
        data: Data,
        acceptHeader: String,
        configuration: ProxyConfiguration,
        logger: Logger
    ) -> (Data, String) {
        // Determine the best output format from the browser's Accept header.
        // Very old browsers (MacWeb 2.0) may only accept image/gif.
        // Most classic Mac browsers (IE5, Netscape 4) accept both.
        let outputFormat = Self.preferredImageFormat(
            acceptHeader: acceptHeader,
            quality: configuration.imageQuality
        )

        let transcoder = ImageTranscoder(
            maxWidth: configuration.maxImageWidth,
            maxHeight: configuration.maxImageWidth * 3 / 4,
            outputFormat: outputFormat,
            colorDepth: configuration.colorDepth
        )

        // forceFormat: true means also transcode JPEG→GIF if the browser only accepts GIF
        if transcoder.needsTranscoding(data, forceFormat: true),
           let result = transcoder.transcode(data) {
            return (result.data, result.mimeType)
        }

        // Already in the right format — pass through with correct MIME type
        return (data, ImageTranscoder.mimeType(for: data))
    }

    private static func readableDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: date)
    }

    /// Check if a URL's domain is in the transcoding bypass list.
    /// Matches both exact domain and parent domain (e.g., "retro.com" matches "www.retro.com").
    private static func shouldBypassTranscoding(url: URL, bypassDomains: Set<String>) -> Bool {
        guard !bypassDomains.isEmpty, let host = url.host?.lowercased() else { return false }
        if bypassDomains.contains(host) { return true }
        // Check parent domain: www.example.com → example.com
        let parts = host.split(separator: ".")
        if parts.count > 2 {
            let parent = parts.dropFirst().joined(separator: ".")
            return bypassDomains.contains(parent)
        }
        return false
    }

    /// Minimal transcoding for bypass domains — only HTTPS→HTTP downgrade and encoding.
    /// Skips the full HTML5→3.2 conversion but keeps the page loadable.
    private static func transcodeHTMLMinimal(
        data: Data,
        originalURL: URL,
        configuration: ProxyConfiguration,
        isWaybackContent: Bool,
        logger: Logger
    ) throws -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }

        // Clean Wayback injection if content came from the archive
        if isWaybackContent {
            let bridge = WaybackBridge()
            html = (try? bridge.cleanWaybackResponse(html)) ?? html
        }

        html = html.replacingOccurrences(of: "https://", with: "http://")
        html = Self.cleanUnicode(html)

        if configuration.minifyHTML {
            html = Self.minifyHTML(html)
        }

        let enc = configuration.outputEncoding
        return html.data(using: enc.swiftEncoding, allowLossyConversion: true) ?? Data(html.utf8)
    }

    /// Minify HTML by stripping comments, collapsing whitespace, and removing
    /// unnecessary attributes. Reduces bandwidth on slow vintage connections.
    static func minifyHTML(_ html: String) -> String {
        var result = html

        // Strip HTML comments (but preserve conditional comments for IE compat)
        if let commentRegex = try? NSRegularExpression(
            pattern: #"<!--(?!\[if).*?-->"#,
            options: .dotMatchesLineSeparators
        ) {
            result = commentRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Collapse runs of whitespace (spaces, tabs, newlines) to a single space
        // within tag content. Preserve whitespace in <pre> blocks.
        if let wsRegex = try? NSRegularExpression(pattern: #"\s{2,}"#) {
            result = wsRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        // Remove blank lines
        if let blankRegex = try? NSRegularExpression(pattern: #"\n\s*\n"#) {
            result = blankRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n"
            )
        }

        return result
    }

    // MARK: - Dead Endpoint Redirection

    /// Built-in dead service endpoints → revival/archive alternatives.
    /// These are services that vintage software tries to reach but no longer exist.
    /// User-defined redirects in config override these defaults.
    static let defaultDeadEndpoints: [String: String] = [
        // Netscape
        "home.netscape.com":              "http://web.archive.org/web/1999/http://home.netscape.com/",
        "channels.netscape.com":          "http://web.archive.org/web/1999/http://channels.netscape.com/",
        "search.netscape.com":            "http://web.archive.org/web/2001/http://search.netscape.com/",
        "wp.netscape.com":                "http://web.archive.org/web/2001/http://wp.netscape.com/",
        // Internet Explorer start pages
        "home.microsoft.com":             "http://web.archive.org/web/2001/http://home.microsoft.com/",
        "www.msn.com":                    "http://web.archive.org/web/2001/http://www.msn.com/",
        // Windows Update (dead, no revival)
        "windowsupdate.microsoft.com":    "http://web.archive.org/web/2003/http://windowsupdate.microsoft.com/",
        "v4.windowsupdate.microsoft.com": "http://web.archive.org/web/2003/http://windowsupdate.microsoft.com/",
        // Apple services
        "itools.mac.com":                 "http://web.archive.org/web/2002/http://itools.mac.com/",
        "homepage.mac.com":               "http://web.archive.org/web/2003/http://homepage.mac.com/",
        "www.mac.com":                    "http://web.archive.org/web/2002/http://www.mac.com/",
        // RealPlayer
        "www.real.com":                   "http://web.archive.org/web/2001/http://www.real.com/",
        "realguide.real.com":             "http://web.archive.org/web/2001/http://realguide.real.com/",
        // ICQ
        "www.icq.com":                    "http://web.archive.org/web/2001/http://www.icq.com/",
        // Excite (common 90s portal)
        "www.excite.com":                 "http://web.archive.org/web/2001/http://www.excite.com/",
        // AltaVista (classic search engine)
        "www.altavista.com":              "http://web.archive.org/web/2002/http://www.altavista.com/",
        // GeoCities
        "www.geocities.com":              "http://web.archive.org/web/2001/http://www.geocities.com/",
    ]

    /// Check if a hostname matches a dead endpoint. User overrides take precedence.
    private static func resolveDeadEndpoint(host: String, config: ProxyConfiguration) -> String? {
        // User-defined redirects override built-in defaults
        if let userRedirect = config.deadEndpointRedirects[host] {
            return userRedirect
        }
        return defaultDeadEndpoints[host]
    }

    /// Determine if a URL is a sub-resource (image, CSS, JS, font) rather than
    /// an HTML page navigation. Sub-resources use the temporal cache to stay on
    /// the same snapshot date; page navigations always use the configured target date.
    private static let subResourceExtensions: Set<String> = [
        "gif", "jpg", "jpeg", "png", "bmp", "tif", "tiff", "ico", "webp", "avif", "svg",
        "css", "js",
        "woff", "woff2", "ttf", "eot", "otf",
        "swf", "mov", "avi", "mpg", "mpeg", "mp3", "wav", "aiff",
        "zip", "gz", "tar", "sit", "hqx", "bin",
        "pdf", "doc", "xls", "ppt",
    ]

    private static func isSubResourceURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return subResourceExtensions.contains(ext)
    }

    /// Parse the Accept header to pick the best image output format.
    /// Priority: if browser lists image/jpeg → JPEG (better quality/size ratio).
    /// If only image/gif → GIF. Falls back to JPEG for */* or image/*.
    private static func preferredImageFormat(acceptHeader: String, quality: Double) -> ImageTranscoder.OutputFormat {
        let lower = acceptHeader.lowercased()

        // Wildcards accept anything — prefer JPEG
        if lower.contains("*/*") || lower.contains("image/*") {
            return .jpeg(quality: quality)
        }

        let acceptsJPEG = lower.contains("image/jpeg") || lower.contains("image/jpg")
        let acceptsGIF  = lower.contains("image/gif")

        if acceptsJPEG {
            return .jpeg(quality: quality)
        } else if acceptsGIF {
            return .gif
        }

        // No image types listed at all (odd) — default to JPEG
        return .jpeg(quality: quality)
    }

    // MARK: - Virtual Host (http://retrogate/...)

    private func handleRetroGateVirtualHost(context: ChannelHandlerContext, head: HTTPRequestHead, url: URL, config: ProxyConfiguration) {
        let path = url.path.lowercased()
        let logger = self.logger

        switch path {
        case "/", "":
            // Start page / portal
            let html = Self.buildStartPage(config: config)
            let data = html.data(using: config.outputEncoding.swiftEncoding, allowLossyConversion: true) ?? Data(html.utf8)
            sendResponse(context: context, data: data, contentType: "text/html; charset=\(config.outputEncoding.charsetLabel)", statusCode: 200)

        case "/search":
            // Search gateway — fetch DuckDuckGo HTML results
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            if query.isEmpty {
                let html = Self.buildSearchPage(query: "", results: nil, config: config)
                let data = html.data(using: config.outputEncoding.swiftEncoding, allowLossyConversion: true) ?? Data(html.utf8)
                sendResponse(context: context, data: data, contentType: "text/html; charset=\(config.outputEncoding.charsetLabel)", statusCode: 200)
                return
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.completeWithTask {
                let results = await Self.fetchSearchResults(query: query, logger: logger)
                let html = Self.buildSearchPage(query: query, results: results, config: config)
                let data = html.data(using: config.outputEncoding.swiftEncoding, allowLossyConversion: true) ?? Data(html.utf8)
                context.eventLoop.execute {
                    self.sendResponse(context: context, data: data, contentType: "text/html; charset=\(config.outputEncoding.charsetLabel)", statusCode: 200)
                }
            }
            promise.futureResult.whenFailure { error in
                self.sendError(context: context, status: .internalServerError, message: "Search failed: \(error.localizedDescription)")
            }

        case "/proxy.pac":
            // PAC file for automatic proxy configuration.
            // The browser already knows our IP (it's talking to us), so extract
            // it from the Host header the browser sent in this very request.
            let hostHeader = head.headers["Host"].first ?? ""
            let proxyHost: String
            let proxyPort: Int
            if hostHeader.contains(":") {
                let parts = hostHeader.split(separator: ":")
                proxyHost = String(parts[0])
                proxyPort = Int(parts[1]) ?? context.channel.localAddress?.port ?? 8080
            } else {
                proxyHost = hostHeader.isEmpty ? (context.channel.localAddress?.ipAddress ?? "10.0.2.2") : hostHeader
                proxyPort = context.channel.localAddress?.port ?? 8080
            }
            let pac = Self.buildPACFile(proxyHost: proxyHost, port: proxyPort)
            let data = Data(pac.utf8)
            sendResponse(context: context, data: data, contentType: "application/x-ns-proxy-autoconfig", statusCode: 200)

        default:
            sendError(context: context, status: .notFound, message: "Unknown RetroGate page: \(path)")
        }
    }

    /// Build the RetroGate start page — a portal with search, curated links, and status.
    private static func buildStartPage(config: ProxyConfiguration) -> String {
        let waybackStatus: String
        switch config.browsingMode {
        case .wayback(let targetDate, _):
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM d, yyyy"
            fmt.locale = Locale(identifier: "en_US")
            waybackStatus = """
            <tr><td bgcolor="#FFFFCC" colspan="2">
            <b>Wayback Machine:</b> ON -- Browsing the web as it was on <b>\(fmt.string(from: targetDate))</b>
            </td></tr>
            """
        case .liveWeb:
            waybackStatus = """
            <tr><td bgcolor="#EEEEEE" colspan="2">
            <b>Wayback Machine:</b> OFF -- Browsing the live web
            </td></tr>
            """
        }

        return """
        <html>
        <head><title>RetroGate - Home</title></head>
        <body bgcolor="#FFFFFF" text="#000000" link="#0000CC" vlink="#663399">
        <center>
        <table width="580" border="0" cellpadding="8" cellspacing="0">
        <tr><td colspan="2" align="center">
        <h1>RetroGate</h1>
        <p><i>Browse the modern web on vintage Macs</i></p>
        </td></tr>

        \(waybackStatus)

        <tr><td colspan="2" align="center">
        <br>
        <form action="http://retrogate/search" method="GET">
        <table border="0" cellpadding="2" cellspacing="0">
        <tr><td><input type="text" name="q" size="40" value=""></td>
        <td><input type="submit" value="Search"></td></tr>
        </table>
        </form>
        <p><font size="2">Powered by DuckDuckGo</font></p>
        </td></tr>

        <tr><td colspan="2"><hr></td></tr>

        <tr><td valign="top" width="50%">
        <b>Popular Sites</b><br>
        <ul>
        <li><a href="http://www.apple.com">Apple</a></li>
        <li><a href="http://www.microsoft.com">Microsoft</a></li>
        <li><a href="http://www.google.com">Google</a></li>
        <li><a href="http://en.wikipedia.org">Wikipedia</a></li>
        <li><a href="http://news.ycombinator.com">Hacker News</a></li>
        <li><a href="http://www.bbc.co.uk">BBC</a></li>
        <li><a href="http://www.cnn.com">CNN</a></li>
        </ul>
        </td>
        <td valign="top" width="50%">
        <b>Retro &amp; Nostalgia</b><br>
        <ul>
        <li><a href="http://www.68kmla.org">68kMLA Forum</a></li>
        <li><a href="http://www.macintoshrepository.org">Macintosh Repository</a></li>
        <li><a href="http://www.macintoshgarden.org">Macintosh Garden</a></li>
        <li><a href="http://system7today.com">System 7 Today</a></li>
        <li><a href="http://web.archive.org">Wayback Machine</a></li>
        <li><a href="http://oldweb.today">OldWeb.today</a></li>
        </ul>
        </td></tr>

        <tr><td colspan="2"><hr></td></tr>

        <tr><td valign="top" width="50%">
        <b>Reference</b><br>
        <ul>
        <li><a href="http://en.wikipedia.org/wiki/Main_Page">Wikipedia Main Page</a></li>
        <li><a href="http://www.weather.gov">Weather (US)</a></li>
        <li><a href="http://www.imdb.com">IMDb</a></li>
        </ul>
        </td>
        <td valign="top" width="50%">
        <b>RetroGate</b><br>
        <ul>
        <li><a href="http://retrogate/search">Search</a></li>
        <li><a href="http://retrogate/proxy.pac">PAC File</a></li>
        </ul>
        </td></tr>

        <tr><td colspan="2"><hr>
        <center><font size="1">RetroGate Proxy -- <a href="http://retrogate/">Home</a></font></center>
        </td></tr>
        </table>
        </center>
        </body>
        </html>
        """
    }

    /// Build the search results page.
    private static func buildSearchPage(query: String, results: [SearchResult]?, config: ProxyConfiguration) -> String {
        let escapedQuery = query
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        var resultsHTML = ""
        if let results = results {
            if results.isEmpty {
                resultsHTML = "<p>No results found for <b>\(escapedQuery)</b>.</p>"
            } else {
                for (i, result) in results.enumerated() {
                    let safeTitle = result.title
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                    let safeSnippet = result.snippet
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                    let safeURL = result.url
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                    // Downgrade https links to http so the vintage browser routes them through us
                    let httpURL = result.url.replacingOccurrences(of: "https://", with: "http://")
                    resultsHTML += """
                    <tr><td>
                    <b>\(i + 1).</b> <a href="\(httpURL)"><b>\(safeTitle)</b></a><br>
                    <font size="2">\(safeSnippet)</font><br>
                    <font size="1" color="#006600">\(safeURL)</font>
                    <br><br>
                    </td></tr>
                    """
                }
            }
        }

        return """
        <html>
        <head><title>RetroGate Search\(query.isEmpty ? "" : " - \(escapedQuery)")</title></head>
        <body bgcolor="#FFFFFF" text="#000000" link="#0000CC" vlink="#663399">
        <center>
        <table width="580" border="0" cellpadding="4" cellspacing="0">
        <tr><td align="center">
        <a href="http://retrogate/"><b>RetroGate</b></a>
        <br><br>
        <form action="http://retrogate/search" method="GET">
        <input type="text" name="q" size="40" value="\(escapedQuery)">
        <input type="submit" value="Search">
        </form>
        </td></tr>
        <tr><td><hr></td></tr>
        \(resultsHTML)
        <tr><td><hr>
        <center><font size="1"><a href="http://retrogate/">RetroGate Home</a> -- Powered by DuckDuckGo</font></center>
        </td></tr>
        </table>
        </center>
        </body>
        </html>
        """
    }

    struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    /// Fetch search results from DuckDuckGo's HTML-only endpoint.
    private static func fetchSearchResults(query: String, logger: Logger) async -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await urlSession.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            logger.warning("Search fetch failed for query: \(query)")
            return []
        }

        // Parse DuckDuckGo HTML results
        // Each result is in a <div class="result"> with <a class="result__a"> and <a class="result__snippet">
        var results: [SearchResult] = []
        do {
            let doc = try SwiftSoup.parse(html)
            for resultDiv in try doc.select(".result") {
                guard let linkEl = try resultDiv.select(".result__a").first() else { continue }
                let title = try linkEl.text()
                var href = try linkEl.attr("href")

                // DuckDuckGo wraps URLs in redirects: //duckduckgo.com/l/?uddg=ENCODED_URL&...
                // Extract the actual URL from the uddg parameter
                if href.contains("uddg=") {
                    if let components = URLComponents(string: href.hasPrefix("//") ? "https:\(href)" : href),
                       let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                        href = uddg
                    }
                }

                let snippet = (try? resultDiv.select(".result__snippet").first()?.text()) ?? ""

                guard !title.isEmpty, !href.isEmpty else { continue }
                results.append(SearchResult(title: title, url: href, snippet: snippet))
                if results.count >= 20 { break }
            }
        } catch {
            logger.warning("Failed to parse search results: \(error)")
        }
        return results
    }

    /// Generate a PAC (Proxy Auto-Configuration) file.
    /// Vintage browsers can load this from http://retrogate/proxy.pac to auto-configure.
    private static func buildPACFile(proxyHost: String, port: Int) -> String {
        return """
        function FindProxyForURL(url, host) {
            // Route all HTTP traffic through RetroGate
            if (url.substring(0, 5) == "http:") {
                return "PROXY \(proxyHost):\(port)";
            }
            return "DIRECT";
        }
        """
    }

    // MARK: - Network Helpers

    /// Fetch with retry and exponential backoff for archive.org transient errors,
    /// plus HTTPS→HTTP certificate fallback for direct fetches.
    private static func fetchWithRetry(
        request: URLRequest,
        delegate: URLSessionTaskDelegate?,
        retryOn502: Bool,
        fetchURL: URL,
        logger: Logger
    ) async throws -> (Data, URLResponse) {
        let maxRetries = retryOn502 ? 3 : 1
        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delayNs = UInt64(pow(2.0, Double(attempt - 1))) * 500_000_000
                try await Task.sleep(nanoseconds: delayNs)
                logger.info("Retry \(attempt)/\(maxRetries - 1) for \(fetchURL.host ?? "?")")
            }
            do {
                let (data, response) = try await Self.urlSession.data(for: request, delegate: delegate)
                // Retry on transient archive.org 502/503
                if let http = response as? HTTPURLResponse,
                   (http.statusCode == 502 || http.statusCode == 503),
                   fetchURL.host?.contains("archive.org") == true,
                   attempt < maxRetries - 1 {
                    continue
                }
                return (data, response)
            } catch let error as URLError where !retryOn502
                        && fetchURL.scheme == "https"
                        && (error.code == .serverCertificateUntrusted
                            || error.code == .serverCertificateHasBadDate
                            || error.code == .serverCertificateHasUnknownRoot
                            || error.code == .serverCertificateNotYetValid
                            || error.code == .secureConnectionFailed) {
                // HTTPS cert error → fall back to plain HTTP (live web only)
                logger.info("HTTPS cert error for \(fetchURL.host ?? "?"), falling back to HTTP")
                var c = URLComponents(url: fetchURL, resolvingAgainstBaseURL: false)!
                c.scheme = "http"
                var r = URLRequest(url: c.url!)
                r.timeoutInterval = 30
                r.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
                return try await Self.urlSession.data(for: r)
            } catch {
                if attempt == maxRetries - 1 { throw error }
            }
        }
        throw ProxyError.notHTTP // unreachable
    }

    // MARK: - Unicode Cleanup

    /// Map Unicode characters to iso-8859-1 friendly equivalents before encoding.
    /// Without this, curly quotes/dashes become garbled multi-byte garbage.
    private static func cleanUnicode(_ text: String) -> String {
        var s = text
        // Curly quotes → straight quotes
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")  // '
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")  // '
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"") // "
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"") // "
        // Dashes
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
        s = s.replacingOccurrences(of: "\u{2014}", with: "--") // em-dash
        // Ellipsis
        s = s.replacingOccurrences(of: "\u{2026}", with: "...") // …
        // Spaces
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")  // non-breaking space
        s = s.replacingOccurrences(of: "\u{2002}", with: " ")  // en-space
        s = s.replacingOccurrences(of: "\u{2003}", with: " ")  // em-space
        s = s.replacingOccurrences(of: "\u{2009}", with: " ")  // thin space
        // Bullets and symbols
        s = s.replacingOccurrences(of: "\u{2022}", with: "*")  // bullet
        s = s.replacingOccurrences(of: "\u{2122}", with: "(TM)") // ™
        s = s.replacingOccurrences(of: "\u{00AE}", with: "(R)") // ®  (keep — exists in iso-8859-1)
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")
        // Arrows
        s = s.replacingOccurrences(of: "\u{2190}", with: "<-") // ←
        s = s.replacingOccurrences(of: "\u{2192}", with: "->") // →
        s = s.replacingOccurrences(of: "\u{2191}", with: "^")  // ↑
        s = s.replacingOccurrences(of: "\u{2193}", with: "v")  // ↓
        return s
    }

    // MARK: - Wayback Image Prefetching
    //
    // When a Wayback HTML page loads, the browser will request every <img>
    // and background image one-by-one. Each Wayback fetch takes 2-5 seconds,
    // so a page with 10 images means 10-20 seconds of waiting.
    //
    // Prefetching fires parallel background requests for all image URLs as
    // soon as we parse the HTML — before the browser even asks. By the time
    // the browser requests each image, it's already in the ResponseCache.

    /// Extract image URLs from transcoded HTML (already encoded, but URLs are ASCII-safe).
    private static func extractImageURLs(from htmlData: Data, baseURL: URL) -> [URL] {
        // Try decoding with common encodings — we only need ASCII URLs
        guard let html = String(data: htmlData, encoding: .isoLatin1)
              ?? String(data: htmlData, encoding: .utf8)
              ?? String(data: htmlData, encoding: .macOSRoman) else { return [] }

        // Match <img src="..."> and background="..." attributes
        // After transcoding, URLs are absolute HTTP and ASCII-safe.
        let patterns = [
            #"<img\b[^>]*\bsrc\s*=\s*"([^"]+)"#,   // <img src="...">
            #"\bbackground\s*=\s*"([^"]+)"#,          // <td background="...">
        ]

        var urls = Set<URL>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let urlStr = String(html[range])

                // Skip data: URIs, anchors, javascript:
                guard !urlStr.hasPrefix("data:"),
                      !urlStr.hasPrefix("#"),
                      !urlStr.hasPrefix("javascript:") else { continue }

                // Resolve relative URLs against the page's base URL
                if let url = URL(string: urlStr, relativeTo: baseURL)?.absoluteURL {
                    urls.insert(url)
                }
            }
        }

        return Array(urls.prefix(30))  // Cap at 30 to avoid flooding archive.org
    }

    /// Fire background fetches for all image URLs found in a Wayback HTML page.
    /// Each fetched response is stored in the ResponseCache so subsequent
    /// browser requests get instant cache hits.
    private static func prefetchWaybackImages(
        htmlData: Data,
        pageURL: URL,
        waybackDate: Date,
        temporalCache: TemporalCache,
        responseCache: ResponseCache,
        logger: Logger
    ) {
        let imageURLs = extractImageURLs(from: htmlData, baseURL: pageURL)
        guard !imageURLs.isEmpty else { return }

        logger.info("Prefetching \(imageURLs.count) sub-resources for \(pageURL.host ?? "?")")

        for imageURL in imageURLs {
            Task {
                // Use temporal cache for date consistency (same as normal request flow)
                var fetchDate = waybackDate
                if let domain = imageURL.host,
                   let cachedStamp = temporalCache.get(domain: domain) {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyyMMdd"
                    if let d = fmt.date(from: cachedStamp) {
                        fetchDate = d
                    }
                }

                // Construct Wayback URL (same logic as handleProxyRequest Wayback branch)
                let bridge = WaybackBridge(targetDate: fetchDate)
                let fetchURL = bridge.rewriteURL(imageURL)
                let cacheKey = fetchURL.absoluteString

                // Skip if already cached
                guard responseCache.get(url: cacheKey) == nil else { return }

                // Best-effort fetch — no retries, failures are non-critical.
                // The browser's actual request will use fetchWithRetry if this misses.
                var request = URLRequest(url: fetchURL)
                request.timeoutInterval = 20
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                if let host = fetchURL.host {
                    request.setValue(host, forHTTPHeaderField: "Host")
                }

                do {
                    let delegate = WaybackRedirectGuard()
                    let (data, response) = try await urlSession.data(for: request, delegate: delegate)
                    if let http = response as? HTTPURLResponse,
                       http.statusCode >= 200, http.statusCode < 400,
                       let ct = http.value(forHTTPHeaderField: "Content-Type") {
                        responseCache.set(url: cacheKey, data: data, contentType: ct)
                        logger.debug("Prefetched: \(imageURL.lastPathComponent) (\(data.count) bytes)")
                    }
                } catch {
                    // Non-critical — the browser's request will fetch it normally
                    logger.debug("Prefetch skipped: \(imageURL.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Response Writing

    private func sendResponse(context: ChannelHandlerContext, data: Data, contentType: String, statusCode: Int, extraHeaders: [(String, String)] = []) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")
        // Prevent vintage browsers from caching responses — the user may change
        // the Wayback date, and the same URL should return different content.
        // Pragma is the HTTP/1.0 equivalent of Cache-Control.
        headers.add(name: "Pragma", value: "no-cache")
        headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        headers.add(name: "Expires", value: "0")
        // Forward cookies and other headers from upstream (with Secure flag stripped)
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }

        let status = HTTPResponseStatus(statusCode: statusCode)
        let responseHead = HTTPResponseHead(version: .http1_0, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func sendRedirect(context: ChannelHandlerContext, location: String) {
        let html = """
        <html><body>
        <p>Redirecting to <a href="\(location)">\(location)</a>...</p>
        </body></html>
        """
        let data = Data(html.utf8)
        sendResponse(context: context, data: data, contentType: "text/html; charset=iso-8859-1", statusCode: 302, extraHeaders: [("Location", location)])
    }

    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let html = """
        <html><body bgcolor="#FFFFFF">
        <h1>\(status.code) \(status.reasonPhrase)</h1>
        <p>\(message)</p>
        <hr><p><i>RetroGate Proxy</i></p>
        </body></html>
        """
        let data = Data(html.utf8)
        sendResponse(context: context, data: data, contentType: "text/html; charset=iso-8859-1", statusCode: Int(status.code))
    }
}

enum ProxyError: Error, LocalizedError {
    case notHTTP
    case waybackRedirectedAway
    case transientArchiveError

    var errorDescription: String? {
        switch self {
        case .notHTTP: return "Response was not HTTP"
        case .waybackRedirectedAway: return "Wayback Machine redirected to live site"
        case .transientArchiveError: return "Archive.org returned a transient error"
        }
    }
}

/// URLSession delegate that blocks redirects leaving web.archive.org.
/// When the Wayback Machine can't find a page, it sometimes 302-redirects
/// to the live site — which may have certificate errors or serve modern HTML.
private final class WaybackRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let host = request.url?.host, host.contains("archive.org") {
            // Redirect within archive.org — allow
            completionHandler(request)
        } else {
            // Redirect away from archive.org → block
            completionHandler(nil)
        }
    }
}
