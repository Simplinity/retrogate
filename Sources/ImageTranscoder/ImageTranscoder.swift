import Foundation
import Logging
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Color Depth

/// Display color depth for vintage machines.
/// Controls image dithering and palette reduction to match the target hardware.
public enum ColorDepth: String, Sendable, Codable, CaseIterable, Hashable {
    /// 1-bit black & white — Floyd-Steinberg error-diffusion dithering.
    case monochrome = "monochrome"
    /// 16 colors — ordered (Bayer 4x4) dithering with standard VGA palette.
    case sixteenColor = "16color"
    /// 256 colors — standard GIF palette quantization.
    case twoFiftySix = "256color"
    /// Thousands+ (16-bit/24-bit) — full color, no reduction.
    case thousands = "thousands"

    public var displayName: String {
        switch self {
        case .monochrome: return "B&W (1-bit)"
        case .sixteenColor: return "16 Colors"
        case .twoFiftySix: return "256 Colors"
        case .thousands: return "Thousands+"
        }
    }
}

// MARK: - Image Transcoder

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
    private let colorDepth: ColorDepth
    private let logger: Logger

    public init(maxWidth: Int = 640, maxHeight: Int = 480, outputFormat: OutputFormat = .jpeg(quality: 0.6), colorDepth: ColorDepth = .thousands) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.outputFormat = outputFormat
        self.colorDepth = colorDepth
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

        // For reduced color depths, fill white background (transparent areas become white)
        if colorDepth != .thousands {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

        // Apply dithering for reduced color depths
        if colorDepth != .thousands, let pixelData = ctx.data {
            switch colorDepth {
            case .monochrome:
                Self.floydSteinbergDither(pixels: pixelData, width: scaledWidth, height: scaledHeight, bytesPerRow: ctx.bytesPerRow)
            case .sixteenColor:
                Self.orderedDither16(pixels: pixelData, width: scaledWidth, height: scaledHeight, bytesPerRow: ctx.bytesPerRow)
            case .twoFiftySix, .thousands:
                break
            }
        }

        guard let resizedImage = ctx.makeImage() else {
            logger.warning("Failed to create resized CGImage")
            return nil
        }

        // For reduced color depths, force GIF (palette-based format preserves dithered pixels)
        let effectiveFormat = (colorDepth != .thousands) ? OutputFormat.gif : outputFormat

        // Encode to target format using ImageIO (thread-safe)
        let outputData = NSMutableData()
        let (utType, mimeType, properties): (CFString, String, CFDictionary) = {
            switch effectiveFormat {
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

        let depthLabel = colorDepth != .thousands ? " [\(colorDepth.displayName)]" : ""
        logger.info("Transcoded \(originalWidth)x\(originalHeight) → \(scaledWidth)x\(scaledHeight) \(mimeType)\(depthLabel) (\(outputData.length) bytes)")
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
        // Dithering modes always require full transcoding
        switch colorDepth {
        case .monochrome, .sixteenColor:
            return true
        case .twoFiftySix:
            return Self.detectFormat(data) != .gif
        case .thousands:
            break
        }

        let detected = Self.detectFormat(data)
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

    // MARK: - Floyd-Steinberg Dithering (1-bit B&W)

    /// Error-diffusion dithering to 1-bit black & white.
    /// Produces the classic Mac Plus/SE halftone look.
    private static func floydSteinbergDither(pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let buf = pixels.assumingMemoryBound(to: UInt8.self)

        // Convert to grayscale float buffer for error diffusion
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bytesPerRow + x * 4
                // ITU-R BT.601 luminance weights
                gray[y * width + x] = 0.299 * Float(buf[off]) + 0.587 * Float(buf[off + 1]) + 0.114 * Float(buf[off + 2])
            }
        }

        // Error diffusion: threshold each pixel, distribute quantization error to neighbors
        //          * 7/16
        //   3/16 5/16 1/16
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = gray[i]
                let new: Float = old > 127.5 ? 255 : 0
                let err = old - new
                gray[i] = new

                if x + 1 < width                    { gray[i + 1]                     += err * 7 / 16 }
                if y + 1 < height && x > 0          { gray[(y + 1) * width + (x - 1)] += err * 3 / 16 }
                if y + 1 < height                    { gray[(y + 1) * width + x]       += err * 5 / 16 }
                if y + 1 < height && x + 1 < width  { gray[(y + 1) * width + (x + 1)] += err * 1 / 16 }
            }
        }

        // Write B&W pixels back to RGBA buffer
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bytesPerRow + x * 4
                let v: UInt8 = gray[y * width + x] > 127.5 ? 255 : 0
                buf[off] = v; buf[off + 1] = v; buf[off + 2] = v; buf[off + 3] = 255
            }
        }
    }

    // MARK: - Ordered Dithering (16 Colors)

    /// Bayer 4x4 threshold matrix (normalized to 0-1).
    private static let bayerMatrix: [[Float]] = [
        [ 0.0/16,  8.0/16,  2.0/16, 10.0/16],
        [12.0/16,  4.0/16, 14.0/16,  6.0/16],
        [ 3.0/16, 11.0/16,  1.0/16,  9.0/16],
        [15.0/16,  7.0/16, 13.0/16,  5.0/16],
    ]

    /// Standard VGA 16-color palette (CGA/EGA/VGA compatible).
    private static let vga16: [(UInt8, UInt8, UInt8)] = [
        (  0,   0,   0), (  0,   0, 170), (  0, 170,   0), (  0, 170, 170),
        (170,   0,   0), (170,   0, 170), (170,  85,   0), (170, 170, 170),
        ( 85,  85,  85), ( 85,  85, 255), ( 85, 255,  85), ( 85, 255, 255),
        (255,  85,  85), (255,  85, 255), (255, 255,  85), (255, 255, 255),
    ]

    /// Ordered (Bayer) dithering to 16-color VGA palette.
    private static func orderedDither16(pixels: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        let buf = pixels.assumingMemoryBound(to: UInt8.self)
        let spread: Float = 64

        for y in 0..<height {
            for x in 0..<width {
                let off = y * bytesPerRow + x * 4
                let threshold = bayerMatrix[y & 3][x & 3]
                let ditherOffset = (threshold - 0.5) * spread

                let r = Float(buf[off])     + ditherOffset
                let g = Float(buf[off + 1]) + ditherOffset
                let b = Float(buf[off + 2]) + ditherOffset

                let nearest = nearestVGA16(r: r, g: g, b: b)
                buf[off] = nearest.0; buf[off + 1] = nearest.1; buf[off + 2] = nearest.2; buf[off + 3] = 255
            }
        }
    }

    /// Find nearest color in the VGA 16-color palette by Euclidean distance.
    private static func nearestVGA16(r: Float, g: Float, b: Float) -> (UInt8, UInt8, UInt8) {
        var bestDist: Float = .greatestFiniteMagnitude
        var best = vga16[0]
        for c in vga16 {
            let dr = r - Float(c.0), dg = g - Float(c.1), db = b - Float(c.2)
            let d = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; best = c }
        }
        return best
    }
}
