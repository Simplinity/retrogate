import SwiftUI
import ProxyServer
import HTMLTranscoder
import ImageTranscoder

@main
struct RetroGateApp: App {
    @StateObject private var proxyState = ProxyState()

    init() {
        // Ensure the app gets a proper Dock icon and can receive focus,
        // even when launched as a bare binary outside an .app bundle
        NSApplication.shared.setActivationPolicy(.regular)

        // Disable App Nap — RetroGate is a server that must stay active
        // even when the user switches to another app
        ProcessInfo.processInfo.disableAutomaticTermination("Proxy server running")
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "RetroGate proxy must remain responsive"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(proxyState)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 680, height: 520)
        .commands {
            // Replace "About RetroGate" with a proper About panel
            CommandGroup(replacing: .appInfo) {
                Button("About RetroGate") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "RetroGate",
                        .applicationVersion: "1.0.0",
                        .version: "1",
                        .credits: NSAttributedString(
                            string: "A proxy server for vintage computers.\nBrowse the modern web on classic Macs and PCs.",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                    ])
                }
            }

            // Remove File > New Window (single-window app)
            CommandGroup(replacing: .newItem) {}

            // Proxy controls
            CommandMenu("Proxy") {
                Button(proxyState.isRunning ? "Stop Proxy" : "Start Proxy") {
                    proxyState.toggleProxy()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(proxyState.waybackEnabled ? "Disable Wayback Mode" : "Enable Wayback Mode") {
                    proxyState.waybackEnabled.toggle()
                    proxyState.syncConfig()
                    proxyState.saveSettings()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("Clear Request Log") {
                    proxyState.requestLog.removeAll()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(proxyState)
        }
    }
}

// MARK: - Vintage Presets

enum VintagePlatform: String, CaseIterable, Identifiable {
    case mac = "Mac"
    case pc = "PC"
    var id: String { rawValue }
}

struct ScreenResolution: Hashable {
    let width: Int
    let height: Int
    var label: String { "\(width) × \(height)" }
}

struct VintagePreset: Identifiable {
    let id: String
    let platform: VintagePlatform
    let osName: String
    let year: String
    let htmlLevel: HTMLTranscoder.Level
    let imageQuality: Double
    let defaultResolution: ScreenResolution
    let resolutions: [ScreenResolution]

    /// The years when this OS was actively used for web browsing.
    /// Used to auto-suggest a Wayback date and show era context in the UI.
    /// Note: The web became publicly available in 1993 (Mosaic). Even System 6
    /// and Windows 3.1 can run early browsers (MacWWW, Mosaic), just not for
    /// content predating 1993.
    let eraRange: ClosedRange<Int>

    /// Color depths this hardware typically supported.
    let supportedColorDepths: [ColorDepth]
    /// The most common color depth for this era.
    let defaultColorDepth: ColorDepth

    /// Suggested Wayback date — the midpoint of this OS's web browsing era.
    var suggestedWaybackDate: Date {
        let midYear = eraRange.lowerBound + (eraRange.upperBound - eraRange.lowerBound) / 2
        var c = DateComponents()
        c.year = midYear
        c.month = 6
        c.day = 15
        return Calendar.current.date(from: c) ?? Date()
    }

    /// Human-readable era description.
    var eraDescription: String {
        "\(eraRange.lowerBound)–\(eraRange.upperBound)"
    }

    static let all: [VintagePreset] = [
        // ── Mac ──────────────────────────────────────
        // System 6 (1988): Predates the web, but MacWWW (1993) runs on it.
        // Mac Plus/SE had 1-bit B&W screens; Mac II had color.
        VintagePreset(id: "system6", platform: .mac, osName: "System 6", year: "1988",
                      htmlLevel: .aggressive, imageQuality: 0.3,
                      defaultResolution: .init(width: 512, height: 342),
                      resolutions: [.init(width: 512, height: 342),
                                    .init(width: 640, height: 480)],
                      eraRange: 1993...1995,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .monochrome),
        // System 7 (1991): NCSA Mosaic, early Netscape.
        // Classic was B&W, but most System 7 Macs had color.
        VintagePreset(id: "system7", platform: .mac, osName: "System 7", year: "1991",
                      htmlLevel: .aggressive, imageQuality: 0.4,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 512, height: 342),
                                    .init(width: 640, height: 480),
                                    .init(width: 832, height: 624)],
                      eraRange: 1994...1997,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .twoFiftySix),
        // Mac OS 8 (1997): Netscape 3–4, IE 4 Mac, Cyberdog.
        VintagePreset(id: "macos8", platform: .mac, osName: "Mac OS 8", year: "1997",
                      htmlLevel: .moderate, imageQuality: 0.5,
                      defaultResolution: .init(width: 832, height: 624),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 832, height: 624),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1997...1999,
                      supportedColorDepths: [.sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
        // Mac OS 9 (1999): IE 5 Mac, Netscape 4.7, iCab.
        VintagePreset(id: "macos9", platform: .mac, osName: "Mac OS 9", year: "1999",
                      htmlLevel: .moderate, imageQuality: 0.6,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 832, height: 624),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1152, height: 870)],
                      eraRange: 1999...2002,
                      supportedColorDepths: [.twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
        // Mac OS X (2001): Safari, Camino, Firefox, IE 5.2 Mac.
        VintagePreset(id: "macosx", platform: .mac, osName: "Mac OS X", year: "2001",
                      htmlLevel: .minimal, imageQuality: 0.8,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 800, height: 600),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1152, height: 870),
                                    .init(width: 1280, height: 1024)],
                      eraRange: 2001...2005,
                      supportedColorDepths: [.thousands],
                      defaultColorDepth: .thousands),
        // ── PC ───────────────────────────────────────
        // Windows 3.1 (1992): Predates the web, but Mosaic ran on it via Win32s.
        // Standard VGA was 16 colors.
        VintagePreset(id: "win31", platform: .pc, osName: "Windows 3.1", year: "1992",
                      htmlLevel: .aggressive, imageQuality: 0.3,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600)],
                      eraRange: 1994...1996,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix],
                      defaultColorDepth: .sixteenColor),
        // Windows 95 (1995): IE 3–4, Netscape 2–4.
        VintagePreset(id: "win95", platform: .pc, osName: "Windows 95", year: "1995",
                      htmlLevel: .moderate, imageQuality: 0.5,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1995...1998,
                      supportedColorDepths: [.sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .twoFiftySix),
        // Windows 98 (1998): IE 5–6, Netscape 4.7.
        VintagePreset(id: "win98", platform: .pc, osName: "Windows 98", year: "1998",
                      htmlLevel: .moderate, imageQuality: 0.6,
                      defaultResolution: .init(width: 800, height: 600),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1998...2001,
                      supportedColorDepths: [.twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
        // Windows 2000 (2000): IE 5–6, early Firefox/Mozilla.
        VintagePreset(id: "win2000", platform: .pc, osName: "Windows 2000", year: "2000",
                      htmlLevel: .minimal, imageQuality: 0.7,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 800, height: 600),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1280, height: 1024)],
                      eraRange: 2000...2003,
                      supportedColorDepths: [.twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
        // Windows XP (2001): IE 6, Firefox 1–3, Opera.
        VintagePreset(id: "winxp", platform: .pc, osName: "Windows XP", year: "2001",
                      htmlLevel: .minimal, imageQuality: 0.8,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 800, height: 600),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1280, height: 1024),
                                    .init(width: 1600, height: 1200)],
                      eraRange: 2001...2006,
                      supportedColorDepths: [.thousands],
                      defaultColorDepth: .thousands),
    ]

    static func forPlatform(_ platform: VintagePlatform) -> [VintagePreset] {
        all.filter { $0.platform == platform }
    }
}

