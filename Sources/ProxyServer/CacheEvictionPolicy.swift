import Foundation

/// Pure, testable decision layer for cache cleanup.
///
/// Given the current state of the cache (age + size of every entry, pinned or not)
/// and the user's retention limits, returns the set of keys that should be deleted.
/// Knows nothing about SQLite, the filesystem, or threading — call from anywhere.
///
/// Policy:
/// 1. Pinned entries are never evicted.
/// 2. Age pass: delete every entry whose `lastAccessedAt` is older than
///    `(now - maxAgeMs)`. Disabled when `maxAgeMs <= 0`.
/// 3. Size pass: if total size still exceeds `maxSizeBytes`, keep evicting
///    the least-recently-accessed non-pinned entries until we're under the cap.
///    Disabled when `maxSizeBytes <= 0`.
public struct CacheEvictionPolicy: Sendable {
    public struct Candidate: Sendable, Equatable {
        public let key: String
        public let sizeBytes: Int64
        public let lastAccessedAt: Int64
        public let pinned: Bool

        public init(key: String, sizeBytes: Int64, lastAccessedAt: Int64, pinned: Bool) {
            self.key = key
            self.sizeBytes = sizeBytes
            self.lastAccessedAt = lastAccessedAt
            self.pinned = pinned
        }
    }

    public init() {}

    /// Compute the keys to evict.
    ///
    /// - Parameters:
    ///   - entries: every entry in the cache, in any order
    ///   - maxSizeBytes: hard cap on total bytes; `<= 0` means unlimited
    ///   - maxAgeMs: max age since `lastAccessedAt` in ms; `<= 0` means forever
    ///   - nowMs: current time in unix ms (injectable for tests)
    /// - Returns: keys that should be deleted, in no guaranteed order
    public func evaluate(
        entries: [Candidate],
        maxSizeBytes: Int64,
        maxAgeMs: Int64,
        nowMs: Int64
    ) -> Set<String> {
        var toDelete: Set<String> = []

        // Pass 1 — age.
        if maxAgeMs > 0 {
            let cutoff = nowMs - maxAgeMs
            for e in entries where !e.pinned && e.lastAccessedAt < cutoff {
                toDelete.insert(e.key)
            }
        }

        // Pass 2 — size. Only evaluate survivors from the age pass.
        guard maxSizeBytes > 0 else { return toDelete }

        let survivors = entries.filter { !toDelete.contains($0.key) }
        let totalSize = survivors.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if totalSize <= maxSizeBytes { return toDelete }

        // Evict LRU non-pinned entries until under the cap.
        // Pinned entries count toward total size but are never candidates.
        let evictable = survivors
            .filter { !$0.pinned }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }  // oldest first

        var remaining = totalSize
        for e in evictable {
            if remaining <= maxSizeBytes { break }
            toDelete.insert(e.key)
            remaining -= e.sizeBytes
        }
        return toDelete
    }
}
