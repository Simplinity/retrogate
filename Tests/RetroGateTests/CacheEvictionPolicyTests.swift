import XCTest
@testable import ProxyServer

final class CacheEvictionPolicyTests: XCTestCase {
    let policy = CacheEvictionPolicy()
    let now: Int64 = 1_700_000_000_000  // arbitrary fixed unix ms for deterministic tests

    // MARK: - No limits

    func testNoLimitsReturnsNothing() {
        let entries = [
            c(key: "a", size: 1_000_000, age: .days(10)),
            c(key: "b", size: 9_999_999, age: .days(365))
        ]
        let result = policy.evaluate(entries: entries, maxSizeBytes: 0, maxAgeMs: 0, nowMs: now)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Age-based eviction

    func testAgePassDeletesExpiredOnly() {
        let entries = [
            c(key: "fresh", size: 100, age: .days(1)),
            c(key: "borderline", size: 100, age: .days(7) + 1),  // just over
            c(key: "stale", size: 100, age: .days(30))
        ]
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 0,
            maxAgeMs: .days(7),
            nowMs: now
        )
        XCTAssertEqual(result, ["borderline", "stale"])
    }

    func testAgePassRespectsPinned() {
        let entries = [
            c(key: "ancient-pinned", size: 100, age: .days(9999), pinned: true),
            c(key: "ancient", size: 100, age: .days(9999))
        ]
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 0,
            maxAgeMs: .days(7),
            nowMs: now
        )
        XCTAssertEqual(result, ["ancient"])
    }

    // MARK: - Size-based eviction

    func testSizePassEvictsLRUUntilUnderCap() {
        let entries = [
            c(key: "newest", size: 300, age: .minutes(1)),
            c(key: "middle", size: 300, age: .minutes(10)),
            c(key: "oldest", size: 300, age: .minutes(100))
        ]
        // Total = 900, cap = 600 → must remove 300+ bytes (LRU first)
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 600,
            maxAgeMs: 0,
            nowMs: now
        )
        XCTAssertEqual(result, ["oldest"])
    }

    func testSizePassEvictsMultipleWhenNeeded() {
        let entries = [
            c(key: "a", size: 100, age: .minutes(1)),
            c(key: "b", size: 100, age: .minutes(2)),
            c(key: "c", size: 100, age: .minutes(3)),
            c(key: "d", size: 100, age: .minutes(4))
        ]
        // Total = 400, cap = 150 → must remove until <= 150 (i.e., remove 3 entries, keep 1)
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 150,
            maxAgeMs: 0,
            nowMs: now
        )
        XCTAssertEqual(result, ["d", "c", "b"])
    }

    func testSizePassNeverEvictsPinnedEvenIfCapExceeded() {
        let entries = [
            c(key: "pinned-big", size: 1000, age: .minutes(100), pinned: true),
            c(key: "small-new", size: 10, age: .minutes(1))
        ]
        // Pinned alone exceeds the cap — policy must leave it and take small entry? No.
        // Pinned is NEVER a candidate. The 10-byte entry stays because even after
        // evicting "small-new" we're still 1000 > 100, so evicting it is pointless.
        // Policy currently would evict small-new anyway because we try to get under.
        // Actually read the policy: it only evicts until <= cap OR no more evictable.
        // So small-new gets evicted as we try, even though it won't save us.
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 100,
            maxAgeMs: 0,
            nowMs: now
        )
        // Pinned never deleted; small-new is evicted in attempt to shrink.
        XCTAssertFalse(result.contains("pinned-big"))
        XCTAssertTrue(result.contains("small-new"))
    }

    func testSizePassNoopWhenUnderCap() {
        let entries = [
            c(key: "a", size: 100, age: .minutes(1)),
            c(key: "b", size: 100, age: .minutes(2))
        ]
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 500,
            maxAgeMs: 0,
            nowMs: now
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Combined passes

    func testAgeAndSizeBothApply() {
        let entries = [
            c(key: "stale-small",  size: 10,  age: .days(30)),   // dies to age
            c(key: "fresh-huge",   size: 900, age: .minutes(5)), // survives age, older → dies to size
            c(key: "fresh-small",  size: 50,  age: .minutes(1))  // survives both (newer)
        ]
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 100,
            maxAgeMs: .days(7),
            nowMs: now
        )
        XCTAssertTrue(result.contains("stale-small"))
        XCTAssertTrue(result.contains("fresh-huge"))
        XCTAssertFalse(result.contains("fresh-small"))
    }

    // MARK: - Edge cases

    func testEmptyEntriesReturnsEmpty() {
        let result = policy.evaluate(entries: [], maxSizeBytes: 100, maxAgeMs: .days(1), nowMs: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testZeroByteEntriesAreEvictable() {
        let entries = [
            c(key: "empty-fresh", size: 0, age: .minutes(1)),
            c(key: "empty-stale", size: 0, age: .days(30))
        ]
        let result = policy.evaluate(
            entries: entries,
            maxSizeBytes: 0,
            maxAgeMs: .days(7),
            nowMs: now
        )
        XCTAssertEqual(result, ["empty-stale"])
    }

    // MARK: - Helper

    private func c(
        key: String,
        size: Int64,
        age: Int64,
        pinned: Bool = false
    ) -> CacheEvictionPolicy.Candidate {
        CacheEvictionPolicy.Candidate(
            key: key,
            sizeBytes: size,
            lastAccessedAt: now - age,
            pinned: pinned
        )
    }
}

// MARK: - Duration helpers

private extension Int64 {
    static func minutes(_ n: Int64) -> Int64 { n * 60 * 1000 }
    static func days(_ n: Int64) -> Int64 { n * 24 * 60 * 60 * 1000 }
}
