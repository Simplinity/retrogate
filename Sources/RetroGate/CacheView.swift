import SwiftUI
#if canImport(ProxyServer)
import ProxyServer
#endif

// MARK: - Row model

/// UI-friendly, Identifiable wrapper around CacheEntryMetadata.
/// (CacheEntryMetadata itself is a transfer struct and not Identifiable.)
struct CacheRow: Identifiable, Hashable {
    let id: String  // SHA-256 prefix key
    let originalURL: String
    let domain: String
    let waybackDate: String?
    let contentType: String
    let sizeBytes: Int64
    let firstCachedAt: Int64
    let hitCount: Int64
    let pinned: Bool

    init(_ entry: CacheEntryMetadata) {
        self.id = entry.key
        self.originalURL = entry.originalURL
        self.domain = entry.domain
        self.waybackDate = entry.waybackDate
        self.contentType = entry.contentType
        self.sizeBytes = entry.sizeBytes
        self.firstCachedAt = entry.firstCachedAt
        self.hitCount = entry.hitCount
        self.pinned = entry.pinned
    }
}

/// Coarse content-type buckets for the filter dropdown.
enum ContentTypeFilter: String, CaseIterable, Identifiable {
    case all = "All types"
    case html = "HTML"
    case image = "Images"
    case stylesheet = "CSS"
    case javascript = "JavaScript"
    case other = "Other"

    var id: String { rawValue }

    func matches(_ contentType: String) -> Bool {
        let ct = contentType.lowercased()
        switch self {
        case .all: return true
        case .html: return ct.contains("text/html") || ct.contains("application/xhtml")
        case .image: return ct.hasPrefix("image/")
        case .stylesheet: return ct.contains("text/css")
        case .javascript: return ct.contains("javascript") || ct.contains("ecmascript")
        case .other:
            return !(ct.contains("text/html")
                     || ct.hasPrefix("image/")
                     || ct.contains("text/css")
                     || ct.contains("javascript"))
        }
    }
}

// MARK: - Cache view

struct CacheView: View {
    @EnvironmentObject var state: ProxyState

