import Foundation
#if canImport(HTMLTranscoder)
import HTMLTranscoder
#endif
#if canImport(ImageTranscoder)
import ImageTranscoder
#endif

// MARK: - Browsing Mode

/// The two fundamental ways RetroGate can fetch web content.
/// These map to entirely separate code paths in the proxy pipeline,
/// so changes to one mode never affect the other.
///
/// - `.liveWeb`: Fetch from the live internet. HTTPS upgrade, cert fallback,
///   auto-Wayback-fallback for 404s. Focus: make modern pages work on old browsers.
/// - `.wayback`: Fetch from the Internet Archive. URL rewriting, response caching,
///   temporal consistency, date drift guard. Focus: browse the web as it was.
public enum BrowsingMode: Sendable {
    /// Browse the modern, live web with transcoding for vintage browsers.
    case liveWeb

    /// Browse archived web pages via the Wayback Machine.
    /// - Parameters:
    ///   - targetDate: The date to fetch archived pages for.
    ///   - toleranceMonths: Max acceptable date drift from target (0 = any date).
    case wayback(targetDate: Date, toleranceMonths: Int)

    /// Whether this mode uses the Wayback Machine.
    public var isWayback: Bool {
        if case .wayback = self { return true }
        return false
    }
}

// MARK: - Configuration

/// Configuration for the proxy server, passed from the UI to the handler.
///
/// Browsing-mode-specific settings (Wayback date, tolerance) live inside
/// `BrowsingMode.wayback(...)`. Everything else applies to both modes.
public struct ProxyConfiguration: Sendable {
    public var browsingMode: BrowsingMode
    public var transcodingLevel: HTMLTranscoder.Level
    public var maxImageWidth: Int
    public var imageQuality: Double
    public var outputEncoding: OutputEncoding
    /// Domains that bypass HTML transcoding (already retro-friendly).
    public var transcodingBypassDomains: Set<String>
    /// Enable HTML minification to reduce bandwidth on slow connections.
    public var minifyHTML: Bool
    /// Display color depth — controls image dithering and palette reduction.
    public var colorDepth: ColorDepth
    /// User-defined dead endpoint redirects (host → redirect URL).
    public var deadEndpointRedirects: [String: String]
    public var onRequestLogged: (@Sendable (RequestLogData) -> Void)?

    public init(
        browsingMode: BrowsingMode = .liveWeb,
        transcodingLevel: HTMLTranscoder.Level = .aggressive,
        maxImageWidth: Int = 640,
        imageQuality: Double = 0.6,
        outputEncoding: OutputEncoding = .isoLatin1,
        transcodingBypassDomains: Set<String> = [],
        minifyHTML: Bool = false,
        colorDepth: ColorDepth = .thousands,
        deadEndpointRedirects: [String: String] = [:],
        onRequestLogged: (@Sendable (RequestLogData) -> Void)? = nil
    ) {
        self.browsingMode = browsingMode
        self.transcodingLevel = transcodingLevel
        self.maxImageWidth = maxImageWidth
        self.imageQuality = imageQuality
        self.outputEncoding = outputEncoding
        self.transcodingBypassDomains = transcodingBypassDomains
        self.minifyHTML = minifyHTML
        self.colorDepth = colorDepth
        self.deadEndpointRedirects = deadEndpointRedirects
        self.onRequestLogged = onRequestLogged
    }
}

// MARK: - Output Encoding

/// Character encoding for HTML output.
public enum OutputEncoding: String, Sendable, Codable, CaseIterable {
    case macRoman = "macintosh"
    case isoLatin1 = "iso-8859-1"

    public var swiftEncoding: String.Encoding {
        switch self {
        case .macRoman: return .macOSRoman
        case .isoLatin1: return .isoLatin1
        }
    }

    public var charsetLabel: String { rawValue }

    public var displayName: String {
        switch self {
        case .macRoman: return "MacRoman"
        case .isoLatin1: return "ISO 8859-1"
        }
    }
}

// MARK: - Request Logging

/// Data emitted after each proxied request, for the UI log.
public struct RequestLogData: Sendable {
    public let method: String
    public let url: String
    public let statusCode: Int
    public let originalSize: Int
    public let transcodedSize: Int
    /// The actual Wayback snapshot date served (YYYYMMDD), if applicable.
    /// nil when Wayback is disabled or for non-Wayback responses.
    public let waybackDate: String?
    public let contentType: String?
    /// Error message if the request failed, nil on success.
    public var errorMessage: String? = nil
}
