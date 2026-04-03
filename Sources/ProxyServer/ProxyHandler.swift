import NIO
import NIOHTTP1
import Logging
import Foundation
import HTMLTranscoder
import ImageTranscoder
import WaybackBridge

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
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    private static let maxResponseSize = 10 * 1024 * 1024 // 10 MB

    init(logger: Logger, sharedConfig: SharedConfiguration) {
        self.logger = logger
        self.sharedConfig = sharedConfig
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
        guard let originalURL = URL(string: head.uri) else {
            sendError(context: context, status: .badRequest, message: "Invalid URL")
            return
        }

        // Snapshot config at request time so UI changes take effect immediately
        let config = self.sharedConfig.value

        // Upgrade http:// to https:// for the outbound fetch
        var fetchURL = originalURL
        if var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) {
            if components.scheme == "http" {
                components.scheme = "https"
                fetchURL = components.url ?? originalURL
            }
        }

        // Wayback Machine URL rewriting
        if config.waybackEnabled {
            let bridge = WaybackBridge(targetDate: config.waybackDate)
            if !bridge.isWaybackURL(fetchURL) {
                fetchURL = bridge.rewriteURL(fetchURL)
            }
        }

        // Bridge NIO → async: spawn a Task, write the response back on the event loop
        let promise = context.eventLoop.makePromise(of: Void.self)
        let logger = self.logger

        promise.completeWithTask {
            do {
                let (data, contentType, statusCode) = try await Self.fetchAndTranscode(
                    fetchURL: fetchURL,
                    originalURL: originalURL,
                    configuration: config,
                    logger: logger
                )

                // Log the request
                config.onRequestLogged?(RequestLogData(
                    method: String(describing: head.method),
                    url: head.uri,
                    statusCode: statusCode,
                    originalSize: data.count,
                    transcodedSize: data.count
                ))

                // Write response back on the event loop
                context.eventLoop.execute {
                    self.sendResponse(context: context, data: data, contentType: contentType, statusCode: statusCode)
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

    // MARK: - Fetch & Transcode (async)

    private static func fetchAndTranscode(
        fetchURL: URL,
        originalURL: URL,
        configuration: ProxyConfiguration,
        logger: Logger
    ) async throws -> (Data, String, Int) {
        var request = URLRequest(url: fetchURL)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.notHTTP
        }

        let statusCode = httpResponse.statusCode
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

        // Route by content type
        if contentType.contains("text/html") {
            let transcoded = try transcodeHTML(
                data: data,
                originalURL: originalURL,
                configuration: configuration,
                logger: logger
            )
            return (transcoded, "text/html; charset=iso-8859-1", statusCode)
        } else if contentType.starts(with: "image/") {
            let (imageData, mimeType) = transcodeImage(
                data: data,
                configuration: configuration,
                logger: logger
            )
            return (imageData, mimeType, statusCode)
        } else {
            // CSS, JS, fonts, etc. — pass through
            return (data, contentType, statusCode)
        }
    }

    private static func transcodeHTML(
        data: Data,
        originalURL: URL,
        configuration: ProxyConfiguration,
        logger: Logger
    ) throws -> Data {
        guard var html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }

        // Clean Wayback Machine injection if applicable
        if configuration.waybackEnabled {
            let bridge = WaybackBridge(targetDate: configuration.waybackDate)
            html = (try? bridge.cleanWaybackResponse(html)) ?? html
        }

        // Transcode HTML5 → HTML 3.2
        let transcoder = HTMLTranscoder(level: configuration.transcodingLevel, maxImageWidth: configuration.maxImageWidth)
        html = (try? transcoder.transcode(html, baseURL: originalURL)) ?? html

        // Encode as iso-8859-1 for vintage browsers (lossy — replaces unmappable chars)
        return html.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(html.utf8)
    }

    private static func transcodeImage(
        data: Data,
        configuration: ProxyConfiguration,
        logger: Logger
    ) -> (Data, String) {
        let transcoder = ImageTranscoder(
            maxWidth: configuration.maxImageWidth,
            maxHeight: configuration.maxImageWidth * 3 / 4,
            outputFormat: .jpeg(quality: configuration.imageQuality)
        )

        if transcoder.needsTranscoding(data),
           let result = transcoder.transcode(data) {
            return (result.data, result.mimeType)
        }

        // Already JPEG/GIF — pass through
        return (data, "image/jpeg")
    }

    // MARK: - Response Writing

    private func sendResponse(context: ChannelHandlerContext, data: Data, contentType: String, statusCode: Int) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")

        let status = HTTPResponseStatus(statusCode: statusCode)
        let responseHead = HTTPResponseHead(version: .http1_0, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
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

    var errorDescription: String? {
        switch self {
        case .notHTTP: return "Response was not HTTP"
        }
    }
}