// MARK: - Config File

private struct SavedSettings: Codable {
    var port: UInt16 = 8080
    var waybackEnabled: Bool = true
    var waybackDateTimestamp: Double = {
        var c = DateComponents(); c.year = 1999; c.month = 6; c.day = 15
        return Calendar.current.date(from: c)?.timeIntervalSince1970 ?? 0
    }()
    var waybackToleranceMonths: Int = 6
    var platform: String = "Mac"
    var presetId: String = "macos9"
    var screenWidth: Int = 1024
    var screenHeight: Int = 768
    var transcodingBypassDomains: String = "68kmla.org\nsystem7today.com\nmacintoshgarden.org"
    var minifyHTML: Bool = false
    var colorDepth: String = "thousands"

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RetroGate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> SavedSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return SavedSettings()
        }
        return s
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

// Resilient decoder: missing keys use defaults instead of failing.
// This prevents config resets when new fields are added in updates.
extension SavedSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(UInt16.self, forKey: .port) { port = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .waybackEnabled) { waybackEnabled = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .waybackDateTimestamp) { waybackDateTimestamp = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .waybackToleranceMonths) { waybackToleranceMonths = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .platform) { platform = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .presetId) { presetId = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .screenWidth) { screenWidth = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .screenHeight) { screenHeight = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .transcodingBypassDomains) { transcodingBypassDomains = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .minifyHTML) { minifyHTML = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .colorDepth) { colorDepth = v }
    }
}

