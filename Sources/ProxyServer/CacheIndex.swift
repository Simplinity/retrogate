import Foundation
import SQLite3
import NIOConcurrencyHelpers
import Logging

/// SQLite destructor marker: ask SQLite to copy the bound bytes so the source
/// can be safely deallocated after the bind call returns.
internal let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1)!,
    to: sqlite3_destructor_type.self
)

// MARK: - Model

/// Metadata for a single cached response. The bytes themselves live in
/// `~/Library/Caches/RetroGate/blobs/<key>`; this struct is the sidecar row.
public struct CacheEntryMetadata: Sendable, Equatable {
    public var key: String
    public var waybackURL: String
    public var originalURL: String
    public var domain: String
    public var waybackDate: String?
    public var contentType: String
    public var sizeBytes: Int64
    public var firstCachedAt: Int64
    public var lastAccessedAt: Int64
    public var hitCount: Int64
    public var pinned: Bool
    public var note: String?

    public init(
        key: String,
        waybackURL: String,
        originalURL: String,
        domain: String,
        waybackDate: String?,
        contentType: String,
        sizeBytes: Int64,
        firstCachedAt: Int64,
        lastAccessedAt: Int64,
        hitCount: Int64 = 0,
        pinned: Bool = false,
        note: String? = nil
    ) {
        self.key = key
        self.waybackURL = waybackURL
        self.originalURL = originalURL
        self.domain = domain
        self.waybackDate = waybackDate
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.firstCachedAt = firstCachedAt
        self.lastAccessedAt = lastAccessedAt
        self.hitCount = hitCount
        self.pinned = pinned
        self.note = note
    }
}

public enum CacheIndexError: Error {
    case openFailed(String)
    case migrationFailed(String)
}

/// A named collection of cached entries — think "playlist" for pages.
/// Members are referenced by cache key; the blob lives in the main cache.
public struct CacheCapsule: Sendable, Identifiable, Equatable {
    public var id: String               // UUID string
    public var name: String
    public var createdAt: Int64         // unix ms
    public var description: String?
    public var memberCount: Int

    public init(id: String, name: String, createdAt: Int64, description: String?, memberCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.description = description
        self.memberCount = memberCount
    }
}

// MARK: - Index

