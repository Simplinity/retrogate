import XCTest
@testable import ProxyServer

final class CapsuleBundlerTests: XCTestCase {
    var tempDir: URL!
    var cacheDir: URL!
    var blobsDir: URL!
    var index: CacheIndex!
    var bundler: CapsuleBundler!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrogate-bundler-tests-\(UUID().uuidString)", isDirectory: true)
        cacheDir = tempDir.appendingPathComponent("cache", isDirectory: true)
        blobsDir = cacheDir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        index = try CacheIndex(dbURL: cacheDir.appendingPathComponent("index.sqlite"))
        bundler = CapsuleBundler()
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Roundtrip

    func testExportImportRoundtrip() throws {
        // Seed 3 entries with matching blob files
        for key in ["aaa", "bbb", "ccc"] {
            index.upsert(entry(key: key, originalURL: "http://example.com/\(key)"))
            try writeBlob(key: key, contents: "blob-\(key)")
        }
        // Two of them in a capsule
        guard let cap = index.createCapsule(name: "Trip", description: "round") else {
            return XCTFail("capsule create failed")
        }
        index.addToCapsule(id: cap.id, keys: ["aaa", "ccc"])

        // Export to a new bundle
        let bundleURL = tempDir.appendingPathComponent("MyTrip.retrogate-capsule", isDirectory: true)
        try bundler.export(capsuleId: cap.id, destination: bundleURL, index: index, blobsDir: blobsDir)

        // Sanity: the bundle contents exist on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("blobs/aaa").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("blobs/ccc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("blobs/bbb").path),
                       "non-member blob should not be in the bundle")

        // Import into a fresh cache+index
        let freshDir = tempDir.appendingPathComponent("fresh", isDirectory: true)
        let freshBlobs = freshDir.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: freshBlobs, withIntermediateDirectories: true)
        let freshIndex = try CacheIndex(dbURL: freshDir.appendingPathComponent("index.sqlite"))

        let imported = try bundler.importBundle(from: bundleURL, index: freshIndex, blobsDir: freshBlobs)

        XCTAssertEqual(imported.name, "Trip")
        XCTAssertEqual(imported.description, "round")
        XCTAssertEqual(imported.memberCount, 2)

        let members = Set(freshIndex.membersOfCapsule(id: imported.id))
        XCTAssertEqual(members, ["aaa", "ccc"])

        // Blobs copied over with original contents
        XCTAssertEqual(try String(contentsOf: freshBlobs.appendingPathComponent("aaa")), "blob-aaa")
        XCTAssertEqual(try String(contentsOf: freshBlobs.appendingPathComponent("ccc")), "blob-ccc")

        // Metadata came through
        let aaa = freshIndex.get(key: "aaa")
        XCTAssertEqual(aaa?.originalURL, "http://example.com/aaa")
        XCTAssertEqual(aaa?.domain, "example.com")
    }

    // MARK: - Missing blobs

    func testExportContinuesWhenBlobMissing() throws {
        // Create an entry in the index but *don't* write its blob file
        index.upsert(entry(key: "ghost"))
        guard let cap = index.createCapsule(name: "Holes") else {
            return XCTFail("capsule create failed")
        }
        index.addToCapsule(id: cap.id, keys: ["ghost"])

        let bundleURL = tempDir.appendingPathComponent("Holes.retrogate-capsule", isDirectory: true)
        XCTAssertNoThrow(try bundler.export(capsuleId: cap.id, destination: bundleURL, index: index, blobsDir: blobsDir),
                         "Export should tolerate missing blobs")

        // Manifest should still have the entry
        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(CapsuleBundler.Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.entries.map(\.key), ["ghost"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("blobs/ghost").path))
    }

    // MARK: - Error paths

    func testExportRefusesOverwritingExistingDestination() throws {
        index.upsert(entry(key: "x"))
        guard let cap = index.createCapsule(name: "A") else {
            return XCTFail("capsule create failed")
        }
        index.addToCapsule(id: cap.id, keys: ["x"])

        let dest = tempDir.appendingPathComponent("Taken.retrogate-capsule", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try bundler.export(capsuleId: cap.id, destination: dest, index: index, blobsDir: blobsDir)
        )
    }

    func testImportFailsOnMissingManifest() throws {
        let dest = tempDir.appendingPathComponent("Bogus.retrogate-capsule", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try bundler.importBundle(from: dest, index: index, blobsDir: blobsDir)
        )
    }

    func testImportRejectsFutureFormatVersion() throws {
        let dest = tempDir.appendingPathComponent("FromFuture.retrogate-capsule", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let manifestText = """
        {
          "capsule": {"createdAt": 0, "name": "future"},
          "entries": [],
          "exportedAt": 0,
          "formatVersion": 999
        }
        """
        try manifestText.write(to: dest.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try bundler.importBundle(from: dest, index: index, blobsDir: blobsDir)
        )
    }

    // MARK: - Helpers

    private func entry(key: String, originalURL: String = "http://example.com/") -> CacheEntryMetadata {
        let now = CacheIndex.nowMs()
        return CacheEntryMetadata(
            key: key,
            waybackURL: "https://web.archive.org/web/19970615000000/\(originalURL)",
            originalURL: originalURL,
            domain: URL(string: originalURL)?.host ?? "",
            waybackDate: "19970615",
            contentType: "text/html",
            sizeBytes: 42,
            firstCachedAt: now,
            lastAccessedAt: now
        )
    }

    private func writeBlob(key: String, contents: String) throws {
        try contents.write(
            to: blobsDir.appendingPathComponent(key),
            atomically: true,
            encoding: .utf8
        )
    }
}
