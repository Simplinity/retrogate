import Foundation
import HTMLTranscoder

/// Configuration for the proxy server, passed from the UI to the handler.
public struct ProxyConfiguration: Sendable {
    public var transcodingLevel: HTMLTranscoder.Level
    public var waybackEnabled: Bool
    public var waybackDate: Date
    public var maxImageWidth: Int
    public var imageQuality: Double
    public var onRequestLogged: (@Sendable (RequestLogData) -> Void)?

    public init(
        transcodingLevel: HTMLTranscoder.Level = .aggressive,
        waybackEnabled: Bool = false,
        waybackDate: Date = Date(),
        maxImageWidth: Int = 640,
        imageQuality: Double = 0.6,
        onRequestLogged: (@Sendable (RequestLogData) -> Void)? = nil
    ) {
        self.transcodingLevel = transcodingLevel
        self.waybackEnabled = waybackEnabled
        self.waybackDate = waybackDate
        self.maxImageWidth = maxImageWidth
        self.imageQuality = imageQuality
        self.onRequestLogged = onRequestLogged
    }
}

/// Data emitted after each proxied request, for the UI log.
public struct RequestLogData: Sendable {
    public let method: String
    public let url: String
    public let statusCode: Int
    public let originalSize: Int
    public let transcodedSize: Int
}
