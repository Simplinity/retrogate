import SwiftUI
#if canImport(ProxyServer)
import ProxyServer
#endif

/// Sheet that warms the cache with a user-supplied URL list.
///
/// Three phases, driven by `phase`:
///   - `.idle`     — user edits the URL list, presses Start
///   - `.running`  — progress bar ticks, Cancel is live
///   - `.finished` — summary; optionally roll successful entries into a new capsule
struct PrefetchView: View {
    @EnvironmentObject var state: ProxyState
    @Environment(\.dismiss) private var dismiss

    /// Result handed back to the parent when the sheet closes.
    /// `nil` = user cancelled before any fetches happened (nothing to do).
    struct Result {
        let succeededKeys: [String]
        let capsuleName: String?   // if non-nil, parent should create a capsule
    }

    let onDone: (Result?) -> Void

    @State private var urlText: String = ""
    @State private var rejectedCount: Int = 0
    @State private var rateLimit: Double = 1.0
    @State private var phase: Phase = .idle
    @State private var progress: CacheWarmer.Progress? = nil
    @State private var warmer: CacheWarmer? = nil
    @State private var runTask: Task<Void, Never>? = nil

    @State private var capsuleNameDraft: String = ""

    enum Phase { case idle, running, finished }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            switch phase {
            case .idle:     idleView
            case .running:  runningView
            case .finished: finishedView
            }
            Divider()
            footer
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: Phases

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(Color.gold)
            Text("Prefetch Pages")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("Snapshot: \(waybackDateString)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste URLs — one per line. Lines starting with # are ignored.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextEditor(text: $urlText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                .onChange(of: urlText) { _ in
                    rejectedCount = CacheWarmer.parseURLList(urlText).rejected
                }

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("Delay between fetches")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("", value: $rateLimit, format: .number)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("sec")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let parsed = CacheWarmer.parseURLList(urlText)
                Text(parsedSummary(parsed.urls.count, rejected: parsed.rejected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = progress {
                ProgressView(value: Double(p.completed), total: Double(max(1, p.total)))
                    .progressViewStyle(.linear)

                HStack(spacing: 16) {
                    stat("Done",      "\(p.completed) / \(p.total)")
                    stat("Fetched",   "\(p.succeeded)")
                    stat("Already",   "\(p.cached)")
                    stat("Failed",    "\(p.failed)")
                }

                if let current = p.current {
                    Text("Fetching: \(current)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Wrapping up…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Starting…")
                    .progressViewStyle(.linear)
            }
        }
    }

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            let p = progress
            Text(p?.isCancelled == true ? "Prefetch cancelled" : "Prefetch finished")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.gold)

            HStack(spacing: 16) {
                stat("Done",    "\(p?.completed ?? 0) / \(p?.total ?? 0)")
                stat("Fetched", "\(p?.succeeded ?? 0)")
                stat("Already", "\(p?.cached ?? 0)")
                stat("Failed",  "\(p?.failed ?? 0)")
            }

            if let keys = p?.succeededKeys, !keys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().padding(.vertical, 4)
                    Text("Wrap these into a capsule?")
                        .font(.system(size: 12, weight: .medium))
                    TextField("Capsule name (optional)", text: $capsuleNameDraft)
                        .textFieldStyle(.roundedBorder)
                    Text("Tip: use the capsule later to export this collection.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .idle:
                Button("Cancel", role: .cancel) {
                    dismiss()
                    onDone(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            case .running:
                Button("Cancel") {
                    let w = warmer
                    Task { await w?.cancel() }
                }
            case .finished:
                Button("Done") {
                    let keys = progress?.succeededKeys ?? []
                    let name = capsuleNameDraft.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    onDone(Result(
                        succeededKeys: keys,
                        capsuleName: name.isEmpty ? nil : name
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private var canStart: Bool {
        state.responseCache != nil &&
        !state.cacheOfflineMode &&
        !CacheWarmer.parseURLList(urlText).urls.isEmpty
    }

    private func start() {
        guard let cache = state.responseCache else { return }
        let urls = CacheWarmer.parseURLList(urlText).urls
        let date = state.waybackDate
        let rate = max(0, rateLimit)

        let newWarmer = CacheWarmer(responseCache: cache)
        self.warmer = newWarmer
        self.phase = .running
        self.progress = nil

        runTask = Task { @MainActor in
            await newWarmer.warm(urls: urls, waybackDate: date, rateLimit: rate) { p in
                await MainActor.run {
                    self.progress = p
                    if p.isFinished || p.isCancelled {
                        self.phase = .finished
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var waybackDateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: state.waybackDate)
    }

    private func parsedSummary(_ accepted: Int, rejected: Int) -> String {
        if accepted == 0 && rejected == 0 { return "No URLs yet" }
        if rejected == 0 { return "\(accepted) URL\(accepted == 1 ? "" : "s")" }
        return "\(accepted) URL\(accepted == 1 ? "" : "s"), \(rejected) rejected"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.gold)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
    }
}