// MARK: - App State

@MainActor
class ProxyState: ObservableObject {
    @Published var isRunning = true
    @Published var port: UInt16 = 8080
    @Published var waybackEnabled = true
    @Published var waybackDate: Date = {
        var c = DateComponents(); c.year = 1999; c.month = 6; c.day = 15
        return Calendar.current.date(from: c) ?? Date()
    }()
    @Published var waybackToleranceMonths: Int = 6
    @Published var platform: VintagePlatform = .mac
    @Published var presetId: String = "macos9"
    @Published var resolution: ScreenResolution = ScreenResolution(width: 1024, height: 768)
    @Published var transcodingBypassDomainsText: String = "68kmla.org\nsystem7today.com\nmacintoshgarden.org"
    @Published var minifyHTML: Bool = false
    @Published var colorDepth: ColorDepth = .thousands
    @Published var requestLog: [RequestLogEntry] = []

    var transcodingBypassDomains: Set<String> {
        Set(transcodingBypassDomainsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    var selectedPreset: VintagePreset {
        VintagePreset.all.first { $0.id == presetId } ?? VintagePreset.all[3]
    }
    var htmlLevel: HTMLTranscoder.Level { selectedPreset.htmlLevel }
    var maxImageWidth: Int { max(resolution.width - 40, 320) }
    var imageQuality: Double { selectedPreset.imageQuality }
    var outputEncoding: OutputEncoding { platform == .mac ? .macRoman : .isoLatin1 }

    private var server: ProxyServer?
    private var serverTask: Task<Void, Never>?

    init() {
        let s = SavedSettings.load()
        port = s.port
        waybackEnabled = s.waybackEnabled
        waybackDate = Date(timeIntervalSince1970: s.waybackDateTimestamp)
        waybackToleranceMonths = s.waybackToleranceMonths
        platform = VintagePlatform(rawValue: s.platform) ?? .mac
        if VintagePreset.all.contains(where: { $0.id == s.presetId }) { presetId = s.presetId }
        resolution = ScreenResolution(width: s.screenWidth, height: s.screenHeight)
        transcodingBypassDomainsText = s.transcodingBypassDomains
        minifyHTML = s.minifyHTML

        // Load color depth, validating against the selected preset's capabilities
        let preset = VintagePreset.all.first { $0.id == presetId } ?? VintagePreset.all[3]
        if let depth = ColorDepth(rawValue: s.colorDepth), preset.supportedColorDepths.contains(depth) {
            colorDepth = depth
        } else {
            colorDepth = preset.defaultColorDepth
        }

        saveSettings() // Ensure config file exists on first launch
        startProxy()
    }

    func saveSettings() {
        SavedSettings(
            port: port,
            waybackEnabled: waybackEnabled,
            waybackDateTimestamp: waybackDate.timeIntervalSince1970,
            waybackToleranceMonths: waybackToleranceMonths,
            platform: platform.rawValue,
            presetId: presetId,
            screenWidth: resolution.width,
            screenHeight: resolution.height,
            transcodingBypassDomains: transcodingBypassDomainsText,
            minifyHTML: minifyHTML,
            colorDepth: colorDepth.rawValue
        ).save()
    }

    func toggleProxy() {
        if isRunning {
            startProxy()
        } else {
            stopProxy()
        }
    }

    /// The BrowsingMode derived from current UI settings.
    var browsingMode: BrowsingMode {
        waybackEnabled
            ? .wayback(targetDate: waybackDate, toleranceMonths: waybackToleranceMonths)
            : .liveWeb
    }

    /// Push current UI settings to the running server's shared config.
    func syncConfig() {
        guard let server = server else { return }
        server.sharedConfig.value = ProxyConfiguration(
            browsingMode: browsingMode,
            transcodingLevel: htmlLevel,
            maxImageWidth: maxImageWidth,
            imageQuality: imageQuality,
            outputEncoding: outputEncoding,
            transcodingBypassDomains: transcodingBypassDomains,
            minifyHTML: minifyHTML,
            colorDepth: colorDepth,
            onRequestLogged: server.sharedConfig.value.onRequestLogged
        )
        // Clear the temporal cache so sub-resources don't load from the old date
        server.temporalCache.clear()
    }

    private func startProxy() {
        let config = ProxyConfiguration(
            browsingMode: browsingMode,
            transcodingLevel: htmlLevel,
            maxImageWidth: maxImageWidth,
            imageQuality: imageQuality,
            outputEncoding: outputEncoding,
            transcodingBypassDomains: transcodingBypassDomains,
            minifyHTML: minifyHTML,
            colorDepth: colorDepth,
            onRequestLogged: { [weak self] entry in
                Task { @MainActor in
                    self?.requestLog.insert(RequestLogEntry(
                        timestamp: Date(),
                        method: entry.method,
                        url: entry.url,
                        statusCode: entry.statusCode,
                        originalSize: entry.originalSize,
                        transcodedSize: entry.transcodedSize,
                        waybackDate: entry.waybackDate,
                        contentType: entry.contentType
                    ), at: 0)
                    // Keep log manageable
                    if (self?.requestLog.count ?? 0) > 500 {
                        self?.requestLog = Array(self!.requestLog.prefix(500))
                    }
                }
            }
        )

        let newServer = ProxyServer(host: "0.0.0.0", port: Int(port), configuration: config)
        self.server = newServer

        serverTask = Task.detached {
            do {
                try await newServer.start()
                try await newServer.waitForClose()
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.server = nil
                }
            }
        }
    }

    private func stopProxy() {
        serverTask?.cancel()
        serverTask = nil
        Task {
            try? await server?.stop()
            server = nil
        }
    }
}

struct RequestLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let url: String
    let statusCode: Int
    let originalSize: Int
    let transcodedSize: Int
    let waybackDate: String?
    let contentType: String?
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var state: ProxyState

