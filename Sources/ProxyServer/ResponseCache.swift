import Foundation
import CryptoKit
import NIOConcurrencyHelpers
import Logging

/// Disk-backed response cache for Wayback Machine content.
///
/// Wayback snapshots are immutable — a given URL+timestamp will always return
/// the same bytes. Caching them locally eliminates repeated round-trips to
/// archive.org, which is slow (~2–5 s per request) and rate-limited.
///
/// Storage layout:
///   ~/Library/Caches/RetroGate/
///   ├── blobs/<key>          — raw bytes file (content-type-length + content-type + data)
///   └── index.sqlite         — metadata sidecar (CacheIndex)
///
/// `<key>` is the first 16 hex chars of SHA-256(wayback URL).
///
/// A simple LRU in front of disk keeps the hottest ~200 responses in RAM.
public final class ResponseCache: @unchecked Sendable {
    public let cacheDir: URL
    public let blobsDir: URL
    private let logger: Logger
    private let lock = NIOLock()
    private var memoryCache: [String: CachedResponse] = [:]
    private var accessOrder: [String] = []   // LRU order: oldest first, newest last
    private let maxMemoryEntries = 200

    /// Sidecar metadata index. Created during init; owned for the cache's lifetime.
    public let index: CacheIndex

    /// Bumped whenever the on-disk layout changes incompatibly. On mismatch
    /// with the stored version, the entire cache dir is wiped.
    public static let storageVersion: Int = 2
    private static let storageVersionKey = "retrogate.cache.format.version"

    // Eviction config — 0/0 means unlimited, the default.
    private let limitsLock = NIOLock()
    private var maxSizeBytes: Int64 = 0
    private var maxAgeMs: Int64 = 0
    private var insertsSinceSweep: Int = 0
    private let sweepIntervalInserts = 50
    private let evictionPolicy = CacheEvictionPolicy()

    public struct CachedResponse: Sendable {
        public let data: Data
        public let contentType: String
    }

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("RetroGate", isDirectory: true)
        self.blobsDir = cacheDir.appendingPathComponent("blobs", isDirectory: true)
        var logger = Logger(label: "app.retrogate.cache")
        logger.logLevel = .info
        self.logger = logger

