import Foundation
import Logging

/// Export and import capsule bundles.
///
/// A bundle is a plain directory named `<capsule>.retrogate-capsule` with:
///
///     manifest.json          — metadata + the list of entries
///     blobs/<key>            — raw cache bytes (same format ResponseCache uses on disk)
///
/// Plain-directory format was chosen over zip for three reasons:
///   1. No extra library or /usr/bin/zip dependency — works in a sandboxed app.
///   2. Human-inspectable: Show Package Contents in Finder reveals the parts.
///   3. Cheap incremental export — blobs are already on disk, we just copy.
///
/// Forward compatibility: bump `Manifest.formatVersion` when adding fields.
/// Unknown fields on import are ignored; missing required fields throw.
public struct CapsuleBundler: Sendable {
    public static let bundleExtension = "retrogate-capsule"
    public static let manifestFilename = "manifest.json"
    public static let blobsDirName = "blobs"
    public static let currentFormatVersion: Int = 1

    public enum BundleError: LocalizedError {
        case destinationExists(URL)
        case invalidBundle(String)
        case missingBlob(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let url): return "Already exists: \(url.path)"
            case .invalidBundle(let msg): return "Invalid capsule bundle: \(msg)"
            case .missingBlob(let key): return "Missing blob for key \(key)"
            case .writeFailed(let msg): return "Write failed: \(msg)"
            }
        }
    }

    // MARK: - Manifest types

    public struct Manifest: Codable, Sendable {
        public var formatVersion: Int
        public var exportedAt: Int64
        public var capsule: CapsuleInfo
        public var entries: [EntryInfo]
    }

    public struct CapsuleInfo: Codable, Sendable {
        public var name: String
        public var description: String?
        public var createdAt: Int64
    }

    public struct EntryInfo: Codable, Sendable {
        public var key: String
        public var waybackURL: String
        public var originalURL: String
        public var domain: String
        public var waybackDate: String?
        public var contentType: String
        public var sizeBytes: Int64
        public var firstCachedAt: Int64
        public var pinned: Bool
        public var note: String?
    }

    private let logger: Logger

    public init(logger: Logger? = nil) {
        var log = logger ?? Logger(label: "app.retrogate.capsule")
        log.logLevel = .info
        self.logger = log
    }

    // MARK: - Export

    /// Write a capsule to `destination`. Fails if the destination already exists.
    public func export(
        capsuleId: String,
        destination: URL,
        index: CacheIndex,
        blobsDir: URL
    ) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw BundleError.destinationExists(destination)
        }

        // Fetch capsule + members + per-entry metadata.
        let capsules = index.listCapsules()
        guard let capsule = capsules.first(where: { $0.id == capsuleId }) else {
            throw BundleError.invalidBundle("capsule \(capsuleId) not found")
        }
        let keys = index.membersOfCapsule(id: capsuleId)

        var entries: [EntryInfo] = []
        entries.reserveCapacity(keys.count)
        for key in keys {
            guard let meta = index.get(key: key) else {
                logger.warning("Skipping missing member \(key) during export")
                continue
            }
            entries.append(EntryInfo(
                key: meta.key,
                waybackURL: meta.waybackURL,
                originalURL: meta.originalURL,
                domain: meta.domain,
                waybackDate: meta.waybackDate,
                contentType: meta.contentType,
                sizeBytes: meta.sizeBytes,
                firstCachedAt: meta.firstCachedAt,
                pinned: meta.pinned,
                note: meta.note
            ))
        }

        // Create bundle skeleton.
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let blobsOut = destination.appendingPathComponent(Self.blobsDirName, isDirectory: true)
        try fm.createDirectory(at: blobsOut, withIntermediateDirectories: true)

        // Copy each blob. Missing blobs log a warning but don't abort —
        // the capsule can still roundtrip metadata even if some bytes vanished.
        for entry in entries {
            let src = blobsDir.appendingPathComponent(entry.key)
            let dst = blobsOut.appendingPathComponent(entry.key)
            guard fm.fileExists(atPath: src.path) else {
                logger.warning("Missing blob for entry \(entry.key) — exporting manifest anyway")
                continue
            }
            try fm.copyItem(at: src, to: dst)
        }

        // Write manifest last so a partial write doesn't leave a "valid" bundle.
        let manifest = Manifest(
            formatVersion: Self.currentFormatVersion,
            exportedAt: CacheIndex.nowMs(),
            capsule: CapsuleInfo(
                name: capsule.name,
                description: capsule.description,
                createdAt: capsule.createdAt
            ),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let manifestURL = destination.appendingPathComponent(Self.manifestFilename)
        try data.write(to: manifestURL, options: .atomic)

        logger.info("Exported capsule '\(capsule.name)' with \(entries.count) entries to \(destination.lastPathComponent)")
    }

    // MARK: - Import

    /// Read a bundle from `source` and merge it into the local cache.
    /// Blobs already present with the same key are assumed identical (SHA-256-keyed),
    /// so they're preserved rather than overwritten.
    ///
    /// Returns the newly created `Capsule` on success.
    @discardableResult
    public func importBundle(
        from source: URL,
        index: CacheIndex,
        blobsDir: URL
    ) throws -> CacheCapsule {
        let fm = FileManager.default
        let manifestURL = source.appendingPathComponent(Self.manifestFilename)
        let blobsIn = source.appendingPathComponent(Self.blobsDirName, isDirectory: true)

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw BundleError.invalidBundle("missing \(Self.manifestFilename)")
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.formatVersion <= Self.currentFormatVersion else {
            throw BundleError.invalidBundle("format version \(manifest.formatVersion) is newer than supported \(Self.currentFormatVersion)")
        }

        // Create (or re-create) the capsule locally. Name collisions are fine;
        // user can rename afterward.
        guard let capsule = index.createCapsule(
            name: manifest.capsule.name,
            description: manifest.capsule.description
        ) else {
            throw BundleError.writeFailed("createCapsule failed")
        }

        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        var importedKeys: [String] = []
        importedKeys.reserveCapacity(manifest.entries.count)

        for entry in manifest.entries {
            // Copy blob if we don't already have it.
            let localBlob = blobsDir.appendingPathComponent(entry.key)
            let bundleBlob = blobsIn.appendingPathComponent(entry.key)
            if !fm.fileExists(atPath: localBlob.path), fm.fileExists(atPath: bundleBlob.path) {
                do {
                    try fm.copyItem(at: bundleBlob, to: localBlob)
                } catch {
                    logger.warning("Skipping entry \(entry.key): blob copy failed \(error)")
                    continue
                }
            }

            // Upsert metadata — upsert preserves hit_count / pinned / note on existing rows.
            let existing = index.get(key: entry.key)
            let meta = CacheEntryMetadata(
                key: entry.key,
                waybackURL: entry.waybackURL,
                originalURL: entry.originalURL,
                domain: entry.domain,
                waybackDate: entry.waybackDate,
                contentType: entry.contentType,
                sizeBytes: entry.sizeBytes,
                firstCachedAt: existing?.firstCachedAt ?? entry.firstCachedAt,
                lastAccessedAt: existing?.lastAccessedAt ?? entry.firstCachedAt,
                hitCount: existing?.hitCount ?? 0,
                pinned: existing?.pinned ?? entry.pinned,
                note: existing?.note ?? entry.note
            )
            index.upsert(meta)
            importedKeys.append(entry.key)
        }

        index.addToCapsule(id: capsule.id, keys: importedKeys)
        logger.info("Imported capsule '\(capsule.name)' with \(importedKeys.count) entries from \(source.lastPathComponent)")

        // Refetch so the returned Capsule has the up-to-date memberCount.
        if let fresh = index.listCapsules().first(where: { $0.id == capsule.id }) {
            return fresh
        }
        return capsule
    }
}
