import XCTest
@testable import ProxyServer

final class CacheIndexTests: XCTestCase {
    var tempDir: URL!
    var index: CacheIndex!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrogate-cacheindex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        index = try CacheIndex(dbURL: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Basic roundtrip

    func testUpsertAndGetRoundtrip() {
        let entry = makeEntry(key: "abc123", waybackDate: "19970615", size: 4096)
        index.upsert(entry)

        let fetched = index.get(key: "abc123")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.waybackURL, entry.waybackURL)
        XCTAssertEqual(fetched?.originalURL, entry.originalURL)
        XCTAssertEqual(fetched?.domain, "apple.com")
        XCTAssertEqual(fetched?.waybackDate, "19970615")
        XCTAssertEqual(fetched?.contentType, "text/html")
        XCTAssertEqual(fetched?.sizeBytes, 4096)
        XCTAssertEqual(fetched?.hitCount, 0)
        XCTAssertEqual(fetched?.pinned, false)
    }

    func testGetMissingReturnsNil() {
        XCTAssertNil(index.get(key: "does-not-exist"))
    }

    // MARK: - Hit tracking

    func testRecordHitIncrementsAndUpdatesTimestamp() {
        let before = CacheIndex.nowMs()
        let entry = makeEntry(key: "hit1", firstCachedAt: before, lastAccessedAt: before)
        index.upsert(entry)

        index.recordHit(key: "hit1", at: before + 1000)
        index.recordHit(key: "hit1", at: before + 2000)
        index.recordHit(key: "hit1", at: before + 3000)

        let fetched = index.get(key: "hit1")
        XCTAssertEqual(fetched?.hitCount, 3)
        XCTAssertEqual(fetched?.lastAccessedAt, before + 3000)
    }

    func testRecordHitOnMissingKeyIsNoop() {
        index.recordHit(key: "ghost")
        XCTAssertNil(index.get(key: "ghost"))
    }

    // MARK: - Upsert semantics

    func testUpsertPreservesHitCountAndPinned() {
        let e1 = makeEntry(key: "preserve")
        index.upsert(e1)
        index.recordHit(key: "preserve")
        index.recordHit(key: "preserve")
        index.setPinned(key: "preserve", pinned: true)

        // Refetch with new content-size (simulating re-fetch of the same URL)
        var e2 = e1
        e2.sizeBytes = 99999
        e2.contentType = "image/gif"
        index.upsert(e2)

        let fetched = index.get(key: "preserve")
        XCTAssertEqual(fetched?.hitCount, 2, "hit_count must survive re-upsert")
        XCTAssertEqual(fetched?.pinned, true, "pinned flag must survive re-upsert")
        XCTAssertEqual(fetched?.sizeBytes, 99999, "new size should be applied")
        XCTAssertEqual(fetched?.contentType, "image/gif", "new content-type should be applied")
    }

    // MARK: - Pin flag

    func testSetPinned() {
        index.upsert(makeEntry(key: "pinme"))
        XCTAssertEqual(index.get(key: "pinme")?.pinned, false)

        index.setPinned(key: "pinme", pinned: true)
        XCTAssertEqual(index.get(key: "pinme")?.pinned, true)

        index.setPinned(key: "pinme", pinned: false)
        XCTAssertEqual(index.get(key: "pinme")?.pinned, false)
    }

    // MARK: - Aggregates

    func testCountAndTotalSize() {
        XCTAssertEqual(index.count(), 0)
        XCTAssertEqual(index.totalSize(), 0)

        index.upsert(makeEntry(key: "a", size: 100))
        index.upsert(makeEntry(key: "b", size: 250))
        index.upsert(makeEntry(key: "c", size: 50))

        XCTAssertEqual(index.count(), 3)
        XCTAssertEqual(index.totalSize(), 400)
    }

    // MARK: - Deletion

    func testDeleteSingle() {
        index.upsert(makeEntry(key: "gone"))
        XCTAssertNotNil(index.get(key: "gone"))
        index.delete(key: "gone")
        XCTAssertNil(index.get(key: "gone"))
    }