    private var localIP: String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }

    @State private var selectedTab: SidebarItem = .dashboard

    enum SidebarItem: String, CaseIterable {
        case dashboard = "Dashboard"
        case requestLog = "Request Log"
        case waybackTimeline = "Wayback Timeline"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Dashboard", systemImage: "gauge")
                    .tag(SidebarItem.dashboard)
                Label("Request Log", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.requestLog)
                Label("Wayback Timeline", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.waybackTimeline)
            }
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case .dashboard:
                dashboardView
            case .requestLog:
                requestLogView
            case .waybackTimeline:
                waybackTimelineView
            }
        }
    }

    private var dashboardView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: state.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(state.isRunning ? .green : .secondary)

                Button {
                    state.isRunning.toggle()
                    state.toggleProxy()
                } label: {
                    Text(state.isRunning ? "Stop Proxy" : "Start Proxy")
                        .frame(width: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(state.isRunning ? .red : .green)

                Text(state.isRunning ? "Proxy Running" : "Proxy Stopped")
                    .font(.headline)
                    .foregroundColor(state.isRunning ? .green : .secondary)

                if state.isRunning {
                    Text("Configure your vintage Mac's HTTP proxy to:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(localIP):\(state.port)")
                        .font(.system(.title2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding()

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Enable Wayback Mode", isOn: $state.waybackEnabled)
                            .tint(.orange)
                        InfoPopover(
                            title: "Wayback Machine Mode",
                            text: "When enabled, RetroGate fetches pages from the Internet Archive's Wayback Machine instead of the live web.\n\nThis lets you browse the web as it actually was in the past -- perfect for experiencing vintage sites on vintage hardware.\n\nWhen disabled, RetroGate fetches from the live internet and transcodes modern pages for your old browser."
                        )
                    }
                    if state.waybackEnabled {
                        Text("Browsing the web as it was in the \(state.selectedPreset.osName) era (\(state.selectedPreset.eraDescription))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DatePicker("Target date:", selection: $state.waybackDate, displayedComponents: .date)
                        HStack {
                            Picker("Date tolerance:", selection: $state.waybackToleranceMonths) {
                                Text("1 month").tag(1)
                                Text("3 months").tag(3)
                                Text("6 months").tag(6)
                                Text("9 months").tag(9)
                                Text("12 months").tag(12)
                                Text("Any date").tag(0)
                            }
                            InfoPopover(
                                title: "Date Tolerance",
                                text: "The Wayback Machine may not have a snapshot on your exact target date. This setting controls how far the actual snapshot date can be from your target.\n\nFor example, with 6 months tolerance and a target of June 1999, RetroGate accepts snapshots from January 1999 to December 1999.\n\nSet to \"Any date\" to always show the closest available snapshot, regardless of how far it is."
                            )
                        }
                        Button("Suggest date for \(state.selectedPreset.osName) era") {
                            state.waybackDate = state.selectedPreset.suggestedWaybackDate
                        }
                        .controlSize(.small)
                    }
                }
                .padding(4)
            } label: {
                HStack {
                    Text("Wayback Machine")
                    if state.waybackEnabled {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.orange)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Platform", selection: $state.platform) {
                        ForEach(VintagePlatform.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Operating System", selection: $state.presetId) {
                        ForEach(VintagePreset.forPlatform(state.platform)) { preset in
                            Text("\(preset.osName) (\(preset.year))").tag(preset.id)
                        }
                    }

                    Picker("Screen Resolution", selection: $state.resolution) {
                        ForEach(state.selectedPreset.resolutions, id: \.self) { res in
                            Text(res.label).tag(res)
                        }
                    }

                    if state.selectedPreset.supportedColorDepths.count > 1 {
                        HStack {
                            Picker("Color Depth", selection: $state.colorDepth) {
                                ForEach(state.selectedPreset.supportedColorDepths, id: \.self) { depth in
                                    Text(depth.displayName).tag(depth)
                                }
                            }
                            InfoPopover(
                                title: "Display Color Depth",
                                text: "Matches image output to your vintage display's color capabilities.\n\nB&W (1-bit): Floyd-Steinberg dithering for monochrome screens (Mac Plus, SE, Classic). Classic halftone newspaper look.\n\n16 Colors: Ordered dithering with the standard VGA palette. For Windows 3.1 and early VGA displays.\n\n256 Colors: GIF palette quantization for 8-bit displays common in the mid-90s.\n\nThousands+: Full-color JPEG output for 16-bit or 24-bit displays."
                            )
                        }
                    }
                }
                .padding(4)
            } label: {
                Label("My Vintage Computer", systemImage: "desktopcomputer")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Minify HTML", isOn: $state.minifyHTML)
                        InfoPopover(
                            title: "HTML Minification",
                            text: "Removes comments, collapses whitespace, and strips blank lines from HTML before sending it to your vintage browser.\n\nThis reduces page size by 20-40%, which matters on slow connections (modems, SheepShaver slirp NAT).\n\nIt does not change how the page looks -- only how much data is transferred."
                        )
                    }

                    Divider()

                    HStack(alignment: .top) {
                        Text("Bypass domains")
                            .font(.callout)
                        InfoPopover(
                            title: "Transcoding Bypass Domains",
                            text: "Sites listed here skip the HTML5-to-HTML 3.2 transcoding.\n\nSome sites are already retro-friendly (simple HTML, no JavaScript) and work better WITHOUT aggressive transcoding. For these domains, RetroGate only downgrades HTTPS to HTTP and converts the character encoding.\n\nOne domain per line. Subdomains are matched automatically (e.g. \"68kmla.org\" also matches \"www.68kmla.org\")."
                        )
                        Spacer()
                    }
                    TextEditor(text: $state.transcodingBypassDomainsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.gray.opacity(0.3))
                }
                .padding(4)
            } label: {
                Label("Advanced", systemImage: "gearshape.2")
            }

            Spacer()
        }
        .padding()
        .onChange(of: state.platform) {
            // Cascade: pick first OS for this platform
            if let first = VintagePreset.forPlatform(state.platform).first {
                state.presetId = first.id
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.presetId) {
            // Cascade: pick default resolution and validate color depth for this OS
            if let preset = VintagePreset.all.first(where: { $0.id == state.presetId }) {
                state.resolution = preset.defaultResolution
                if !preset.supportedColorDepths.contains(state.colorDepth) {
                    state.colorDepth = preset.defaultColorDepth
                }
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.resolution) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.waybackEnabled) {
            // When Wayback mode is turned ON, auto-suggest a date from the selected preset's era
            if state.waybackEnabled {
                state.waybackDate = state.selectedPreset.suggestedWaybackDate
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.waybackDate) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.waybackToleranceMonths) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.port) { state.saveSettings() }
        .onChange(of: state.minifyHTML) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.colorDepth) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.transcodingBypassDomainsText) { state.saveSettings(); state.syncConfig() }
    }

    private var requestLogView: some View {
        VStack {
            if state.requestLog.isEmpty {
                ContentUnavailableView(
                    "No Requests Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Requests will appear here as your vintage Mac browses the web.")
                )
            } else {
                Table(state.requestLog) {
                    TableColumn("Time") { entry in
                        Text(entry.timestamp, style: .time)
                            .monospacedDigit()
                    }
                    .width(min: 70, max: 90)

                    TableColumn("Method") { entry in
                        Text(entry.method)
                            .fontWeight(.medium)
                    }
                    .width(min: 50, max: 60)

                    TableColumn("URL") { entry in
                        Text(entry.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    TableColumn("Status") { entry in
                        Text("\(entry.statusCode)")
                            .foregroundColor(entry.statusCode < 400 ? .primary : .red)
                    }
                    .width(min: 50, max: 60)

                    TableColumn("Size") { entry in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.transcodedSize), countStyle: .file))
                    }
                    .width(min: 60, max: 80)
                }
            }
        }
    }

    /// Filter log to only HTML page requests that have a resolved Wayback date.
    private var waybackEntries: [RequestLogEntry] {
        state.requestLog.filter { $0.waybackDate != nil && ($0.contentType?.contains("text/html") == true) }
    }

    private var waybackTimelineView: some View {
        VStack {
            if waybackEntries.isEmpty {
                ContentUnavailableView(
                    "No Wayback Pages Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Pages served from the Wayback Machine will appear here, showing the actual archive date vs your target date.")
                )
            } else {
                Table(waybackEntries) {
                    TableColumn("Time") { entry in
                        Text(entry.timestamp, style: .time)
                            .monospacedDigit()
                    }
                    .width(min: 70, max: 90)

                    TableColumn("URL") { entry in
                        // Show just the host + path for readability
                        Text(Self.shortURL(entry.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    TableColumn("Target") { _ in
                        Text(Self.formatWaybackDate(state.waybackDate))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, max: 110)

                    TableColumn("Actual") { entry in
                        if let wbDate = entry.waybackDate {
                            Text(Self.formatDateStamp(wbDate))
                        }
                    }
                    .width(min: 90, max: 110)

                    TableColumn("Delta") { entry in
                        if let wbDate = entry.waybackDate {
                            let delta = Self.dateDelta(target: state.waybackDate, actual: wbDate)
                            Text(delta.label)
                                .foregroundStyle(delta.color)
                                .fontWeight(delta.isExact ? .regular : .medium)
                        }
                    }
                    .width(min: 80, max: 120)
                }
            }
        }
    }

    // MARK: - Wayback Timeline Helpers

    private static func shortURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host ?? ""
        let path = url.path
        if path == "/" || path.isEmpty {
            return host
        }
        return host + path
    }

    private static func formatWaybackDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    /// Parse "YYYYMMDD" stamp into a readable date string.
    private static func formatDateStamp(_ stamp: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        guard let date = f.date(from: stamp) else { return stamp }
        let display = DateFormatter()
        display.dateFormat = "MMM d, yyyy"
        return display.string(from: date)
    }

    /// Compute the delta between the configured target date and the actual Wayback date.
    private static func dateDelta(target: Date, actual: String) -> (label: String, color: Color, isExact: Bool) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        guard let actualDate = f.date(from: actual) else {
            return (actual, .secondary, false)
        }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: calendar.startOfDay(for: target), to: calendar.startOfDay(for: actualDate))
        let days = components.day ?? 0

        if days == 0 {
            return ("Exact", .green, true)
        }

        let absDays = abs(days)
        let label: String
        if absDays < 30 {
            label = "\(days > 0 ? "+" : "")\(days)d"
        } else if absDays < 365 {
            let months = absDays / 30
            label = "\(days > 0 ? "+" : "-")\(months)mo"
        } else {
            let years = absDays / 365
            let remMonths = (absDays % 365) / 30
            if remMonths > 0 {
                label = "\(days > 0 ? "+" : "-")\(years)y \(remMonths)mo"
            } else {
                label = "\(days > 0 ? "+" : "-")\(years)y"
            }
        }

        let color: Color = absDays <= 7 ? .green : absDays <= 90 ? .orange : .red
        return (label, color, false)
    }
}

// MARK: - Info Popover

/// A small (i) button that shows an explanatory popover on click.
struct InfoPopover: View {
    let title: String
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: ProxyState

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            networkTab
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 450, height: 280)
    }

    private var generalTab: some View {
        Form {
            TextField("Proxy Port:", value: $state.port, format: .number)
                .help("The HTTP port vintage browsers connect to (default: 8080)")
            Toggle("Minify HTML", isOn: $state.minifyHTML)
                .help("Strip comments and collapse whitespace to save bandwidth on slow connections")
        }
        .formStyle(.grouped)
        .onChange(of: state.port) { state.syncConfig(); state.saveSettings() }
        .onChange(of: state.minifyHTML) { state.syncConfig(); state.saveSettings() }
    }

    private var networkTab: some View {
        Form {
            Section {
                Text("Domains listed here skip HTML transcoding (one per line). Use this for sites that already serve retro-compatible HTML.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $state.transcodingBypassDomainsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .border(Color(nsColor: .separatorColor))
            } header: {
                Text("Transcoding Bypass Domains")
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.transcodingBypassDomainsText) { state.syncConfig(); state.saveSettings() }
    }
}