    @State private var rows: [CacheRow] = []
    @State private var totalBytes: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var oldestAt: Int64? = nil
    @State private var totalHits: Int64 = 0

    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<CacheRow>] = [
        KeyPathComparator(\CacheRow.firstCachedAt, order: .reverse)
    ]
    @State private var confirmClear = false

    // Filters
    @State private var searchText = ""
    @State private var domainFilter: String = ""   // empty = all
    @State private var typeFilter: ContentTypeFilter = .all
    @State private var pinnedOnly = false

    // Capsules
    @State private var capsules: [CacheCapsule] = []
    @State private var selectedCapsuleId: String? = nil    // nil = All
    @State private var capsuleMemberKeys: Set<String> = []
    @State private var capsuleNameDraft = ""
    @State private var capsuleDescriptionDraft = ""
    @State private var showCreateCapsule = false
    @State private var renameTarget: CacheCapsule? = nil
    @State private var capsuleAlert: CapsuleAlert? = nil

    // Prefetch
    @State private var showPrefetch = false

    // Full-text search
    @State private var contentSearchText: String = ""
    @State private var ftsHits: [CacheIndex.FTSHit] = []
    @State private var ftsIndexedCount: Int64 = 0
    @State private var isRebuildingIndex = false
    @State private var ftsRebuildProgress: (done: Int, total: Int) = (0, 0)

    // Tags & notes
    @State private var tagFilter: String = ""         // empty = all
    @State private var tagsByKey: [String: [String]] = [:]
    @State private var availableTags: [String] = []
    @State private var drawerTagsDraft: String = ""
    @State private var drawerNoteDraft: String = ""
    @State private var drawerMetadata: CacheEntryMetadata? = nil

    private struct CapsuleAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            offlineBanner
            header
                .padding(16)
            Divider()
            retentionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            capsuleBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            contentSearchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            tableArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
        .navigationTitle("Cache")
        .sheet(isPresented: $showCreateCapsule) {
            capsuleFormSheet(title: "New Capsule", isRename: false)
        }
        .sheet(item: $renameTarget) { _ in
            capsuleFormSheet(title: "Rename Capsule", isRename: true)
        }
        .sheet(isPresented: $showPrefetch) {
            PrefetchView { result in
                handlePrefetchResult(result)
            }
        }
        .alert(item: $capsuleAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private func handlePrefetchResult(_ result: PrefetchView.Result?) {
        defer { refresh() }
        guard let result = result,
              !result.succeededKeys.isEmpty,
              let name = result.capsuleName,
              let index = state.cacheIndex,
              let cap = index.createCapsule(name: name) else { return }
        index.addToCapsule(id: cap.id, keys: result.succeededKeys)
        selectedCapsuleId = cap.id
        capsuleMemberKeys = Set(result.succeededKeys)
    }

    // MARK: Offline banner

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: state.cacheOfflineMode ? "bolt.slash.fill" : "bolt")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.cacheOfflineMode ? Color.gold : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.cacheOfflineMode ? "Offline Mode" : "Offline Mode")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.cacheOfflineMode ? Color.gold : Color.primary)
                Text(state.cacheOfflineMode
                     ? "Cache misses return a 404 — no archive.org calls."
                     : "Only serve from cache (skip archive.org).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $state.cacheOfflineMode)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Serve only from cache; never call archive.org")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            state.cacheOfflineMode
                ? Color.gold.opacity(0.12)
                : Color.clear
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HeroStat(icon: "externaldrive", title: "Entries", value: "\(totalCount)")
            HeroStat(icon: "scalemass",     title: "On Disk",  value: formattedBytes(totalBytes))
            HeroStat(icon: "arrow.counterclockwise", title: "Hits", value: "\(totalHits)")
            HeroStat(icon: "calendar",      title: "Oldest",   value: oldestLabel)
        }
    }

    private var oldestLabel: String {
        guard let oldest = oldestAt, oldest > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(oldest) / 1000)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Retention controls

    private var retentionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge")
                .foregroundStyle(Color.gold)
                .font(.system(size: 13))
            Text("Retention")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.gold)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: 6) {
                Text("Max size")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("0", value: Binding(
                    get: { state.cacheMaxSizeMB },
                    set: { state.cacheMaxSizeMB = max(0, $0) }
                ), format: .number)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
                Text("MB")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(state.cacheMaxSizeMB == 0 ? "(unlimited)" : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("Auto-delete after")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("0", value: Binding(
                    get: { state.cacheMaxAgeDays },
                    set: { state.cacheMaxAgeDays = max(0, $0) }
                ), format: .number)
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)
                Text("days")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(state.cacheMaxAgeDays == 0 ? "(never)" : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                let evicted = state.responseCache?.sweep() ?? 0
                refresh()
                if evicted > 0 {
                    selection.removeAll()
                }
            } label: {
                Label("Sweep now", systemImage: "wind")
            }
            .controlSize(.small)
            .disabled(state.responseCache == nil || (state.cacheMaxSizeMB == 0 && state.cacheMaxAgeDays == 0))
            .help("Apply retention rules now and delete anything over the limits")
        }
    }

    // MARK: Capsule bar

    private var capsuleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Color.gold)
                .font(.system(size: 13))
            Text("Capsules")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.gold)
                .textCase(.uppercase)
                .tracking(0.8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    capsuleChip(
                        title: "All",
                        count: rows.count,
                        isActive: selectedCapsuleId == nil
                    ) {
                        selectedCapsuleId = nil
                        capsuleMemberKeys = []
                    }

                    ForEach(capsules) { capsule in
                        capsuleChip(
                            title: capsule.name,
                            count: capsule.memberCount,
                            isActive: selectedCapsuleId == capsule.id
                        ) {
                            selectCapsule(capsule)
                        }
                        .contextMenu { capsuleContextMenu(for: capsule) }
                    }
                }
            }

            Spacer()

            Button {
                beginCreateFromSelection()
            } label: {
                Label("New from selection", systemImage: "plus.square.on.square")
            }
            .disabled(selection.isEmpty || state.cacheIndex == nil)
            .controlSize(.small)
            .help("Create a capsule containing the currently-selected entries")

            Button {
                importCapsule()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .disabled(state.cacheIndex == nil)
            .controlSize(.small)
            .help("Import a .retrogate-capsule bundle")

            Button {
                showPrefetch = true
            } label: {
                Label("Prefetch…", systemImage: "tray.and.arrow.down")
            }
            .disabled(state.responseCache == nil || state.cacheOfflineMode)
            .controlSize(.small)
            .help(state.cacheOfflineMode
                  ? "Turn off Offline Mode to prefetch from archive.org"
                  : "Warm the cache by pasting a list of URLs")
        }
    }

    @ViewBuilder
    private func capsuleChip(title: String, count: Int, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.gold.opacity(0.22) : Color.gold.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isActive ? Color.gold.opacity(0.6) : Color.gold.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capsuleContextMenu(for capsule: CacheCapsule) -> some View {
        Button("Rename…") {
            capsuleNameDraft = capsule.name
            capsuleDescriptionDraft = capsule.description ?? ""
            renameTarget = capsule
        }
        Button("Export…") { exportCapsule(capsule) }
        Divider()
        Button("Delete Capsule", role: .destructive) {
            state.cacheIndex?.deleteCapsule(id: capsule.id)
            if selectedCapsuleId == capsule.id {
                selectedCapsuleId = nil
                capsuleMemberKeys = []
            }
            refresh()
        }
    }

    // MARK: Capsule create/rename sheet

    private func capsuleFormSheet(title: String, isRename: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("e.g. Apple 1997", text: $capsuleNameDraft)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description (optional)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("", text: $capsuleDescriptionDraft, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            if !isRename, !selection.isEmpty {
                Text("Will contain \(selection.count) currently-selected \(selection.count == 1 ? "entry" : "entries").")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showCreateCapsule = false
                    renameTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(isRename ? "Save" : "Create") {
                    if isRename, let target = renameTarget {
                        state.cacheIndex?.renameCapsule(
                            id: target.id,
                            newName: capsuleNameDraft.trimmingCharacters(in: .whitespaces),
                            description: capsuleDescriptionDraft.isEmpty ? nil : capsuleDescriptionDraft
                        )
                        renameTarget = nil
                    } else {
                        createCapsuleFromDraft()
                        showCreateCapsule = false
                    }
                    refresh()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capsuleNameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Filter by URL…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Picker("Domain", selection: $domainFilter) {
                Text("All domains").tag("")
                ForEach(availableDomains, id: \.self) { d in
                    Text(d).tag(d)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .labelsHidden()

            Picker("Type", selection: $typeFilter) {
                ForEach(ContentTypeFilter.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .labelsHidden()

            Picker("Tag", selection: $tagFilter) {
                Text("All tags").tag("")
                ForEach(availableTags, id: \.self) { t in Text(t).tag(t) }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()
            .disabled(availableTags.isEmpty)

            Toggle(isOn: $pinnedOnly) {
                Label("Pinned only", systemImage: "pin")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Spacer()

            if isFiltering {
                Button {
                    clearFilters()
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    private var isFiltering: Bool {
        !searchText.isEmpty || !domainFilter.isEmpty || typeFilter != .all
            || pinnedOnly || !contentSearchText.isEmpty || !tagFilter.isEmpty
    }

    private var isContentSearching: Bool {
        !contentSearchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clearFilters() {
        searchText = ""
        domainFilter = ""
        typeFilter = .all
        pinnedOnly = false
        contentSearchText = ""
        ftsHits = []
        tagFilter = ""
    }

    // MARK: Content search bar

    private var contentSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(Color.gold)
                .font(.system(size: 13))

            TextField("Search page contents (FTS5)…", text: $contentSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onChange(of: contentSearchText) { _ in runContentSearch() }

            if !contentSearchText.isEmpty {
                Text("\(ftsHits.count) matches")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRebuildingIndex {
                ProgressView(value: Double(ftsRebuildProgress.done),
                             total: Double(max(1, ftsRebuildProgress.total)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text("\(ftsRebuildProgress.done)/\(ftsRebuildProgress.total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                indexCoverageLabel
                Button {
                    rebuildFTSIndex()
                } label: {
                    Label("Build Index", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(state.responseCache == nil)
                .help("Re-scan every HTML page currently in cache and rebuild the search index")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var indexCoverageLabel: some View {
        let htmlCount = rows.filter { $0.contentType.lowercased().contains("text/html") }.count
        let indexed = Int(ftsIndexedCount)
        if htmlCount > 0 && indexed < htmlCount {
            Text("Index: \(indexed)/\(htmlCount) HTML pages")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        } else if indexed > 0 {
            Text("Index: \(indexed) pages")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("Index empty")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload the cache list from disk")

            Divider().frame(height: 14)

            Button {
                pinSelection(true)
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .disabled(selection.isEmpty)

            Button {
                pinSelection(false)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Spacer()

            Text(selectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Clear All", systemImage: "trash.slash")
            }
            .disabled(rows.isEmpty)
            .confirmationDialog(
                "Remove every cached entry?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) { clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every blob and metadata row. Pinned entries are also removed. This cannot be undone.")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    private var selectionSummary: String {
        if !selection.isEmpty {
            return "\(selection.count) of \(filteredRows.count) selected"
        }
        if isFiltering {
            return "\(filteredRows.count) of \(rows.count) shown"
        }
        return "\(rows.count) entries"
    }

    // MARK: Table

    private var tableArea: some View {
        HStack(spacing: 0) {
            tableContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selection.count == 1, let meta = drawerMetadata {
                Divider()
                detailDrawer(for: meta)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selection.count == 1)
        .onChange(of: selection) { _ in
            // Save pending drafts against whatever the drawer was last showing
            // before replacing it. Prevents a tag/note drafted for row A from
            // getting written to row B when the user clicks away.
            if let prev = drawerMetadata {
                saveDrawerTags(meta: prev)
                saveDrawerNote(meta: prev)
            }
            loadDrawerForSelection()
        }
    }

    @ViewBuilder
    private var tableContent: some View {
        if state.cacheIndex == nil {
            offlineState
        } else if rows.isEmpty {
            emptyState
        } else if filteredRows.isEmpty {
            noMatchesState
        } else {
            table
        }
    }

    private var table: some View {
        Table(sortedFilteredRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Image(systemName: row.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(row.pinned ? Color.gold : Color.secondary.opacity(0.25))
                    .font(.system(size: 11))
                    .onTapGesture {
                        togglePin(row)
                    }
                    .help(row.pinned ? "Unpin" : "Pin")
            }
            .width(20)

            TableColumn("URL", value: \.originalURL) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.originalURL)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isContentSearching, let snippet = snippetByKey[row.id] {
                        snippetText(snippet)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .help(row.originalURL)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Domain", value: \.domain) { row in
                Text(row.domain).font(.system(size: 12))
            }
            .width(min: 110, ideal: 160)

            TableColumn("Snapshot", value: \.waybackDateSortable) { row in
                Text(formatWaybackDate(row.waybackDate))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Type", value: \.contentType) { row in
                Text(shortContentType(row.contentType))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Size", value: \.sizeBytes) { row in
                Text(formattedBytes(row.sizeBytes))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)

            TableColumn("Hits", value: \.hitCount) { row in
                Text(row.hitCount == 0 ? "—" : "\(row.hitCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(row.hitCount == 0 ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(50)

            TableColumn("Cached", value: \.firstCachedAt) { row in
                Text(relativeTime(row.firstCachedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { keys in
            contextMenuItems(for: keys)
        } primaryAction: { _ in
            if let first = selection.first, let row = rows.first(where: { $0.id == first }) {
                copyURL(row.originalURL)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for keys: Set<String>) -> some View {
        let selected = rows.filter { keys.contains($0.id) }
        let anyUnpinned = selected.contains { !$0.pinned }
        let anyPinned = selected.contains { $0.pinned }

        Button("Copy URL") {
            if let row = selected.first { copyURL(row.originalURL) }
        }
        .disabled(selected.count != 1)

        Divider()

        if anyUnpinned {
            Button("Pin") { pinKeys(keys, pinned: true) }
        }
        if anyPinned {
            Button("Unpin") { pinKeys(keys, pinned: false) }
        }

        Divider()

        Button("Delete", role: .destructive) {
            selection = keys
            deleteSelection()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No cached pages yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Turn Wayback mode on and browse a page to populate the cache.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No entries match the current filters")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Clear filters") { clearFilters() }
                .buttonStyle(.link)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Proxy not running")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Start the proxy (⌘⇧S) to see the cache.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail drawer

    @ViewBuilder
    private func detailDrawer(for meta: CacheEntryMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                drawerHeader(meta)
                Divider()
                drawerMetadataSection(meta)
                Divider()
                drawerTagsSection(meta)
                Divider()
                drawerNoteSection(meta)
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color.gold.opacity(0.03))
    }

    private func drawerHeader(_ meta: CacheEntryMetadata) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Entry")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.gold)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
            Button {
                selection.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close drawer")
        }
    }

    private func drawerMetadataSection(_ meta: CacheEntryMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meta.originalURL)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if meta.pinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.gold)
                }
                Text(meta.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    label("Snapshot"); value(formatWaybackDate(meta.waybackDate))
                }
                GridRow {
                    label("Type");     value(shortContentType(meta.contentType))
                }
                GridRow {
                    label("Size");     value(formattedBytes(meta.sizeBytes))
                }
                GridRow {
                    label("Hits");     value("\(meta.hitCount)")
                }
                GridRow {
                    label("First cached"); value(relativeTime(meta.firstCachedAt))
                }
                GridRow {
                    label("Last used"); value(relativeTime(meta.lastAccessedAt))
                }
            }
            .padding(.top, 4)

            HStack(spacing: 8) {
                Button {
                    state.cacheIndex?.setPinned(key: meta.key, pinned: !meta.pinned)
                    refresh()
                    loadDrawerForSelection()
                } label: {
                    Label(meta.pinned ? "Unpin" : "Pin",
                          systemImage: meta.pinned ? "pin.slash" : "pin")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    state.responseCache?.remove(url: meta.waybackURL)
                    selection.removeAll()
                    refresh()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private func drawerTagsSection(_ meta: CacheEntryMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                label("Tags")
                Spacer()
                Text("comma-separated")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            TextField("e.g. apple, retro", text: $drawerTagsDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { saveDrawerTags(meta: meta) }

            let saved = tagsByKey[meta.key] ?? []
            if !saved.isEmpty {
                Text("Saved: \(saved.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func drawerNoteSection(_ meta: CacheEntryMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label("Note")
            TextEditor(text: $drawerNoteDraft)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            Button("Save note") { saveDrawerNote(meta: meta) }
                .buttonStyle(.link)
                .controlSize(.small)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.gold)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
    }

    private func loadDrawerForSelection() {
        guard selection.count == 1,
              let key = selection.first,
              let meta = state.cacheIndex?.get(key: key) else {
            drawerMetadata = nil
            drawerTagsDraft = ""
            drawerNoteDraft = ""
            return
        }
        drawerMetadata = meta
        drawerTagsDraft = (tagsByKey[key] ?? []).joined(separator: ", ")
        drawerNoteDraft = meta.note ?? ""
    }

    private func saveDrawerTags(meta: CacheEntryMetadata) {
        guard let index = state.cacheIndex else { return }
        let parsed = drawerTagsDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        index.setTags(key: meta.key, tags: parsed)
        tagsByKey = index.tagsByKey()
        availableTags = index.allTags()
    }

    private func saveDrawerNote(meta: CacheEntryMetadata) {
        state.cacheIndex?.setNote(key: meta.key, note: drawerNoteDraft)
        // Refresh local meta so the next render shows the saved value.
        if let updated = state.cacheIndex?.get(key: meta.key) {
            drawerMetadata = updated
        }
    }

    // MARK: Filtering & sorting

    private var availableDomains: [String] {
        Array(Set(rows.map(\.domain))).sorted()
    }

    private var ftsHitKeys: Set<String> {
        Set(ftsHits.map(\.key))
    }

    /// Snippet lookup keyed by cache key, for the Match column.
    private var snippetByKey: [String: String] {
        Dictionary(uniqueKeysWithValues: ftsHits.map { ($0.key, $0.snippet) })
    }

    /// FTS rank lookup (smaller rank = more relevant). Defaults to 0 when unavailable.
    private var rankByKey: [String: Double] {
        Dictionary(uniqueKeysWithValues: ftsHits.map { ($0.key, $0.rank) })
    }

    private var filteredRows: [CacheRow] {
        let hits = ftsHitKeys
        return rows.filter { row in
            if isContentSearching && !hits.contains(row.id) { return false }
            if selectedCapsuleId != nil && !capsuleMemberKeys.contains(row.id) { return false }
            if pinnedOnly && !row.pinned { return false }
            if !domainFilter.isEmpty && row.domain != domainFilter { return false }
            if !typeFilter.matches(row.contentType) { return false }
            if !tagFilter.isEmpty && !(tagsByKey[row.id] ?? []).contains(tagFilter) {
                return false
            }
            if !searchText.isEmpty &&
                !row.originalURL.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
    }

    private var sortedFilteredRows: [CacheRow] {
        if isContentSearching {
            // Respect FTS relevance ordering over whatever the column sort was.
            let ranks = rankByKey
            return filteredRows.sorted { (a, b) in
                (ranks[a.id] ?? 0) < (ranks[b.id] ?? 0)
            }
        }
        return filteredRows.sorted(using: sortOrder)
    }

    // MARK: Data

    private func refresh() {
        guard let index = state.cacheIndex else {
            rows = []
            totalBytes = 0
            totalCount = 0
            oldestAt = nil
            totalHits = 0
            capsules = []
            capsuleMemberKeys = []
            selectedCapsuleId = nil
            ftsHits = []
            ftsIndexedCount = 0
            tagsByKey = [:]
            availableTags = []
            return
        }
        let entries = index.allEntries(limit: 10_000)
        rows = entries.map(CacheRow.init)
        totalBytes = index.totalSize()
        totalCount = index.count()
        oldestAt = entries.map(\.firstCachedAt).min()
        totalHits = entries.reduce(Int64(0)) { $0 + $1.hitCount }
        ftsIndexedCount = index.ftsCount()

        capsules = index.listCapsules()
        // If the currently-selected capsule was deleted, drop the selection.
        if let selected = selectedCapsuleId, !capsules.contains(where: { $0.id == selected }) {
            selectedCapsuleId = nil
            capsuleMemberKeys = []
        } else if let selected = selectedCapsuleId {
            capsuleMemberKeys = Set(index.membersOfCapsule(id: selected))
        }

        tagsByKey = index.tagsByKey()
        availableTags = index.allTags()
        // Drop a tag filter that no longer matches any entry.
        if !tagFilter.isEmpty && !availableTags.contains(tagFilter) {
            tagFilter = ""
        }

        // Re-run the active FTS query so fresh data is reflected.
        runContentSearch()
    }

    private func runContentSearch() {
        guard let index = state.cacheIndex else {
            ftsHits = []
            return
        }
        let trimmed = contentSearchText.trimmingCharacters(in: .whitespaces)
        ftsHits = trimmed.isEmpty ? [] : index.searchFTS(query: trimmed, limit: 500)
    }

    private func rebuildFTSIndex() {
        guard let cache = state.responseCache, !isRebuildingIndex else { return }
        isRebuildingIndex = true
        ftsRebuildProgress = (0, 0)
        Task.detached { @Sendable in
            cache.rebuildFTSIndex { done, total in
                Task { @MainActor in
                    self.ftsRebuildProgress = (done, total)
                }
            }
            await MainActor.run {
                self.isRebuildingIndex = false
                self.refresh()
            }
        }
    }

    private func selectCapsule(_ capsule: CacheCapsule) {
        guard let index = state.cacheIndex else { return }
        selectedCapsuleId = capsule.id
        capsuleMemberKeys = Set(index.membersOfCapsule(id: capsule.id))
    }

    private func beginCreateFromSelection() {
        capsuleNameDraft = ""
        capsuleDescriptionDraft = ""
        showCreateCapsule = true
    }

    private func createCapsuleFromDraft() {
        let name = capsuleNameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let index = state.cacheIndex,
              let cap = index.createCapsule(
                name: name,
                description: capsuleDescriptionDraft.isEmpty ? nil : capsuleDescriptionDraft
              ) else { return }
        if !selection.isEmpty {
            index.addToCapsule(id: cap.id, keys: selection)
        }
        // Auto-select the new capsule so user sees what they made.
        selectedCapsuleId = cap.id
        capsuleMemberKeys = selection
    }

    private func exportCapsule(_ capsule: CacheCapsule) {
        guard let cache = state.responseCache, let index = state.cacheIndex else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(capsule.name).\(CapsuleBundler.bundleExtension)"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the capsule bundle"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let bundler = CapsuleBundler()
        do {
            try bundler.export(
                capsuleId: capsule.id,
                destination: dest,
                index: index,
                blobsDir: cache.blobsDir
            )
        } catch {
            capsuleAlert = CapsuleAlert(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }

    private func importCapsule() {
        guard let cache = state.responseCache, let index = state.cacheIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .retrogate-capsule bundle"
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let bundler = CapsuleBundler()
        do {
            let imported = try bundler.importBundle(
                from: src,
                index: index,
                blobsDir: cache.blobsDir
            )
            refresh()
            selectCapsule(imported)
        } catch {
            capsuleAlert = CapsuleAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func togglePin(_ row: CacheRow) {
        state.cacheIndex?.setPinned(key: row.id, pinned: !row.pinned)
        refresh()
    }

    private func pinSelection(_ pinned: Bool) {
        pinKeys(selection, pinned: pinned)
    }

    private func pinKeys(_ keys: Set<String>, pinned: Bool) {
        guard let index = state.cacheIndex else { return }
        for key in keys { index.setPinned(key: key, pinned: pinned) }
        refresh()
    }

    private func deleteSelection() {
        guard let cache = state.responseCache else { return }
        let targets = rows.filter { selection.contains($0.id) }
        for row in targets {
            if let meta = state.cacheIndex?.get(key: row.id) {
                cache.remove(url: meta.waybackURL)
            }
        }
        selection.removeAll()
        refresh()
    }

    private func clearAll() {
        state.responseCache?.clear()
        selection.removeAll()
        refresh()
    }

    private func copyURL(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: Formatting

    private func formattedBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func formatWaybackDate(_ stamp: String?) -> String {
        guard let s = stamp, s.count == 8 else { return "—" }
        let y = s.prefix(4)
        let m = s.dropFirst(4).prefix(2)
        let d = s.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }

    private func shortContentType(_ ct: String) -> String {
        let base = ct.split(separator: ";").first.map(String.init) ?? ct
        return base.trimmingCharacters(in: .whitespaces)
    }

    /// Render an FTS5 snippet (with `<b>...</b>` around matches) as a SwiftUI Text
    /// with bold ranges. Falls back to plain text if markdown parsing fails.
    private func snippetText(_ snippet: String) -> Text {
        let md = snippet
            .replacingOccurrences(of: "<b>", with: "**")
            .replacingOccurrences(of: "</b>", with: "**")
        if let attr = try? AttributedString(markdown: md) {
            return Text(attr)
        }
        return Text(snippet)
    }

    private func relativeTime(_ timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Hero stat tile

/// Compact stat tile used in every tab hero row: icon on the left, small
/// gold label + large value on the right. Shared across Cache, Request Log,
/// and Wayback Timeline so those tabs feel like a family.
struct HeroStat: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.gold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.gold)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.gold.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Sortable helpers

private extension CacheRow {
    var waybackDateSortable: Int {
        Int(waybackDate ?? "0") ?? 0
    }
}