    func testDeleteAll() {
        for i in 0..<5 {
            index.upsert(makeEntry(key: "k\(i)", size: Int64(100 * i)))
        }
        XCTAssertEqual(index.count(), 5)
        index.deleteAll()
        XCTAssertEqual(index.count(), 0)
        XCTAssertEqual(index.totalSize(), 0)
    }

    // MARK: - Listing

    func testAllEntriesOrderedByFirstCachedDesc() {
        let base = CacheIndex.nowMs()
        index.upsert(makeEntry(key: "old",    firstCachedAt: base - 2000))
        index.upsert(makeEntry(key: "newest", firstCachedAt: base))
        index.upsert(makeEntry(key: "middle", firstCachedAt: base - 1000))

        let list = index.allEntries()
        XCTAssertEqual(list.map(\.key), ["newest", "middle", "old"])
    }

    // MARK: - Persistence across opens

    func testPersistenceAcrossReopen() throws {
        let dbURL = tempDir.appendingPathComponent("reopen.sqlite")
        let first = try CacheIndex(dbURL: dbURL)
        first.upsert(makeEntry(key: "persists", size: 777))
        first.recordHit(key: "persists")

        // Closing the first handle (release + open new one)
        let second = try CacheIndex(dbURL: dbURL)
        let fetched = second.get(key: "persists")
        XCTAssertEqual(fetched?.sizeBytes, 777)
        XCTAssertEqual(fetched?.hitCount, 1)
    }

    // MARK: - Concurrent hits