/// SQLite-backed metadata index for the response cache.
///
/// The blob files in `blobs/` are the authoritative bytes. The index adds
/// metadata — URL, domain, wayback date, size, hit count, pinned, tags —
/// so the UI can browse, filter, and manage the cache without opening files.
///
/// Lock discipline: a single NIOLock serializes every statement. SQLite is
/// compiled with FULLMUTEX, so calls are safe across threads, and the lock
/// keeps prepared-statement lifetimes tidy.
public final class CacheIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NIOLock()
    private let logger: Logger
    private let dbURL: URL

    /// Current schema version. Bump when migrations are added.
    public static let schemaVersion: Int32 = 1

    public init(dbURL: URL, logger: Logger? = nil) throws {
        self.dbURL = dbURL
        var log = logger ?? Logger(label: "app.retrogate.cacheindex")
        log.logLevel = .info
        self.logger = log
        try openDatabase()
        try migrate()
    }

    deinit {
        if db != nil { sqlite3_close_v2(db) }
    }

    // MARK: Open & migrate

    private func openDatabase() throws {
        // Ensure parent dir exists (caller should have done so, but be defensive)
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        if rc != SQLITE_OK {
            throw CacheIndexError.openFailed("sqlite3_open_v2 rc=\(rc) path=\(dbURL.path)")
        }
        execOrLog("PRAGMA journal_mode=WAL;")
        execOrLog("PRAGMA synchronous=NORMAL;")
        execOrLog("PRAGMA foreign_keys=ON;")
    }

    private func migrate() throws {
        let current = userVersion()
        if current < 1 {
            try applyV1()
            setUserVersion(1)
        }
        // Future migrations land here as `if current < 2 { applyV2() }` etc.
    }

    private func applyV1() throws {
        let ddl = """
        CREATE TABLE entries (
            key TEXT PRIMARY KEY,
            wayback_url TEXT NOT NULL,
            original_url TEXT NOT NULL,
            domain TEXT NOT NULL,
            wayback_date TEXT,
            content_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            first_cached_at INTEGER NOT NULL,
            last_accessed_at INTEGER NOT NULL,
            hit_count INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            note TEXT
        );
        CREATE INDEX idx_entries_domain ON entries(domain);
        CREATE INDEX idx_entries_last_accessed ON entries(last_accessed_at);
        CREATE INDEX idx_entries_pinned ON entries(pinned) WHERE pinned = 1;
        CREATE INDEX idx_entries_original_url ON entries(original_url);

        CREATE TABLE tags (
            key TEXT NOT NULL,
            tag TEXT NOT NULL,
            PRIMARY KEY (key, tag),
            FOREIGN KEY (key) REFERENCES entries(key) ON DELETE CASCADE
        );
        CREATE INDEX idx_tags_tag ON tags(tag);

        CREATE TABLE capsules (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            description TEXT
        );
        CREATE TABLE capsule_members (
            capsule_id TEXT NOT NULL,
            key TEXT NOT NULL,
            PRIMARY KEY (capsule_id, key),
            FOREIGN KEY (capsule_id) REFERENCES capsules(id) ON DELETE CASCADE,
            FOREIGN KEY (key) REFERENCES entries(key) ON DELETE CASCADE
        );
        CREATE INDEX idx_capsule_members_key ON capsule_members(key);

        CREATE VIRTUAL TABLE entries_fts USING fts5(
            key UNINDEXED,
            content,
            tokenize = 'porter unicode61 remove_diacritics 2'
        );
        """
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw CacheIndexError.migrationFailed("schema v1: \(msg)")
        }
    }

    // MARK: Public API — entries

    /// Insert or update a cache entry. On conflict, preserve `hit_count`,
    /// `pinned`, `note`, and `first_cached_at` — only the fresh fetch data
    /// is updated.
    public func upsert(_ entry: CacheEntryMetadata) {
        lock.withLock {
            let sql = """
            INSERT INTO entries
                (key, wayback_url, original_url, domain, wayback_date, content_type,
                 size_bytes, first_cached_at, last_accessed_at, hit_count, pinned, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                wayback_url      = excluded.wayback_url,
                original_url     = excluded.original_url,
                domain           = excluded.domain,
                wayback_date     = excluded.wayback_date,
                content_type     = excluded.content_type,
                size_bytes       = excluded.size_bytes,
                last_accessed_at = excluded.last_accessed_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.warning("cache upsert: prepare failed: \(lastError())")
                return
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, entry.key)
            bindText(stmt, 2, entry.waybackURL)
            bindText(stmt, 3, entry.originalURL)
            bindText(stmt, 4, entry.domain)
            bindOptText(stmt, 5, entry.waybackDate)
            bindText(stmt, 6, entry.contentType)
            sqlite3_bind_int64(stmt, 7, entry.sizeBytes)
            sqlite3_bind_int64(stmt, 8, entry.firstCachedAt)
            sqlite3_bind_int64(stmt, 9, entry.lastAccessedAt)
            sqlite3_bind_int64(stmt, 10, entry.hitCount)
            sqlite3_bind_int(stmt, 11, entry.pinned ? 1 : 0)
            bindOptText(stmt, 12, entry.note)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                logger.warning("cache upsert: step rc=\(rc): \(lastError())")
            }
        }
    }

    /// Atomically increment hit count and refresh `last_accessed_at`.
    /// Called on every cache hit — must stay cheap.
    public func recordHit(key: String, at timestampMs: Int64 = CacheIndex.nowMs()) {
        lock.withLock {
            let sql = """
            UPDATE entries
            SET hit_count = hit_count + 1, last_accessed_at = ?
            WHERE key = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, timestampMs)
            bindText(stmt, 2, key)
            _ = sqlite3_step(stmt)
        }
    }

    public func get(key: String) -> CacheEntryMetadata? {
        lock.withLock {
            let sql = """
            SELECT wayback_url, original_url, domain, wayback_date, content_type,
                   size_bytes, first_cached_at, last_accessed_at, hit_count, pinned, note
            FROM entries WHERE key = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return CacheEntryMetadata(
                key: key,
                waybackURL: columnText(stmt, 0) ?? "",
                originalURL: columnText(stmt, 1) ?? "",
                domain: columnText(stmt, 2) ?? "",
                waybackDate: columnText(stmt, 3),
                contentType: columnText(stmt, 4) ?? "",
                sizeBytes: sqlite3_column_int64(stmt, 5),
                firstCachedAt: sqlite3_column_int64(stmt, 6),
                lastAccessedAt: sqlite3_column_int64(stmt, 7),
                hitCount: sqlite3_column_int64(stmt, 8),
                pinned: sqlite3_column_int(stmt, 9) != 0,
                note: columnText(stmt, 10)
            )
        }
    }

    public func delete(key: String) {
        lock.withLock {
            // entries_fts is a virtual table, so FK cascade can't touch it.
            // Clean it up manually alongside the entries row.
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM entries_fts WHERE key = ?;", -1, &ftsStmt, nil) == SQLITE_OK {
                bindText(ftsStmt, 1, key)
                _ = sqlite3_step(ftsStmt)
            }
            sqlite3_finalize(ftsStmt)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            _ = sqlite3_step(stmt)
        }
    }

    /// Wipe every row in every table. Foreign-key cascades handle child rows.
    public func deleteAll() {
        lock.withLock {
            execOrLog("DELETE FROM capsule_members;")
            execOrLog("DELETE FROM capsules;")
            execOrLog("DELETE FROM tags;")
            execOrLog("DELETE FROM entries_fts;")
            execOrLog("DELETE FROM entries;")
        }
    }

    public func count() -> Int64 {
        singleValue("SELECT COUNT(*) FROM entries;")
    }

    public func totalSize() -> Int64 {
        singleValue("SELECT COALESCE(SUM(size_bytes), 0) FROM entries;")
    }

    /// Set or clear the pinned flag for a single entry.
    public func setPinned(key: String, pinned: Bool) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE entries SET pinned = ? WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            bindText(stmt, 2, key)
            _ = sqlite3_step(stmt)
        }
    }

    /// Iterate every entry as lightweight eviction candidates (no URL / content-type overhead).
    /// Used by the eviction policy to decide what to delete.
    public func evictionCandidates() -> [CacheEvictionPolicy.Candidate] {
        lock.withLock {
            let sql = "SELECT key, size_bytes, last_accessed_at, pinned FROM entries;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [CacheEvictionPolicy.Candidate] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(CacheEvictionPolicy.Candidate(
                    key: columnText(stmt, 0) ?? "",
                    sizeBytes: sqlite3_column_int64(stmt, 1),
                    lastAccessedAt: sqlite3_column_int64(stmt, 2),
                    pinned: sqlite3_column_int(stmt, 3) != 0
                ))
            }
            return results
        }
    }

    /// Bulk-delete entries in a single transaction. Much faster than calling
    /// `delete(key:)` in a loop when evicting hundreds at once.
    public func deleteMany(keys: some Collection<String>) {
        guard !keys.isEmpty else { return }
        lock.withLock {
            execOrLog("BEGIN IMMEDIATE;")
            var ftsStmt: OpaquePointer?
            var entryStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM entries_fts WHERE key = ?;", -1, &ftsStmt, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "DELETE FROM entries WHERE key = ?;", -1, &entryStmt, nil) == SQLITE_OK else {
                sqlite3_finalize(ftsStmt)
                sqlite3_finalize(entryStmt)
                execOrLog("ROLLBACK;")
                return
            }
            defer {
                sqlite3_finalize(ftsStmt)
                sqlite3_finalize(entryStmt)
            }
            for key in keys {
                sqlite3_reset(ftsStmt)
                sqlite3_clear_bindings(ftsStmt)
                bindText(ftsStmt, 1, key)
                _ = sqlite3_step(ftsStmt)

                sqlite3_reset(entryStmt)
                sqlite3_clear_bindings(entryStmt)
                bindText(entryStmt, 1, key)
                _ = sqlite3_step(entryStmt)
            }
            execOrLog("COMMIT;")
        }
    }

    /// Return all entries, newest-cached first. Intended for UI display.
    /// Not yet paginated — fine for tens of thousands of rows thanks to the index.
    public func allEntries(limit: Int = 5000) -> [CacheEntryMetadata] {
        lock.withLock {
            let sql = """
            SELECT key, wayback_url, original_url, domain, wayback_date, content_type,
                   size_bytes, first_cached_at, last_accessed_at, hit_count, pinned, note
            FROM entries
            ORDER BY first_cached_at DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var results: [CacheEntryMetadata] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(CacheEntryMetadata(
                    key: columnText(stmt, 0) ?? "",
                    waybackURL: columnText(stmt, 1) ?? "",
                    originalURL: columnText(stmt, 2) ?? "",
                    domain: columnText(stmt, 3) ?? "",
                    waybackDate: columnText(stmt, 4),
                    contentType: columnText(stmt, 5) ?? "",
                    sizeBytes: sqlite3_column_int64(stmt, 6),
                    firstCachedAt: sqlite3_column_int64(stmt, 7),
                    lastAccessedAt: sqlite3_column_int64(stmt, 8),
                    hitCount: sqlite3_column_int64(stmt, 9),
                    pinned: sqlite3_column_int(stmt, 10) != 0,
                    note: columnText(stmt, 11)
                ))
            }
            return results
        }
    }

    // MARK: Public API — full-text search

    /// A single hit from the FTS index.
    public struct FTSHit: Sendable, Equatable {
        public let key: String
        /// HTML-ish snippet with `<b>...</b>` around matching terms. Safe to
        /// render with a simple formatter; FTS5 escapes content automatically.
        public let snippet: String
        /// FTS5 rank. More-negative = better match. Opaque to callers.
        public let rank: Double
    }

    /// Insert or replace the indexed content for a key.
    /// Caller is responsible for deciding *what* is worth indexing
    /// (typically only HTML after stripping tags).
    public func upsertFTS(key: String, content: String) {
        lock.withLock {
            // FTS5 virtual tables don't support UPSERT, so remove + insert.
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM entries_fts WHERE key = ?;", -1, &delStmt, nil) == SQLITE_OK {
                bindText(delStmt, 1, key)
                _ = sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            var insStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO entries_fts (key, content) VALUES (?, ?);", -1, &insStmt, nil) == SQLITE_OK {
                bindText(insStmt, 1, key)
                bindText(insStmt, 2, content)
                _ = sqlite3_step(insStmt)
            }
            sqlite3_finalize(insStmt)
        }
    }

    /// Run an FTS5 search and return hits sorted by relevance.
    /// `query` supports the full FTS5 grammar: phrases in quotes, AND / OR,
    /// `column: term`, NEAR, prefix wildcards, etc. A nil/empty query returns nothing.
    public func searchFTS(query: String, limit: Int = 200) -> [FTSHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return lock.withLock {
            let sql = """
            SELECT key,
                   snippet(entries_fts, 1, '<b>', '</b>', '…', 12),
                   rank
            FROM entries_fts
            WHERE entries_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.debug("searchFTS prepare failed: \(lastError())")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, trimmed)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [FTSHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(FTSHit(
                    key: columnText(stmt, 0) ?? "",
                    snippet: columnText(stmt, 1) ?? "",
                    rank: sqlite3_column_double(stmt, 2)
                ))
            }
            return results
        }
    }

    /// Total rows in the FTS index. `0` means nothing has been indexed yet.
    public func ftsCount() -> Int64 {
        singleValue("SELECT COUNT(*) FROM entries_fts;")
    }

    /// Remove every row from the FTS index. Does not touch `entries`.
    /// Useful before a full rebuild.
    public func clearFTS() {
        lock.withLock { execOrLog("DELETE FROM entries_fts;") }
    }

    // MARK: Public API — tags

    /// Replace the entire tag set for a key. Empty set removes all tags.
    /// Normalizes: trims whitespace, drops empty strings, lowercases.
    public func setTags(key: String, tags: some Collection<String>) {
        let normalized = Set(tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        lock.withLock {
            execOrLog("BEGIN IMMEDIATE;")
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM tags WHERE key = ?;", -1, &delStmt, nil) == SQLITE_OK {
                bindText(delStmt, 1, key)
                _ = sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            if !normalized.isEmpty {
                var insStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO tags (key, tag) VALUES (?, ?);", -1, &insStmt, nil) == SQLITE_OK else {
                    execOrLog("ROLLBACK;")
                    return
                }
                defer { sqlite3_finalize(insStmt) }
                for tag in normalized {
                    sqlite3_reset(insStmt)
                    sqlite3_clear_bindings(insStmt)
                    bindText(insStmt, 1, key)
                    bindText(insStmt, 2, tag)
                    _ = sqlite3_step(insStmt)
                }
            }
            execOrLog("COMMIT;")
        }
    }

    public func tagsFor(key: String) -> [String] {
        lock.withLock {
            let sql = "SELECT tag FROM tags WHERE key = ? ORDER BY tag;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = columnText(stmt, 0) { results.append(t) }
            }
            return results
        }
    }

    /// Return every tag assignment as a `[key: [tags]]` map, so the UI can
    /// decorate the whole table in one query instead of N round-trips.
    public func tagsByKey() -> [String: [String]] {
        lock.withLock {
            let sql = "SELECT key, tag FROM tags ORDER BY key, tag;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var result: [String: [String]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = columnText(stmt, 0) ?? ""
                let tag = columnText(stmt, 1) ?? ""
                result[key, default: []].append(tag)
            }
            return result
        }
    }

    /// All distinct tags in use, sorted. Cheap; `idx_tags_tag` covers the scan.
    public func allTags() -> [String] {
        lock.withLock {
            let sql = "SELECT DISTINCT tag FROM tags ORDER BY tag;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let t = columnText(stmt, 0) { results.append(t) }
            }
            return results
        }
    }

    /// Update just the note column without touching the rest of the row.
    /// Useful for the detail drawer: don't force callers to re-upsert everything.
    public func setNote(key: String, note: String?) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE entries SET note = ? WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindOptText(stmt, 1, note?.isEmpty == true ? nil : note)
            bindText(stmt, 2, key)
            _ = sqlite3_step(stmt)
        }
    }

    /// Aggregate: how much has the cache earned its keep.
    /// `hits` = total cache-hit count across all entries.
    /// `bytesAvoided` = total bytes not-re-downloaded (size × hits per entry).
    public func cacheStatsSummary() -> (hits: Int64, bytesAvoided: Int64) {
        lock.withLock {
            let sql = """
            SELECT COALESCE(SUM(hit_count), 0),
                   COALESCE(SUM(size_bytes * hit_count), 0)
            FROM entries;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
            defer { sqlite3_finalize(stmt) }
            return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
        }
    }

    // MARK: Public API — capsules

    /// Create a new capsule. Returns the capsule id on success; nil on conflict.
    @discardableResult
    public func createCapsule(name: String, description: String? = nil) -> CacheCapsule? {
        let id = UUID().uuidString
        let now = Self.nowMs()
        let ok = lock.withLock { () -> Bool in
            let sql = "INSERT INTO capsules (id, name, created_at, description) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            bindText(stmt, 2, name)
            sqlite3_bind_int64(stmt, 3, now)
            bindOptText(stmt, 4, description)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
        guard ok else { return nil }
        return CacheCapsule(id: id, name: name, createdAt: now, description: description, memberCount: 0)
    }

    public func renameCapsule(id: String, newName: String, description: String? = nil) {
        lock.withLock {
            let sql = "UPDATE capsules SET name = ?, description = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, newName)
            bindOptText(stmt, 2, description)
            bindText(stmt, 3, id)
            _ = sqlite3_step(stmt)
        }
    }

    public func deleteCapsule(id: String) {
        lock.withLock {
            let sql = "DELETE FROM capsules WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            _ = sqlite3_step(stmt)
            // capsule_members rows cascade on FK.
        }
    }

    /// Add cache keys to a capsule. Duplicate memberships are silently ignored.
    public func addToCapsule(id capsuleId: String, keys: some Collection<String>) {
        guard !keys.isEmpty else { return }
        lock.withLock {
            execOrLog("BEGIN IMMEDIATE;")
            let sql = "INSERT OR IGNORE INTO capsule_members (capsule_id, key) VALUES (?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                execOrLog("ROLLBACK;")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for key in keys {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, capsuleId)
                bindText(stmt, 2, key)
                _ = sqlite3_step(stmt)
            }
            execOrLog("COMMIT;")
        }
    }

    public func removeFromCapsule(id capsuleId: String, keys: some Collection<String>) {
        guard !keys.isEmpty else { return }
        lock.withLock {
            execOrLog("BEGIN IMMEDIATE;")
            let sql = "DELETE FROM capsule_members WHERE capsule_id = ? AND key = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                execOrLog("ROLLBACK;")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for key in keys {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, capsuleId)
                bindText(stmt, 2, key)
                _ = sqlite3_step(stmt)
            }
            execOrLog("COMMIT;")
        }
    }

    public func listCapsules() -> [CacheCapsule] {
        lock.withLock {
            let sql = """
            SELECT c.id, c.name, c.created_at, c.description,
                   (SELECT COUNT(*) FROM capsule_members m WHERE m.capsule_id = c.id) AS n
            FROM capsules c
            ORDER BY c.created_at DESC, c.rowid DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [CacheCapsule] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(CacheCapsule(
                    id: columnText(stmt, 0) ?? "",
                    name: columnText(stmt, 1) ?? "",
                    createdAt: sqlite3_column_int64(stmt, 2),
                    description: columnText(stmt, 3),
                    memberCount: Int(sqlite3_column_int64(stmt, 4))
                ))
            }
            return results
        }
    }

    public func membersOfCapsule(id capsuleId: String) -> [String] {
        lock.withLock {
            let sql = "SELECT key FROM capsule_members WHERE capsule_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, capsuleId)
            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let key = columnText(stmt, 0) { results.append(key) }
            }
            return results
        }
    }

    // MARK: Helpers

    public static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func userVersion() -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func setUserVersion(_ v: Int32) {
        execOrLog("PRAGMA user_version = \(v);")
    }

    private func singleValue(_ sql: String) -> Int64 {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func execOrLog(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            logger.warning("sqlite exec '\(sql)' rc=\(rc): \(msg)")
        }
    }

    private func lastError() -> String {
        guard let raw = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: raw)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String) {
        sqlite3_bind_text(stmt, idx, text, -1, SQLITE_TRANSIENT)
    }

    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ text: String?) {
        if let t = text {
            bindText(stmt, idx, t)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }
}
