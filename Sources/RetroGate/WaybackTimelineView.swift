import SwiftUI
#if canImport(ProxyServer)
import ProxyServer
#endif

/// A focused, sortable view of HTML pages served from the Wayback Machine,
/// with emphasis on *date drift* — how close the archived snapshot is to
/// the date the user actually asked for.
///
/// The hero row is a temporal-accuracy report card:
///   Total | Exact | Close | Drift
///
/// Drift categories (matching the existing visual convention):
///   Exact  — within 7 days of target
///   Close  — 8 to 90 days
///   Drift  — more than 90 days
struct WaybackTimelineView: View {
    @EnvironmentObject var state: ProxyState

    @State private var urlFilter: String = ""
    @State private var domainFilter: String = ""
    @State private var categoryFilter: DeltaCategory = .all
    @State private var sortOrder: [KeyPathComparator<TimelineRow>] = [
        KeyPathComparator(\TimelineRow.timestamp, order: .reverse)
    ]

    enum DeltaCategory: String, CaseIterable, Identifiable {
        case all   = "All deltas"
        case exact = "Exact (≤ 7 days)"
        case close = "Close (8–90 days)"
        case drift = "Drift (> 90 days)"

        var id: String { rawValue }
    }

    /// Pre-computed row that folds the entry + current target-date comparison
    /// into sortable fields. Recomputed whenever the body re-renders, which is
    /// cheap even with hundreds of entries.
    struct TimelineRow: Identifiable, Hashable {
        let id: UUID
        let timestamp: Date
        let url: String
        let domain: String
        let actualStamp: String        // YYYYMMDD
        let actualDate: Date?
        let deltaDays: Int             // abs days between target and actual
        let category: DeltaCategory

        static func == (lhs: TimelineRow, rhs: TimelineRow) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            summaryBar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            tableArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Wayback Timeline")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HeroStat(icon: "clock.arrow.circlepath",
                     title: "Pages",
                     value: "\(rows.count)")
            HeroStat(icon: "checkmark.circle",
                     title: "Exact",
                     value: countLabel(for: .exact))
            HeroStat(icon: "clock.badge.checkmark",
                     title: "Close",
                     value: countLabel(for: .close))
            HeroStat(icon: "hourglass.bottomhalf.filled",
                     title: "Drift",
                     value: countLabel(for: .drift))
        }
    }

    private func countLabel(for cat: DeltaCategory) -> String {
        let count = rows.filter { $0.category == cat }.count
        guard !rows.isEmpty else { return "—" }
        let pct = Int(round(Double(count) / Double(rows.count) * 100))
        return "\(count) (\(pct)%)"
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Filter by URL…", text: $urlFilter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Picker("", selection: $domainFilter) {
                Text("All domains").tag("")
                ForEach(availableDomains, id: \.self) { d in Text(d).tag(d) }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .labelsHidden()

            Picker("", selection: $categoryFilter) {
                ForEach(DeltaCategory.allCases) { c in Text(c.rawValue).tag(c) }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            .labelsHidden()

            Spacer()

            if isFiltering {
                Button {
                    urlFilter = ""; domainFilter = ""; categoryFilter = .all
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    // MARK: Summary bar (between filter and table)

    private var summaryBar: some View {
        HStack {
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Target: \(formattedTargetDate)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Table

    private var tableArea: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else if filteredSorted.isEmpty {
                noMatchesState
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(filteredSorted, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.timestamp) { row in
                Text(row.timestamp, style: .time)
                    .monospacedDigit()
                    .font(.system(size: 12))
            }
            .width(min: 70, max: 90)

            TableColumn("URL", value: \.url) { row in
                Text(ContentView.shortURL(row.url))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.url)
                    .contextMenu {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.url, forType: .string)
                        }
                    }
            }
            .width(min: 240, ideal: 360)

            TableColumn("Domain", value: \.domain) { row in
                Text(row.domain).font(.system(size: 12))
            }
            .width(min: 110, ideal: 150)

            TableColumn("Actual", value: \.actualStamp) { row in
                Text(formatStamp(row.actualStamp))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, max: 120)

            TableColumn("Delta", value: \.deltaDays) { row in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(for: row.category))
                        .frame(width: 7, height: 7)
                    Text(deltaLabel(for: row))
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(row.category == .exact ? .regular : .medium)
                }
            }
            .width(min: 100, max: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No Wayback pages yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Archived HTML pages appear here with a comparison of your target date vs. the actual snapshot served.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
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
            Button("Clear filters") {
                urlFilter = ""; domainFilter = ""; categoryFilter = .all
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row building

    private var rows: [TimelineRow] {
        state.requestLog.compactMap { entry -> TimelineRow? in
            guard let stamp = entry.waybackDate,
                  entry.contentType?.contains("text/html") == true else { return nil }
            let actualDate = parseStamp(stamp)
            let delta = actualDate.map { abs(daysBetween(state.waybackDate, $0)) } ?? 0
            return TimelineRow(
                id: entry.id,
                timestamp: entry.timestamp,
                url: entry.url,
                domain: URL(string: entry.url)?.host ?? "",
                actualStamp: stamp,
                actualDate: actualDate,
                deltaDays: delta,
                category: categorize(delta)
            )
        }
    }

    private var filteredSorted: [TimelineRow] {
        rows.filter { row in
            if categoryFilter != .all && row.category != categoryFilter { return false }
            if !domainFilter.isEmpty && row.domain != domainFilter { return false }
            if !urlFilter.isEmpty &&
                !row.url.localizedCaseInsensitiveContains(urlFilter) { return false }
            return true
        }
        .sorted(using: sortOrder)
    }

    private var availableDomains: [String] {
        Array(Set(rows.map(\.domain))).sorted()
    }

    private var isFiltering: Bool {
        !urlFilter.isEmpty || !domainFilter.isEmpty || categoryFilter != .all
    }

    private var summaryText: String {
        if isFiltering { return "\(filteredSorted.count) of \(rows.count) shown" }
        return "\(rows.count) archived \(rows.count == 1 ? "page" : "pages")"
    }

    private var formattedTargetDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: state.waybackDate)
    }

    // MARK: Delta helpers

    private func categorize(_ days: Int) -> DeltaCategory {
        switch days {
        case 0...7:  return .exact
        case 8...90: return .close
        default:     return .drift
        }
    }

    private func color(for category: DeltaCategory) -> Color {
        switch category {
        case .all:   return .secondary
        case .exact: return .green
        case .close: return .gold
        case .drift: return .red
        }
    }

    private func deltaLabel(for row: TimelineRow) -> String {
        guard row.actualDate != nil else { return "—" }
        if row.category == .exact && row.deltaDays == 0 { return "Exact" }
        return "\(row.deltaDays)d"
    }

    private func parseStamp(_ stamp: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: stamp)
    }

    private func daysBetween(_ a: Date, _ b: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let components = cal.dateComponents([.day], from: a, to: b)
        return components.day ?? 0
    }

    private func formatStamp(_ stamp: String) -> String {
        guard stamp.count == 8 else { return stamp }
        return "\(stamp.prefix(4))-\(stamp.dropFirst(4).prefix(2))-\(stamp.dropFirst(6).prefix(2))"
    }
}
