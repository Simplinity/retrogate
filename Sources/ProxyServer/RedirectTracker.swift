import Foundation
import NIOConcurrencyHelpers

/// Thread-safe tracker that detects redirect loops and carousels.
///
/// When the proxy sees the same URL repeatedly within a short window,
/// it's likely an HTTP↔HTTPS redirect loop or a multi-site bounce.
/// This tracker records recently-seen URLs and lets the handler break
/// the cycle before the vintage browser gives up with a timeout.
public final class RedirectTracker: @unchecked Sendable {
    private let lock = NIOLock()
    private var recentURLs: [String: Entry] = [:]

    /// How long a URL stays in the "recently seen" set.
    /// 10 seconds is enough to catch loops without false positives
    /// from legitimate revisits.
    private let windowSeconds: TimeInterval = 10

    /// How many times the same URL can appear in the window before
    /// we declare it a loop. 2 = second visit triggers detection.
    private let maxHits = 2

    public init() {}

    private struct Entry {
        var count: Int
        var firstSeen: Date
    }

    /// Record a URL visit. Returns `true` if this looks like a redirect loop.
    public func recordAndCheck(url: String) -> Bool {
        lock.withLock {
            let now = Date()

            // Evict stale entries periodically (every 50 checks)
            if recentURLs.count > 100 {
                recentURLs = recentURLs.filter { now.timeIntervalSince($0.value.firstSeen) < windowSeconds }
            }

            if var entry = recentURLs[url] {
                if now.timeIntervalSince(entry.firstSeen) > windowSeconds {
                    // Window expired — reset
                    recentURLs[url] = Entry(count: 1, firstSeen: now)
                    return false
                }
                entry.count += 1
                recentURLs[url] = entry
                return entry.count >= maxHits
            } else {
                recentURLs[url] = Entry(count: 1, firstSeen: now)
                return false
            }
        }
    }

    /// Clear all tracked URLs (e.g., when settings change).
    public func clear() {
        lock.withLock {
            recentURLs.removeAll()
        }
    }
}
