import SwiftUI
#if canImport(ProxyServer)
import ProxyServer
#endif

/// The firehose of every proxy request, with hero stats, filters, and a
/// sortable table. Styled to match the Cache tab so all three Monitor tabs
/// feel like a family.
struct RequestLogView: View {
    @EnvironmentObject var state: ProxyState

    @State private var urlFilter: String = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var methodFilter: String = allMethods
    @State private var errorsOnly: Bool = false
    @State private var sortOrder: [KeyPathComparator<RequestLogEntry>] = [
        KeyPathComparator(\RequestLogEntry.timestamp, order: .reverse)
    ]

    private static let allMethods = "All"

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all       = "All status"
        case success   = "2xx"
        case redirect  = "3xx"
        case clientErr = "4xx"
        case serverErr = "5xx"

        var id: String { rawValue }

        func matches(_ code: Int) -> Bool {
            switch self {
            case .all:       return true
            case .success:   return (200..<300).contains(code)
            case .redirect:  return (300..<400).contains(code)
            case .clientErr: return (400..<500).contains(code)
            case .serverErr: return (500..<600).contains(code)
            }
        }
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
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            tableArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Request Log")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HeroStat(icon: "arrow.up.arrow.down",
                     title: "Requests",
                     value: "\(state.requestLog.count)")
            HeroStat(icon: "exclamationmark.triangle",
                     title: "Errors",
                     value: "\(errorCount)")
            HeroStat(icon: "arrow.down.circle",
                     title: "Bandwidth",
                     value: formattedBytes(totalBandwidth))
            HeroStat(icon: "chart.bar",
                     title: "Avg size",
                     value: avgSize)
        }
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

            Picker("", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .labelsHidden()

            Picker("", selection: $methodFilter) {
                Text("All methods").tag(Self.allMethods)
                ForEach(availableMethods, id: \.self) { m in Text(m).tag(m) }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .labelsHidden()

            Toggle(isOn: $errorsOnly) {
                Label("Errors only", systemImage: "exclamationmark.triangle")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Spacer()

            if isFiltering {
                Button {
                    urlFilter = ""; statusFilter = .all
                    methodFilter = Self.allMethods; errorsOnly = false
                } label: {
                    Label("Clear filters", systemImage: "xmark.circle")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive) {
                state.requestLog.removeAll()
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .disabled(state.requestLog.isEmpty)
            .controlSize(.small)
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear every entry from the request log (⌘K)")
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: Table

    private var tableArea: some View {
        Group {
            if state.requestLog.isEmpty {
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
            TableColumn("Time", value: \.timestamp) { entry in
                Text(entry.timestamp, style: .time)
                    .monospacedDigit()
                    .font(.system(size: 12))
            }
            .width(min: 70, max: 90)

            TableColumn("Method", value: \.method) { entry in
                Text(entry.method)
                    .font(.system(size: 12, weight: .medium))
            }
            .width(min: 50, max: 70)

            TableColumn("URL", value: \.url) { entry in
                HStack(spacing: 4) {
                    if entry.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    Text(entry.url)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contextMenu {
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url, forType: .string)
                    }
                    if let err = entry.errorMessage {
                        Divider()
                        Text("Error: \(err)")
                    }
                }
                .help(entry.url)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Status", value: \.statusCode) { entry in
                Text("\(entry.statusCode)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(entry.statusCode < 400 ? .primary : .red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 55, max: 75)

            TableColumn("Size", value: \.transcodedSize) { entry in
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.transcodedSize), countStyle: .file))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, max: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No requests yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Requests appear here as your vintage Mac browses.")
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
            Button("Clear filters") {
                urlFilter = ""; statusFilter = .all
                methodFilter = Self.allMethods; errorsOnly = false
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived data

    private var filteredSorted: [RequestLogEntry] {
        state.requestLog.filter { entry in
            if errorsOnly && entry.errorMessage == nil && entry.statusCode < 400 {
                return false
            }
            if !statusFilter.matches(entry.statusCode) { return false }
            if methodFilter != Self.allMethods && entry.method != methodFilter { return false }
            if !urlFilter.isEmpty &&
                !entry.url.localizedCaseInsensitiveContains(urlFilter) {
                return false
            }
            return true
        }
        .sorted(using: sortOrder)
    }

    private var isFiltering: Bool {
        !urlFilter.isEmpty || statusFilter != .all || methodFilter != Self.allMethods || errorsOnly
    }

    private var availableMethods: [String] {
        Array(Set(state.requestLog.map(\.method))).sorted()
    }

    private var errorCount: Int {
        state.requestLog.reduce(0) { $0 + ($1.errorMessage != nil || $1.statusCode >= 400 ? 1 : 0) }
    }

    private var totalBandwidth: Int64 {
        state.requestLog.reduce(Int64(0)) { $0 + Int64($1.transcodedSize) }
    }

    private var avgSize: String {
        guard !state.requestLog.isEmpty else { return "—" }
        let avg = totalBandwidth / Int64(state.requestLog.count)
        return formattedBytes(avg)
    }

    private var summaryText: String {
        if isFiltering {
            return "\(filteredSorted.count) of \(state.requestLog.count) shown"
        }
        return "\(state.requestLog.count) total"
    }

    private func formattedBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
