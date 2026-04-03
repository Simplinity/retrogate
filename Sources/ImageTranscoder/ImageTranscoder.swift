import Foundation
import Logging

#if canImport(AppKit)
import AppKit
#endif

/// Converts modern image formats (WebP, AVIF, HEIF) to vintage-compatible
/// formats (JPEG, GIF) and resizes to configurable max dimensions.
///
/// Uses CoreGraphics/AppKit — no external dependencies needed on macOS.
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
    public func transcode(_ data: Data) -> (data: Data, mimeType: String)? {
        #if canImport(AppKit)
        guard let image = NSImage(data: data) else {
            logger.warning("Failed to decode image data (\(data.count) bytes)")
            return nil
        }
        
        // Get original dimensions
        guard let rep = image.representations.first else { return nil }
        let originalWidth = rep.pixelsWide
        let originalHeight = rep.pixelsHigh
        
        // Calculate scaled dimensions maintaining aspect ratio
        let (scaledWidth, scaledHeight) = scaledSize(
            width: originalWidth, height: originalHeight,
            maxWidth: maxWidth, maxHeight: maxHeight
        )
        
        // Resize
        let resizedImage = NSImage(size: NSSize(width: scaledWidth, height: scaledHeight))
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight),
            from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()
        
        // Convert to target format
        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        switch outputFormat {
        case .jpeg(let quality):
            if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                logger.info("Transcoded \(originalWidth)x\(originalHeight) → \(scaledWidth)x\(scaledHeight) JPEG (\(jpegData.count) bytes)")
                return (jpegData, "image/jpeg")
            }
        case .gif:
            if let gifData = bitmap.representation(using: .gif, properties: [:]) {
                return (gifData, "image/gif")
            }
        case .png:
            if let pngData = bitmap.representation(using: .png, properties: [:]) {
                return (pngData, "image/png")
            }
        }
        
        return nil
        #else
        logger.error("ImageTranscoder requires macOS (AppKit)")
        return nil
        #endif
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
    public func needsTranscoding(_ data: Data) -> Bool {
        // Check magic bytes
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return false } // JPEG
        if data.starts(with: [0x47, 0x49, 0x46]) { return false } // GIF
        return true // WebP, AVIF, PNG, HEIF, etc. — transcode to be safe
    }
}
