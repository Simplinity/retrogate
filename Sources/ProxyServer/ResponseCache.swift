import Foundation
import NIOConcurrencyHelpers
import Logging

/// Disk-backed response cache for Wayback Machine content.
///
/// Wayback snapshots are immutable — a given URL+timestamp will always return
/// the same bytes. Caching them locally eliminates repeated round-trips to
/// archive.org, which is slow (~2-5s per request) and rate-limited.
///
/// Cache key: SHA256 hash of the full Wayback URL.
/// Cache format: binary file with a small header (content-type length + content-type + data).
public final class ResponseCache: @unchecked Sendable {
    private let cacheDir: URL
    private let logger: Logger
    private let lock = NIOLock()
    private var memoryCache: [String: CachedResponse] = [:]
    private let maxMemoryEntries = 200

    public struct CachedResponse: Sendable {
        public let data: Data
        public let contentType: String
    }

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("RetroGate", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var logger = Logger(label: "app.retrogate.cache")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Look up a cached response for a Wayback URL.
    public func get(url: String) -> CachedResponse? {
        let key = cacheKey(url)

        // Check memory cache first
        if let entry = lock.withLock({ memoryCache[key] }) {
            return entry
        }

        // Check disk
        let file = cacheDir.appendingPathComponent(key)
        guard let fileData = try? Data(contentsOf: file), fileData.count > 4 else {
            return nil
        }

        // Parse header: [4 bytes content-type length][content-type UTF-8][response data]
        let ctLen = Int(fileData[0]) << 24 | Int(fileData[1]) << 16 | Int(fileData[2]) << 8 | Int(fileData[3])
        guard fileData.count > 4 + ctLen else { return nil }
        let contentType = String(data: fileData[4..<(4 + ctLen)], encoding: .utf8) ?? "application/octet-stream"
        let data = fileData[(4 + ctLen)...]

        let entry = CachedResponse(data: Data(data), contentType: contentType)

        // Promote to memory cache
        lock.withLock {
            if memoryCache.count >= maxMemoryEntries {
                memoryCache.removeAll()
            }
            memoryCache[key] = entry
        }

        logger.debug("Cache hit (disk): \(url.prefix(80))")
        return entry
    }

    /// Store a response in the cache.
    public func set(url: String, data: Data, contentType: String) {
        let key = cacheKey(url)
        let entry = CachedResponse(data: data, contentType: contentType)

        // Memory cache
        lock.withLock {
            if memoryCache.count >= maxMemoryEntries {
                memoryCache.removeAll()
            }
            memoryCache[key] = entry
        }

        // Write to disk asynchronously
        let file = cacheDir.appendingPathComponent(key)
        let ctData = Data(contentType.utf8)
        var header = Data(count: 4)
        header[0] = UInt8((ctData.count >> 24) & 0xFF)
        header[1] = UInt8((ctData.count >> 16) & 0xFF)
        header[2] = UInt8((ctData.count >> 8) & 0xFF)
        header[3] = UInt8(ctData.count & 0xFF)
        let fileData = header + ctData + data
        try? fileData.write(to: file, options: .atomic)
    }

    /// Clear the entire cache.
    public func clear() {
        lock.withLock { memoryCache.removeAll() }
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        logger.info("Cache cleared")
    }

    /// Simple hash of URL string for the filename.
    private func cacheKey(_ url: String) -> String {
        // Use a simple hash — no need for crypto here
        var hash: UInt64 = 5381
        for byte in url.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
