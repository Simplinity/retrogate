import Foundation
import Logging
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Converts modern image formats (WebP, AVIF, HEIF) to vintage-compatible
/// formats (JPEG, GIF) and resizes to configurable max dimensions.
///
/// Uses CoreGraphics + ImageIO — fully thread-safe, no AppKit dependency.
/// (NSImage.lockFocus crashes on background threads in modern macOS.)
public struct ImageTranscoder {

    public enum OutputFormat: Sendable {
        case jpeg(quality: Double)
        case gif
        case png
    }

    private let maxWidth: Int
    private let maxHeight: Int
    private let outputFormat: OutputFormat
    private let logger: Logger

    public init(maxWidth: Int = 640, maxHeight: Int = 480, outputFormat: OutputFormat = .jpeg(quality: 0.6)) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.outputFormat = outputFormat
        var logger = Logger(label: "app.retrogate.image")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Transcode image data to a vintage-compatible format.
    /// Accepts any format that CGImageSource can read (WebP, AVIF, HEIF, PNG, JPEG, GIF, TIFF, BMP).
    /// Returns transcoded data and the appropriate MIME type.
    ///
    /// Thread-safe: uses CGContext instead of NSImage.lockFocus().
    public func transcode(_ data: Data) -> (data: Data, mimeType: String)? {
        // Try ImageIO first (thread-safe, handles JPEG/PNG/GIF/WebP/AVIF/HEIF)
        let cgImage: CGImage
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            cgImage = img
        } else if Self.isSVG(data),
                  let img = Self.renderSVG(data, maxWidth: maxWidth, maxHeight: maxHeight) {
            // SVG: NSImage can decode it; CGImageSource cannot.
            // NSImage(data:) + cgImage(forProposedRect:) is thread-safe —
            // only lockFocus/unlockFocus is not.
            cgImage = img
        } else {
            logger.warning("Failed to decode image data (\(data.count) bytes)")
            return nil
        }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        // Calculate scaled dimensions maintaining aspect ratio
        let (scaledWidth, scaledHeight) = scaledSize(
            width: originalWidth, height: originalHeight,
            maxWidth: maxWidth, maxHeight: maxHeight
        )

        // Resize using CGContext (thread-safe)
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.warning("Failed to create CGContext for \(scaledWidth)x\(scaledHeight)")
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

        guard let resizedImage = ctx.makeImage() else {
            logger.warning("Failed to create resized CGImage")
            return nil
        }

        // Encode to target format using ImageIO (thread-safe)
        let outputData = NSMutableData()
        let (utType, mimeType, properties): (CFString, String, CFDictionary) = {
            switch outputFormat {
            case .jpeg(let quality):
                let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                return (UTType.jpeg.identifier as CFString, "image/jpeg", props)
            case .gif:
                return (UTType.gif.identifier as CFString, "image/gif", [:] as CFDictionary)
            case .png:
                return (UTType.png.identifier as CFString, "image/png", [:] as CFDictionary)
            }
        }()

        guard let dest = CGImageDestinationCreateWithData(outputData, utType, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, resizedImage, properties)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }

        logger.info("Transcoded \(originalWidth)x\(originalHeight) → \(scaledWidth)x\(scaledHeight) \(mimeType) (\(outputData.length) bytes)")
        return (outputData as Data, mimeType)
    }
    
    /// Calculate scaled dimensions maintaining aspect ratio.
    private func scaledSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        guard width > maxWidth || height > maxHeight else {
            return (width, height)
        }
        
        let widthRatio = Double(maxWidth) / Double(width)
        let heightRatio = Double(maxHeight) / Double(height)
        let ratio = min(widthRatio, heightRatio)
        
        return (Int(Double(width) * ratio), Int(Double(height) * ratio))
    }
    
    /// Detect if data is a modern format that needs transcoding,
    /// or an already-compatible format (JPEG, GIF) that can pass through.
    /// When `forceFormat` is true, also transcode JPEG↔GIF conversions
    /// (e.g., browser only accepts GIF but image is JPEG).
    public func needsTranscoding(_ data: Data, forceFormat: Bool = false) -> Bool {
        let detected = Self.detectFormat(data)
        // If forcing a specific output format, check if we need to convert
        if forceFormat {
            switch (detected, outputFormat) {
            case (.jpeg, .jpeg): return false  // already JPEG, want JPEG
            case (.gif, .gif):   return false  // already GIF, want GIF
            case (.png, .png):   return false  // already PNG, want PNG
            default:             return true   // format mismatch — must transcode
            }
        }
        // Default: only transcode modern formats (WebP, AVIF, HEIF, PNG, SVG, etc.)
        switch detected {
        case .jpeg, .gif: return false
        default:          return true  // SVG, PNG, other → must transcode
        }
    }

    /// Detected image format from magic bytes
    public enum DetectedFormat {
        case jpeg, gif, png, svg, other
    }

    /// Identify image format from magic bytes.
    public static func detectFormat(_ data: Data) -> DetectedFormat {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x47, 0x49, 0x46]) { return .gif }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if isSVG(data) { return .svg }
        return .other
    }

    /// Check if data looks like SVG (XML text starting with <svg or <?xml....<svg).
    static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }

    /// Render SVG data to a CGImage using NSImage (thread-safe decode path).
    private static func renderSVG(_ data: Data, maxWidth: Int, maxHeight: Int) -> CGImage? {
        let nsImage = NSImage(data: data)
        guard let nsImage, nsImage.size.width > 0 else { return nil }
        // Render at target size to get a crisp raster
        let size = NSSize(width: min(nsImage.size.width, CGFloat(maxWidth)),
                          height: min(nsImage.size.height, CGFloat(maxHeight)))
        var rect = NSRect(origin: .zero, size: size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Return the correct MIME type for already-compatible pass-through data.
    public static func mimeType(for data: Data) -> String {
        switch detectFormat(data) {
        case .jpeg: return "image/jpeg"
        case .gif:  return "image/gif"
        case .png:  return "image/png"
        case .svg:  return "image/svg+xml"
        case .other: return "application/octet-stream"
        }
    }
}