        // Migration: if storage version doesn't match, wipe the whole dir.
        // Archived bytes are recoverable from archive.org, so this is safe.
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: Self.storageVersionKey)
        if stored != Self.storageVersion {
            try? FileManager.default.removeItem(at: cacheDir)
            defaults.set(Self.storageVersion, forKey: Self.storageVersionKey)
            logger.info("Cache format v\(stored) → v\(Self.storageVersion): wiped \(cacheDir.path)")
        }

        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // Open index. If this fails the whole cache is unusable — crash loudly
        // rather than silently serving misses forever.
        do {
            self.index = try CacheIndex(
                dbURL: cacheDir.appendingPathComponent("index.sqlite"),
                logger: logger
            )
        } catch {
            fatalError("CacheIndex open failed: \(error)")
        }
    }

    // MARK: Lookup

    /// Look up a cached response by its Wayback URL. Updates hit counters
    /// as a side effect, but still returns quickly on a warm LRU.
    public func get(url: String) -> CachedResponse? {
        let key = cacheKey(url)

        if let entry = lock.withLock({ memoryGet(key) }) {
            index.recordHit(key: key)
            return entry
        }

        guard let fileData = try? Data(contentsOf: blobPath(key)), fileData.count > 4 else {
            return nil
        }
        guard let entry = decode(fileData) else { return nil }

        lock.withLock { memoryPut(key, entry) }
        index.recordHit(key: key)
        logger.debug("Cache hit (disk): \(url.prefix(80))")
        return entry
    }

    /// Store a response. Metadata goes into the SQLite index alongside the
    /// bytes-file. All fields are required except `waybackDate`, which may be
    /// unknown when the caller didn't parse the final redirected URL.
    public func set(
        url: String,
        data: Data,
        contentType: String,
        originalURL: String,
        waybackDate: String?
    ) {
        let key = cacheKey(url)
        let entry = CachedResponse(data: data, contentType: contentType)

        lock.withLock { memoryPut(key, entry) }

        let encoded = encode(data: data, contentType: contentType)
        try? encoded.write(to: blobPath(key), options: .atomic)

        let domain = URL(string: originalURL)?.host ?? ""
        let now = CacheIndex.nowMs()
        let existing = index.get(key: key)
        let meta = CacheEntryMetadata(
            key: key,
            waybackURL: url,
            originalURL: originalURL,
            domain: domain,
            waybackDate: waybackDate ?? existing?.waybackDate,
            contentType: contentType,
            sizeBytes: Int64(data.count),
            firstCachedAt: existing?.firstCachedAt ?? now,
            lastAccessedAt: now,
            hitCount: existing?.hitCount ?? 0,
            pinned: existing?.pinned ?? false,
            note: existing?.note
        )
        index.upsert(meta)

        // Keep the FTS index in lockstep with HTML caches, so search works
        // on anything that just came through the pipeline. Non-HTML responses
        // are skipped — indexing CSS or image bytes as text is pointless.
        if contentType.lowercased().contains("text/html") {
            let plain = HTMLPlainifier.plainify(data: data)
            if !plain.isEmpty {
                index.upsertFTS(key: key, content: plain)
            }
        }

        // Throttled background sweep: every N inserts, give the eviction policy
        // a chance to trim the cache. Cheap when limits are 0/0 (early return).
        let shouldSweep: Bool = limitsLock.withLock {
            self.insertsSinceSweep += 1
            if self.insertsSinceSweep >= self.sweepIntervalInserts {
                self.insertsSinceSweep = 0
                return true
            }
            return false
        }
        if shouldSweep {
            Task.detached { [weak self] in self?.sweep() }
        }
    }

    /// Remove everything from memory, disk, and the index.
    public func clear() {
        lock.withLock {
            memoryCache.removeAll()
            accessOrder.removeAll()
        }
        index.deleteAll()
        try? FileManager.default.removeItem(at: blobsDir)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        logger.info("Cache cleared")
    }

    // MARK: Eviction

    /// Update retention limits. Triggers an immediate sweep with the new values.
    /// Call from the UI whenever the user changes a limit, and once at startup.
    ///
    /// - Parameters:
    ///   - maxSizeMB: hard cap on total bytes (0 = unlimited)
    ///   - maxAgeDays: max age since last access in days (0 = never auto-delete)
    public func updateLimits(maxSizeMB: Int, maxAgeDays: Int) {
        let newSizeBytes = Int64(max(0, maxSizeMB)) * 1024 * 1024
        let newAgeMs = Int64(max(0, maxAgeDays)) * 24 * 60 * 60 * 1000
        limitsLock.withLock {
            self.maxSizeBytes = newSizeBytes
            self.maxAgeMs = newAgeMs
        }
        sweep()
    }

    /// Run the eviction policy and delete whatever it picks. Safe to call any time.
    /// Skips quickly (no SQL) when both limits are unlimited.
    @discardableResult
    public func sweep() -> Int {
        let (size, age) = limitsLock.withLock { (self.maxSizeBytes, self.maxAgeMs) }
        guard size > 0 || age > 0 else { return 0 }

        let candidates = index.evictionCandidates()
        let victims = evictionPolicy.evaluate(
            entries: candidates,
            maxSizeBytes: size,
            maxAgeMs: age,
            nowMs: CacheIndex.nowMs()
        )
        guard !victims.isEmpty else { return 0 }

        // Delete blob files first (best-effort), then the index rows in one txn.
        for key in victims {
            try? FileManager.default.removeItem(at: blobPath(key))
        }
        index.deleteMany(keys: victims)

        // Drop from memory cache too.
        lock.withLock {
            for key in victims {
                memoryCache.removeValue(forKey: key)
            }
            accessOrder.removeAll { victims.contains($0) }
        }

        logger.info("Cache sweep evicted \(victims.count) entries")
        return victims.count
    }

    // MARK: FTS rebuild

    /// Rebuild the full-text index from every HTML blob currently on disk.
    /// Useful once after upgrading, or after `clearFTS()` on the index.
    ///
    /// The callback is invoked on each blob so the UI can show progress.
    /// Heavy operation — call from a background Task.
    @discardableResult
    public func rebuildFTSIndex(onProgress: (@Sendable (Int, Int) -> Void)? = nil) -> Int {
        let entries = index.allEntries(limit: Int.max)
        let total = entries.count
        var indexed = 0
        for (i, entry) in entries.enumerated() {
            defer { onProgress?(i + 1, total) }
            guard entry.contentType.lowercased().contains("text/html") else { continue }
            guard let fileData = try? Data(contentsOf: blobPath(entry.key)),
                  let decoded = decode(fileData) else { continue }
            let plain = HTMLPlainifier.plainify(data: decoded.data)
            if !plain.isEmpty {
                index.upsertFTS(key: entry.key, content: plain)
                indexed += 1
            }
        }
        logger.info("FTS rebuild: indexed \(indexed) of \(total) entries")
        return indexed
    }

    /// Remove one entry by its wayback URL.
    public func remove(url: String) {
        let key = cacheKey(url)
        lock.withLock {
            memoryCache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        index.delete(key: key)
        try? FileManager.default.removeItem(at: blobPath(key))
    }

    // MARK: LRU helpers (must be called while holding `lock`)

    private func memoryGet(_ key: String) -> CachedResponse? {
        guard let entry = memoryCache[key] else { return nil }
        // Move to MRU end of the access order
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
        return entry
    }

    private func memoryPut(_ key: String, _ entry: CachedResponse) {
        if memoryCache[key] != nil, let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        memoryCache[key] = entry
        accessOrder.append(key)
        while memoryCache.count > maxMemoryEntries, !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    // MARK: Encoding

    /// Format: [4 bytes big-endian content-type length][content-type UTF-8][bytes]
    private func encode(data: Data, contentType: String) -> Data {
        let ctData = Data(contentType.utf8)
        var header = Data(count: 4)
        header[0] = UInt8((ctData.count >> 24) & 0xFF)
        header[1] = UInt8((ctData.count >> 16) & 0xFF)
        header[2] = UInt8((ctData.count >> 8) & 0xFF)
        header[3] = UInt8(ctData.count & 0xFF)
        return header + ctData + data
    }

    private func decode(_ fileData: Data) -> CachedResponse? {
        guard fileData.count >= 4 else { return nil }
        let ctLen = Int(fileData[0]) << 24 | Int(fileData[1]) << 16 | Int(fileData[2]) << 8 | Int(fileData[3])
        guard fileData.count >= 4 + ctLen else { return nil }
        let contentType = String(data: fileData[4..<(4 + ctLen)], encoding: .utf8) ?? "application/octet-stream"
        let bytes = Data(fileData[(4 + ctLen)...])
        return CachedResponse(data: bytes, contentType: contentType)
    }

    private func blobPath(_ key: String) -> URL {
        blobsDir.appendingPathComponent(key)
    }

    /// SHA-256(url), first 16 hex chars. 64-bit namespace is plenty for a
    /// local cache and collision-resistant enough not to worry about.
    private func cacheKey(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
