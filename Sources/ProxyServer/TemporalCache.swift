import Foundation
import NIOConcurrencyHelpers

/// Thread-safe cache that maps domains to resolved Wayback timestamps.
///
/// When the Wayback Machine serves an HTML page, the actual snapshot date
/// often differs from the requested date (e.g., you ask for 19971231 but
/// get 19971215 because that's the closest snapshot). This cache remembers
/// the resolved date per domain so sub-resources (images, CSS, JS) can be
/// loaded from the same snapshot, keeping the page temporally consistent.
public final class TemporalCache: @unchecked Sendable {
    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]

    /// How long a resolved date stays valid before falling back to the
    /// configured date. 5 minutes is generous — a page load and all its
    /// sub-resources should complete well within this window.
    private let ttl: TimeInterval = 300

    public init() {}

    private struct Entry {
        let dateStamp: String      // "19971215" — 8-digit Wayback timestamp
        let storedAt: Date
    }

    /// Record a resolved Wayback timestamp for a domain.
    /// Called after fetching an HTML page from the Wayback Machine.
    public func set(domain: String, dateStamp: String) {
        lock.withLock {
            entries[domain] = Entry(dateStamp: dateStamp, storedAt: Date())
        }
    }

    /// Look up the resolved Wayback timestamp for a domain.
    /// Returns nil if not cached or expired.
    public func get(domain: String) -> String? {
        lock.withLock {
            guard let entry = entries[domain] else { return nil }
            if Date().timeIntervalSince(entry.storedAt) > ttl {
                entries.removeValue(forKey: domain)
                return nil
            }
            return entry.dateStamp
        }
    }

    /// Remove all cached entries (e.g., when Wayback date changes in the UI).
    public func clear() {
        lock.withLock {
            entries.removeAll()
        }
    }
}