    func testConcurrentRecordHitIsAtomic() {
        index.upsert(makeEntry(key: "contested"))

        let iterations = 500
        let expectation = expectation(description: "all hits recorded")
        expectation.expectedFulfillmentCount = iterations
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        for _ in 0..<iterations {
            queue.async {
                self.index.recordHit(key: "contested")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 10)

        XCTAssertEqual(index.get(key: "contested")?.hitCount, Int64(iterations))
    }

    // MARK: - Capsules

    func testCreateAndListCapsules() {
        let c1 = index.createCapsule(name: "Apple 1997")
        let c2 = index.createCapsule(name: "Y2K News", description: "Jan 2000 front pages")
        XCTAssertNotNil(c1)
        XCTAssertNotNil(c2)

        let list = index.listCapsules()
        XCTAssertEqual(list.count, 2)
        // Newest first
        XCTAssertEqual(list.first?.name, "Y2K News")
        XCTAssertEqual(list.first?.description, "Jan 2000 front pages")
        XCTAssertEqual(list.first?.memberCount, 0)
    }

    func testAddAndListMembers() {
        index.upsert(makeEntry(key: "a"))
        index.upsert(makeEntry(key: "b"))
        index.upsert(makeEntry(key: "c"))
        guard let cap = index.createCapsule(name: "Curated") else {
            return XCTFail("capsule create failed")
        }

        index.addToCapsule(id: cap.id, keys: ["a", "b"])
        XCTAssertEqual(Set(index.membersOfCapsule(id: cap.id)), ["a", "b"])

        let list = index.listCapsules()
        XCTAssertEqual(list.first?.memberCount, 2)
    }

    func testAddDuplicateMemberIsIgnored() {
        index.upsert(makeEntry(key: "a"))
        guard let cap = index.createCapsule(name: "dup") else {
            return XCTFail()
        }
        index.addToCapsule(id: cap.id, keys: ["a", "a", "a"])
        XCTAssertEqual(index.membersOfCapsule(id: cap.id), ["a"])
    }

    func testRemoveMembers() {
        index.upsert(makeEntry(key: "a"))
        index.upsert(makeEntry(key: "b"))
        guard let cap = index.createCapsule(name: "tmp") else {
            return XCTFail()
        }
        index.addToCapsule(id: cap.id, keys: ["a", "b"])
        index.removeFromCapsule(id: cap.id, keys: ["a"])
        XCTAssertEqual(index.membersOfCapsule(id: cap.id), ["b"])
    }

    func testDeleteCapsuleCascadesMembers() {
        index.upsert(makeEntry(key: "a"))
        guard let cap = index.createCapsule(name: "bye") else { return XCTFail() }
        index.addToCapsule(id: cap.id, keys: ["a"])

        index.deleteCapsule(id: cap.id)
        XCTAssertTrue(index.listCapsules().isEmpty)
        XCTAssertTrue(index.membersOfCapsule(id: cap.id).isEmpty)
        // The entry itself must remain untouched
        XCTAssertNotNil(index.get(key: "a"))
    }

    func testDeleteEntryRemovesFromAllCapsules() {
        index.upsert(makeEntry(key: "shared"))
        guard let cap1 = index.createCapsule(name: "one"),
              let cap2 = index.createCapsule(name: "two") else {
            return XCTFail()
        }
        index.addToCapsule(id: cap1.id, keys: ["shared"])
        index.addToCapsule(id: cap2.id, keys: ["shared"])

        index.delete(key: "shared")
        XCTAssertTrue(index.membersOfCapsule(id: cap1.id).isEmpty)
        XCTAssertTrue(index.membersOfCapsule(id: cap2.id).isEmpty)
    }

    func testRenameCapsule() {
        guard let cap = index.createCapsule(name: "Original") else { return XCTFail() }
        index.renameCapsule(id: cap.id, newName: "Renamed", description: "now with subtitle")

        let list = index.listCapsules()
        XCTAssertEqual(list.first?.name, "Renamed")
        XCTAssertEqual(list.first?.description, "now with subtitle")
    }

    // MARK: - FTS

    func testFTSInsertAndSearch() {
        index.upsert(makeEntry(key: "apple"))
        index.upsert(makeEntry(key: "microsoft"))
        index.upsertFTS(key: "apple", content: "Think Different. Macintosh PowerBook G3.")
        index.upsertFTS(key: "microsoft", content: "Windows 98 — where do you want to go today?")

        XCTAssertEqual(index.ftsCount(), 2)

        let appleHits = index.searchFTS(query: "powerbook")
        XCTAssertEqual(appleHits.map(\.key), ["apple"])
        XCTAssertTrue(appleHits.first?.snippet.contains("<b>PowerBook</b>") == true,
                      "snippet should highlight the match")

        let msHits = index.searchFTS(query: "windows")
        XCTAssertEqual(msHits.map(\.key), ["microsoft"])

        let bothHits = Set(index.searchFTS(query: "macintosh OR windows").map(\.key))
        XCTAssertEqual(bothHits, ["apple", "microsoft"])
    }

    func testFTSPorterStemming() {
        index.upsert(makeEntry(key: "e"))
        index.upsertFTS(key: "e", content: "She was running through the fields")

        // Porter stemmer should match 'running' → 'run'
        XCTAssertEqual(index.searchFTS(query: "runs").map(\.key), ["e"])
    }

    func testFTSRemovedOnDelete() {
        index.upsert(makeEntry(key: "tmp"))
        index.upsertFTS(key: "tmp", content: "discoverable phrase here")
        XCTAssertFalse(index.searchFTS(query: "discoverable").isEmpty)

        index.delete(key: "tmp")
        XCTAssertTrue(index.searchFTS(query: "discoverable").isEmpty)
        XCTAssertEqual(index.ftsCount(), 0)
    }

    func testFTSClearOnDeleteMany() {
        index.upsert(makeEntry(key: "a"))
        index.upsert(makeEntry(key: "b"))
        index.upsertFTS(key: "a", content: "foo bar")
        index.upsertFTS(key: "b", content: "foo baz")
        XCTAssertEqual(index.ftsCount(), 2)

        index.deleteMany(keys: ["a", "b"])
        XCTAssertEqual(index.ftsCount(), 0)
    }

    func testFTSEmptyQueryReturnsNothing() {
        index.upsert(makeEntry(key: "x"))
        index.upsertFTS(key: "x", content: "anything at all")
        XCTAssertTrue(index.searchFTS(query: "").isEmpty)
        XCTAssertTrue(index.searchFTS(query: "   ").isEmpty)
    }

    // MARK: - Tags

    func testSetAndGetTags() {
        index.upsert(makeEntry(key: "tagged"))
        index.setTags(key: "tagged", tags: ["Apple", "  Retro  ", "apple", ""])
        // Normalization: trim + lowercase + dedupe + drop empty → ["apple", "retro"]
        XCTAssertEqual(index.tagsFor(key: "tagged"), ["apple", "retro"])
    }

    func testSetTagsReplacesExisting() {
        index.upsert(makeEntry(key: "k"))
        index.setTags(key: "k", tags: ["old", "ancient"])
        XCTAssertEqual(Set(index.tagsFor(key: "k")), ["old", "ancient"])

        index.setTags(key: "k", tags: ["fresh"])
        XCTAssertEqual(index.tagsFor(key: "k"), ["fresh"])
    }

    func testSetTagsEmptyRemovesAll() {
        index.upsert(makeEntry(key: "k"))
        index.setTags(key: "k", tags: ["foo", "bar"])
        index.setTags(key: "k", tags: [] as [String])
        XCTAssertTrue(index.tagsFor(key: "k").isEmpty)
    }

    func testAllTagsDistinctAndSorted() {
        index.upsert(makeEntry(key: "a"))
        index.upsert(makeEntry(key: "b"))
        index.setTags(key: "a", tags: ["retro", "apple"])
        index.setTags(key: "b", tags: ["apple", "y2k"])
        XCTAssertEqual(index.allTags(), ["apple", "retro", "y2k"])
    }

    func testTagsCascadeOnEntryDelete() {
        index.upsert(makeEntry(key: "doomed"))
        index.setTags(key: "doomed", tags: ["temp"])
        XCTAssertFalse(index.allTags().isEmpty)

        index.delete(key: "doomed")
        XCTAssertTrue(index.allTags().isEmpty)
    }

    // MARK: - Notes

    func testSetNote() {
        index.upsert(makeEntry(key: "k"))
        XCTAssertNil(index.get(key: "k")?.note)

        index.setNote(key: "k", note: "found via reddit")
        XCTAssertEqual(index.get(key: "k")?.note, "found via reddit")

        index.setNote(key: "k", note: nil)
        XCTAssertNil(index.get(key: "k")?.note)

        index.setNote(key: "k", note: "")   // empty string treated as nil
        XCTAssertNil(index.get(key: "k")?.note)
    }

    // MARK: - Cache stats summary

    func testCacheStatsSummary() {
        index.upsert(makeEntry(key: "a", size: 1_000))
        index.upsert(makeEntry(key: "b", size: 2_500))
        // 3 hits on a (1000 bytes each), 2 hits on b (2500 bytes each)
        for _ in 0..<3 { index.recordHit(key: "a") }
        for _ in 0..<2 { index.recordHit(key: "b") }

        let (hits, bytesAvoided) = index.cacheStatsSummary()
        XCTAssertEqual(hits, 5)
        XCTAssertEqual(bytesAvoided, 3 * 1_000 + 2 * 2_500)
    }

    func testCacheStatsSummaryEmpty() {
        let (hits, bytes) = index.cacheStatsSummary()
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(bytes, 0)
    }

    // MARK: - Helpers

    private func makeEntry(
        key: String,
        waybackURL: String = "https://web.archive.org/web/19970615000000/http://apple.com/",
        originalURL: String = "http://apple.com/",
        domain: String = "apple.com",
        waybackDate: String? = "19970615",
        contentType: String = "text/html",
        size: Int64 = 1024,
        firstCachedAt: Int64? = nil,
        lastAccessedAt: Int64? = nil
    ) -> CacheEntryMetadata {
        let now = firstCachedAt ?? CacheIndex.nowMs()
        return CacheEntryMetadata(
            key: key,
            waybackURL: waybackURL,
            originalURL: originalURL,
            domain: domain,
            waybackDate: waybackDate,
            contentType: contentType,
            sizeBytes: size,
            firstCachedAt: now,
            lastAccessedAt: lastAccessedAt ?? now
        )
    }
}
