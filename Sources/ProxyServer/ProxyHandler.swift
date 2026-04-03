import NIO
import NIOHTTP1
import Logging
import Foundation

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
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    
    init(logger: Logger) {
        self.logger = logger
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
        // The URI in a proxy request is the full URL: http://example.com/path
        guard let url = URL(string: head.uri) else {
            sendError(context: context, status: .badRequest, message: "Invalid URL")
            return
        }
        
        // Upgrade http:// to https:// for the outbound fetch
        var fetchURL = url
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if components.scheme == "http" {
                components.scheme = "https"
                fetchURL = components.url ?? url
            }
        }
        
        // TODO: If wayback mode enabled, rewrite URL through Wayback Machine
        // TODO: Fetch via URLSession, transcode HTML, convert images
        // TODO: Return transcoded response
        
        // Placeholder: return a welcome page
        let html = """
        <html>
        <head><title>RetroGate</title></head>
        <body bgcolor="#FFFFFF" text="#000000">
        <h1>RetroGate Proxy</h1>
        <p>Successfully proxied: <b>\(head.uri)</b></p>
        <hr>
        <p><i>RetroGate — Browse the modern web on vintage Macs</i></p>
        </body>
        </html>
        """
        
        let responseData = Data(html.utf8)
        var buffer = context.channel.allocator.buffer(capacity: responseData.count)
        buffer.writeBytes(responseData)
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=iso-8859-1")
        headers.add(name: "Content-Length", value: "\(responseData.count)")
        headers.add(name: "Connection", value: "close")
        
        let responseHead = HTTPResponseHead(version: .http1_0, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
    
    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let html = "<html><body><h1>\(status.code) \(status.reasonPhrase)</h1><p>\(message)</p></body></html>"
        let data = Data(html.utf8)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html")
        headers.add(name: "Content-Length", value: "\(data.count)")
        
        let head = HTTPResponseHead(version: .http1_0, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}
