import SwiftUI
import Logging
#if canImport(ProxyServer)
import ProxyServer
#endif
#if canImport(HTMLTranscoder)
import HTMLTranscoder
#endif
#if canImport(ImageTranscoder)
import ImageTranscoder
#endif

// MARK: - Gold Accent

extension Color {
    static let gold = Color(red: 0.76, green: 0.60, blue: 0.23)
    static let goldLight = Color(red: 0.85, green: 0.72, blue: 0.40)
}

@main
struct RetroGateApp: App {
    @StateObject private var proxyState = ProxyState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableAutomaticTermination("Proxy server running")
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "RetroGate proxy must remain responsive"
        )
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(proxyState)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .defaultSize(width: 1120, height: 760)
        .commands { RetroGateCommands() }

        Settings {
            SettingsView()
                .environmentObject(proxyState)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(proxyState)
        } label: {
            Image(systemName: proxyState.isRunning
                  ? "antenna.radiowaves.left.and.right"
                  : "antenna.radiowaves.left.and.right.slash")
        }
        .menuBarExtraStyle(.menu)
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
    let eraRange: ClosedRange<Int>
    let supportedColorDepths: [ColorDepth]
    let defaultColorDepth: ColorDepth

    var suggestedWaybackDate: Date {
        let midYear = eraRange.lowerBound + (eraRange.upperBound - eraRange.lowerBound) / 2
        var c = DateComponents()
        c.year = midYear
        c.month = 6
        c.day = 15
        return Calendar.current.date(from: c) ?? Date()
    }

    var eraDescription: String {
        "\(eraRange.lowerBound)–\(eraRange.upperBound)"
    }

    static let all: [VintagePreset] = [
        VintagePreset(id: "system6", platform: .mac, osName: "System 6", year: "1988",
                      htmlLevel: .aggressive, imageQuality: 0.3,
                      defaultResolution: .init(width: 512, height: 342),
                      resolutions: [.init(width: 512, height: 342),
                                    .init(width: 640, height: 480)],
                      eraRange: 1993...1995,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .monochrome),
        VintagePreset(id: "system7", platform: .mac, osName: "System 7", year: "1991",
                      htmlLevel: .aggressive, imageQuality: 0.4,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 512, height: 342),
                                    .init(width: 640, height: 480),
                                    .init(width: 832, height: 624)],
                      eraRange: 1994...1997,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix, .thousands, .millions],
                      defaultColorDepth: .twoFiftySix),
        VintagePreset(id: "macos8", platform: .mac, osName: "Mac OS 8", year: "1997",
                      htmlLevel: .moderate, imageQuality: 0.5,
                      defaultResolution: .init(width: 832, height: 624),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 832, height: 624),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1997...1999,
                      supportedColorDepths: [.sixteenColor, .twoFiftySix, .thousands, .millions],
                      defaultColorDepth: .thousands),
        VintagePreset(id: "macos9", platform: .mac, osName: "Mac OS 9", year: "1999",
                      htmlLevel: .moderate, imageQuality: 0.6,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 832, height: 624),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1152, height: 870)],
                      eraRange: 1999...2002,
                      supportedColorDepths: [.twoFiftySix, .thousands, .millions],
                      defaultColorDepth: .millions),
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
        VintagePreset(id: "win31", platform: .pc, osName: "Windows 3.1", year: "1992",
                      htmlLevel: .aggressive, imageQuality: 0.3,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600)],
                      eraRange: 1994...1996,
                      supportedColorDepths: [.monochrome, .sixteenColor, .twoFiftySix],
                      defaultColorDepth: .sixteenColor),
        VintagePreset(id: "win95", platform: .pc, osName: "Windows 95", year: "1995",
                      htmlLevel: .moderate, imageQuality: 0.5,
                      defaultResolution: .init(width: 640, height: 480),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1995...1998,
                      supportedColorDepths: [.sixteenColor, .twoFiftySix, .thousands],
                      defaultColorDepth: .twoFiftySix),
        VintagePreset(id: "win98", platform: .pc, osName: "Windows 98", year: "1998",
                      htmlLevel: .moderate, imageQuality: 0.6,
                      defaultResolution: .init(width: 800, height: 600),
                      resolutions: [.init(width: 640, height: 480),
                                    .init(width: 800, height: 600),
                                    .init(width: 1024, height: 768)],
                      eraRange: 1998...2001,
                      supportedColorDepths: [.twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
        VintagePreset(id: "win2000", platform: .pc, osName: "Windows 2000", year: "2000",
                      htmlLevel: .minimal, imageQuality: 0.7,
                      defaultResolution: .init(width: 1024, height: 768),
                      resolutions: [.init(width: 800, height: 600),
                                    .init(width: 1024, height: 768),
                                    .init(width: 1280, height: 1024)],
                      eraRange: 2000...2003,
                      supportedColorDepths: [.twoFiftySix, .thousands],
                      defaultColorDepth: .thousands),
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
    var deadEndpointRedirects: String = ""
    var hasCompletedOnboarding: Bool = false

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
        if let v = try c.decodeIfPresent(String.self, forKey: .deadEndpointRedirects) { deadEndpointRedirects = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) { hasCompletedOnboarding = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .colorDepth) {
            colorDepth = (v == "millions") ? "thousands" : v
        }
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

    struct PlatformMemory {
        var presetId: String
        var resolution: ScreenResolution
        var colorDepth: ColorDepth
    }
    var platformMemory: [VintagePlatform: PlatformMemory] = [:]
    var isRestoringPlatform = false
    @Published var transcodingBypassDomainsText: String = "68kmla.org\nsystem7today.com\nmacintoshgarden.org"
    @Published var minifyHTML: Bool = false
    @Published var colorDepth: ColorDepth = .thousands
    @Published var deadEndpointRedirectsText: String = ""
    @Published var requestLog: [RequestLogEntry] = []
    @Published var startTime: Date = Date()
    @Published var hasCompletedOnboarding: Bool = false
    @Published var activeRequests: Int = 0
    @Published var totalBytesServed: Int64 = 0
    @Published var errorCount: Int = 0
    @Published var recentErrors: [ErrorEntry] = []

    struct ErrorEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let url: String
        let message: String
    }

    var transcodingBypassDomains: Set<String> {
        Set(transcodingBypassDomainsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    var deadEndpointRedirects: [String: String] {
        var map: [String: String] = [:]
        for line in deadEndpointRedirectsText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let host = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let url = parts[1].trimmingCharacters(in: .whitespaces)
            if !host.isEmpty && !url.isEmpty { map[host] = url }
        }
        return map
    }

    var selectedPreset: VintagePreset {
        VintagePreset.all.first { $0.id == presetId } ?? VintagePreset.all[3]
    }
    var htmlLevel: HTMLTranscoder.Level { selectedPreset.htmlLevel }
    var maxImageWidth: Int { max(resolution.width - 40, 320) }
    var imageQuality: Double { selectedPreset.imageQuality }
    var outputEncoding: OutputEncoding { platform == .mac ? .macRoman : .isoLatin1 }

    var uptimeString: String {
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

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
        deadEndpointRedirectsText = s.deadEndpointRedirects
        hasCompletedOnboarding = s.hasCompletedOnboarding

        let preset = VintagePreset.all.first { $0.id == presetId } ?? VintagePreset.all[3]
        if let depth = ColorDepth(rawValue: s.colorDepth), preset.supportedColorDepths.contains(depth) {
            colorDepth = depth
        } else {
            colorDepth = preset.defaultColorDepth
        }

        saveSettings()
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
            colorDepth: colorDepth.rawValue,
            deadEndpointRedirects: deadEndpointRedirectsText,
            hasCompletedOnboarding: hasCompletedOnboarding
        ).save()
    }

    func toggleProxy() {
        if isRunning {
            stopProxy()
            isRunning = false
        } else {
            isRunning = true
            startProxy()
        }
    }

    func restartProxy() {
        stopProxy()
        isRunning = true
        startProxy()
    }

    var browsingMode: BrowsingMode {
        waybackEnabled
            ? .wayback(targetDate: waybackDate, toleranceMonths: waybackToleranceMonths)
            : .liveWeb
    }

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
            deadEndpointRedirects: deadEndpointRedirects,
            onRequestLogged: server.sharedConfig.value.onRequestLogged
        )
        server.temporalCache.clear()
    }

    private func startProxy() {
        startTime = Date()
        let config = ProxyConfiguration(
            browsingMode: browsingMode,
            transcodingLevel: htmlLevel,
            maxImageWidth: maxImageWidth,
            imageQuality: imageQuality,
            outputEncoding: outputEncoding,
            transcodingBypassDomains: transcodingBypassDomains,
            minifyHTML: minifyHTML,
            colorDepth: colorDepth,
            deadEndpointRedirects: deadEndpointRedirects,
            onRequestLogged: { [weak self] entry in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.totalBytesServed += Int64(entry.transcodedSize)
                    let logEntry = RequestLogEntry(
                        timestamp: Date(),
                        method: entry.method,
                        url: entry.url,
                        statusCode: entry.statusCode,
                        originalSize: entry.originalSize,
                        transcodedSize: entry.transcodedSize,
                        waybackDate: entry.waybackDate,
                        contentType: entry.contentType,
                        errorMessage: entry.errorMessage
                    )
                    self.requestLog.insert(logEntry, at: 0)
                    if self.requestLog.count > 500 {
                        self.requestLog = Array(self.requestLog.prefix(500))
                    }
                    if let errorMsg = entry.errorMessage {
                        self.errorCount += 1
                        self.recentErrors.insert(ErrorEntry(
                            timestamp: Date(), url: entry.url, message: errorMsg
                        ), at: 0)
                        if self.recentErrors.count > 20 {
                            self.recentErrors = Array(self.recentErrors.prefix(20))
                        }
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
    let errorMessage: String?
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var state: ProxyState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        case vintageComputer = "Vintage Computer"
        case waybackMachine = "Wayback Machine"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Monitor") {
                    Label("Dashboard", systemImage: "gauge")
                        .tag(SidebarItem.dashboard)
                        .accessibilityLabel("Dashboard")
                        .accessibilityHint("View proxy status and recent requests")
                    Label("Request Log", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.requestLog)
                        .accessibilityLabel("Request Log")
                        .accessibilityHint("View all proxied requests")
                    Label("Wayback Timeline", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.waybackTimeline)
                        .accessibilityLabel("Wayback Timeline")
                        .accessibilityHint("View date accuracy of archived pages")
                }
                Section("Configure") {
                    Label("Vintage Computer", systemImage: "desktopcomputer")
                        .tag(SidebarItem.vintageComputer)
                        .accessibilityLabel("Vintage Computer")
                        .accessibilityHint("Configure target platform and display settings")
                    HStack {
                        Label("Wayback Machine", systemImage: "clock.arrow.circlepath")
                        if state.waybackEnabled {
                            Circle()
                                .fill(Color.gold)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                    }
                    .tag(SidebarItem.waybackMachine)
                    .accessibilityLabel("Wayback Machine")
                    .accessibilityValue(state.waybackEnabled ? "enabled" : "disabled")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch selectedTab {
            case .dashboard:
                dashboardView
            case .requestLog:
                requestLogView
            case .waybackTimeline:
                waybackTimelineView
            case .vintageComputer:
                vintageComputerView
            case .waybackMachine:
                waybackMachineView
            }
        }
        .toolbar(id: "main") {
            ToolbarItem(id: "proxy-toggle", placement: .navigation) {
                Button {
                    state.toggleProxy()
                } label: {
                    Label(state.isRunning ? "Stop" : "Start",
                          systemImage: state.isRunning ? "stop.fill" : "play.fill")
                }
                .tint(state.isRunning ? .red : .green)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help(state.isRunning ? "Stop the proxy server" : "Start the proxy server")
                .accessibilityLabel(state.isRunning ? "Stop proxy server" : "Start proxy server")
            }
            ToolbarItem(id: "wayback-toggle", placement: .navigation) {
                Toggle(isOn: $state.waybackEnabled) {
                    Label("Wayback", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.button)
                .tint(Color.gold)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help(state.waybackEnabled ? "Disable Wayback Machine mode" : "Enable Wayback Machine mode")
                .accessibilityLabel("Wayback Machine mode")
                .accessibilityValue(state.waybackEnabled ? "enabled" : "disabled")
                .accessibilityHint("Toggle between live web and archived Wayback Machine browsing")
                .onChange(of: state.waybackEnabled) {
                    if state.waybackEnabled {
                        state.waybackDate = state.selectedPreset.suggestedWaybackDate
                    }
                    state.saveSettings(); state.syncConfig()
                }
            }
        }
        .toolbarRole(.automatic)
        .navigationTitle("RetroGate")
        .frame(minWidth: 700, minHeight: 450)
        .focusedSceneValue(\.clearLog, ClearLogAction { state.requestLog.removeAll() })
        .sheet(isPresented: Binding(
            get: { !state.hasCompletedOnboarding },
            set: { if !$0 { state.hasCompletedOnboarding = true; state.saveSettings() } }
        )) {
            OnboardingView(localIP: localIP, port: state.port)
        }
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero status
                dashboardHero

                // Stats row
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    DashboardStatCard(
                        icon: "arrow.up.arrow.down",
                        title: "Requests",
                        value: "\(state.requestLog.count)",
                        detail: state.requestLog.isEmpty ? "None yet" : "\(dashboardPageCount) pages"
                    )
                    DashboardStatCard(
                        icon: "arrow.down.circle",
                        title: "Bandwidth",
                        value: ByteCountFormatter.string(fromByteCount: state.totalBytesServed, countStyle: .file),
                        detail: dashboardOriginalBandwidth
                    )
                    DashboardStatCard(
                        icon: "leaf",
                        title: "Saved",
                        value: dashboardSavingsPercent,
                        detail: dashboardSavingsDetail
                    )
                    DashboardStatCard(
                        icon: "clock",
                        title: "Uptime",
                        value: state.isRunning ? state.uptimeString : "—",
                        detail: state.isRunning ? "Running" : "Stopped"
                    )
                }

                // Middle row: Top Domains + Content Breakdown
                HStack(alignment: .top, spacing: 12) {
                    dashboardTopDomains
                    dashboardContentBreakdown
                }

                // Bottom row: Image Stats + Status/Errors
                HStack(alignment: .top, spacing: 12) {
                    dashboardImageStats
                    dashboardStatusCard
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Dashboard — Hero

    private var dashboardHero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.gold.opacity(state.isRunning ? 0.2 : 0.06))
                    .frame(width: 52, height: 52)
                Image(systemName: state.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(state.isRunning ? Color.gold : Color.gold.opacity(0.35))
                    .symbolEffect(.pulse, options: .repeating, isActive: state.isRunning)
            }
            .accessibilityLabel(state.isRunning ? "Proxy running" : "Proxy stopped")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if state.isRunning {
                        if state.waybackEnabled {
                            Text("Proxy running in ")
                                .font(.headline)
                                .foregroundStyle(Color.gold)
                            + Text("Wayback")
                                .font(.headline.bold())
                                .foregroundStyle(Color.gold)
                            + Text(" mode")
                                .font(.headline)
                                .foregroundStyle(Color.gold)
                        } else {
                            Text("Proxy running")
                                .font(.headline)
                                .foregroundStyle(Color.gold)
                        }
                    } else {
                        Text("Proxy Stopped")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(verbatim: "\(localIP):\(String(state.port))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(localIP):\(String(state.port))", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.gold)
                    .help("Copy address to clipboard")
                    .accessibilityLabel("Copy proxy address")
                    Text("·").foregroundStyle(.quaternary)
                    Text(state.selectedPreset.osName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("·").foregroundStyle(.quaternary)
                    Text(state.resolution.label)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: Dashboard — Top Domains

    private var dashboardDomainStats: [(domain: String, count: Int, bytes: Int)] {
        var domainData: [String: (count: Int, bytes: Int)] = [:]
        for entry in state.requestLog {
            let domain = URL(string: entry.url)?.host ?? "unknown"
            let existing = domainData[domain, default: (count: 0, bytes: 0)]
            domainData[domain] = (count: existing.count + 1, bytes: existing.bytes + entry.transcodedSize)
        }
        return domainData
            .map { (domain: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.count > $1.count }
    }

    private var dashboardTopDomains: some View {
        DashboardCard(title: "Top Domains", icon: "globe") {
            if state.requestLog.isEmpty {
                DashboardEmptyState(text: "No requests yet")
            } else {
                let stats = Array(dashboardDomainStats.prefix(5))
                let maxCount = stats.first?.count ?? 1
                VStack(spacing: 8) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.domain)
                                .font(.system(size: 13, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gold.opacity(0.3))
                                    .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(maxCount))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 60, height: 12)
                            Text("\(item.count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.gold)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: Dashboard — Content Breakdown

    private var dashboardContentBreakdown: some View {
        DashboardCard(title: "Content Mix", icon: "chart.bar") {
            if state.requestLog.isEmpty {
                DashboardEmptyState(text: "No requests yet")
            } else {
                let categories = dashboardContentCategories
                let total = max(categories.reduce(0) { $0 + $1.count }, 1)
                VStack(spacing: 8) {
                    // Stacked bar
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                                let fraction = CGFloat(cat.count) / CGFloat(total)
                                if fraction > 0 {
                                    RoundedRectangle(cornerRadius: idx == 0 ? 4 : (idx == categories.count - 1 ? 4 : 2))
                                        .fill(cat.color)
                                        .frame(width: max(geo.size.width * fraction - 1, 4))
                                }
                            }
                        }
                    }
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Legend
                    ForEach(Array(categories.enumerated()), id: \.offset) { _, cat in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cat.color)
                                .frame(width: 8, height: 8)
                            Text(cat.name)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(cat.count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.gold)
                            Text("(\(Int(Double(cat.count) / Double(total) * 100))%)")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private struct ContentCategory {
        let name: String
        let count: Int
        let color: Color
    }

    private var dashboardContentCategories: [ContentCategory] {
        var html = 0, images = 0, css = 0, other = 0
        for entry in state.requestLog {
            let ct = entry.contentType?.lowercased() ?? ""
            if ct.contains("text/html") { html += 1 }
            else if ct.contains("image/") { images += 1 }
            else if ct.contains("text/css") { css += 1 }
            else { other += 1 }
        }
        return [
            ContentCategory(name: "HTML", count: html, color: Color.gold),
            ContentCategory(name: "Images", count: images, color: Color.goldLight),
            ContentCategory(name: "CSS", count: css, color: Color.gold.opacity(0.45)),
            ContentCategory(name: "Other", count: other, color: Color.gold.opacity(0.2)),
        ].filter { $0.count > 0 }
    }

    // MARK: Dashboard — Image Stats

    private var dashboardImageStats: some View {
        DashboardCard(title: "Image Transcoding", icon: "photo") {
            let imageEntries = state.requestLog.filter { $0.contentType?.contains("image/") == true }
            if imageEntries.isEmpty {
                DashboardEmptyState(text: "No images transcoded")
            } else {
                let totalOriginal = imageEntries.reduce(0) { $0 + $1.originalSize }
                let totalTranscoded = imageEntries.reduce(0) { $0 + $1.transcodedSize }
                let savings = totalOriginal > 0 ? Int((1.0 - Double(totalTranscoded) / Double(totalOriginal)) * 100) : 0
                VStack(spacing: 10) {
                    HStack {
                        DashboardMiniStat(label: "Images", value: "\(imageEntries.count)")
                        Spacer()
                        DashboardMiniStat(label: "Original", value: ByteCountFormatter.string(fromByteCount: Int64(totalOriginal), countStyle: .file))
                        Spacer()
                        DashboardMiniStat(label: "Transcoded", value: ByteCountFormatter.string(fromByteCount: Int64(totalTranscoded), countStyle: .file))
                    }

                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gold.opacity(0.12))
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gold.opacity(0.5))
                                    .frame(width: totalOriginal > 0 ? geo.size.width * CGFloat(totalTranscoded) / CGFloat(totalOriginal) : 0)
                            }
                        }
                        .frame(height: 10)

                        Text("\(savings)% smaller after transcoding")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.gold)
                    }
                }
            }
        }
    }

    // MARK: Dashboard — Status / Errors / Wayback

    private var dashboardStatusCard: some View {
        DashboardCard(title: state.waybackEnabled ? "Wayback Mode" : "Status", icon: state.waybackEnabled ? "clock.arrow.circlepath" : "checkmark.shield") {
            VStack(spacing: 10) {
                if state.waybackEnabled {
                    let dateFormatter: DateFormatter = {
                        let f = DateFormatter()
                        f.dateFormat = "MMMM d, yyyy"
                        return f
                    }()
                    HStack {
                        Text("Target")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(dateFormatter.string(from: state.waybackDate))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.gold)
                    }
                    HStack {
                        Text("Tolerance")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(state.waybackToleranceMonths == 0 ? "Any date" : "\(state.waybackToleranceMonths) months")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.gold)
                    }
                    HStack {
                        Text("Era")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(state.selectedPreset.eraDescription)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.gold)
                    }
                }

                HStack {
                    Text("Errors")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let errorRate = state.requestLog.isEmpty ? 0 : Int(Double(state.errorCount) / Double(state.requestLog.count) * 100)
                    Text(state.errorCount == 0 ? "None" : "\(state.errorCount) (\(errorRate)%)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(state.errorCount == 0 ? Color.gold : Color.gold.opacity(0.7))
                }

                if !state.recentErrors.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(state.recentErrors.prefix(2))) { error in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.gold.opacity(0.5))
                                Text(ContentView.shortURL(error.url))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dashboardInfoRow(_ label: String, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: bold ? .semibold : .medium, design: .rounded))
                .foregroundStyle(Color.gold)
        }
    }

    // MARK: Dashboard — Computed Stats

    private var dashboardPageCount: Int {
        state.requestLog.filter { $0.contentType?.contains("text/html") == true }.count
    }

    private var dashboardOriginalBandwidth: String {
        let original = state.requestLog.reduce(0) { $0 + Int64($1.originalSize) }
        return "from \(ByteCountFormatter.string(fromByteCount: original, countStyle: .file))"
    }

    private var dashboardSavingsPercent: String {
        let original = state.requestLog.reduce(0) { $0 + $1.originalSize }
        let transcoded = state.requestLog.reduce(0) { $0 + $1.transcodedSize }
        guard original > 0 else { return "—" }
        let pct = Int((1.0 - Double(transcoded) / Double(original)) * 100)
        return "\(pct)%"
    }

    private var dashboardSavingsDetail: String {
        let original = state.requestLog.reduce(0) { $0 + Int64($1.originalSize) }
        let transcoded = state.requestLog.reduce(0) { $0 + Int64($1.transcodedSize) }
        let saved = original - transcoded
        guard saved > 0 else { return "No savings yet" }
        return "\(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) saved"
    }

    // MARK: - Vintage Computer

    private var vintageComputerView: some View {
        Form {
            Section("Platform") {
                Picker("Platform", selection: $state.platform) {
                    ForEach(VintagePlatform.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Target platform")
            }

            Section("Hardware") {
                Picker("Operating System", selection: $state.presetId) {
                    ForEach(VintagePreset.forPlatform(state.platform)) { preset in
                        Text("\(preset.osName) (\(preset.year))").tag(preset.id)
                    }
                }
                .accessibilityLabel("Operating system preset")

                Picker("Screen Resolution", selection: $state.resolution) {
                    ForEach(state.selectedPreset.resolutions, id: \.self) { res in
                        Text(res.label).tag(res)
                    }
                }
                .accessibilityLabel("Screen resolution")

                if state.selectedPreset.supportedColorDepths.count > 1 {
                    Picker("Color Depth", selection: $state.colorDepth) {
                        ForEach(state.selectedPreset.supportedColorDepths, id: \.self) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }
                    .accessibilityLabel("Display color depth")
                }
            }

            Section {
                LabeledContent("Transcoding") {
                    Text(transcodingLevelLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcoding level: \(transcodingLevelLabel)")
                LabeledContent("Encoding") {
                    Text(state.outputEncoding.displayName)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Character encoding: \(state.outputEncoding.displayName)")
                LabeledContent("Image Quality") {
                    Text("\(Int(state.imageQuality * 100))%")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Image quality: \(Int(state.imageQuality * 100)) percent")
                LabeledContent("Max Image Width") {
                    Text("\(state.maxImageWidth)px")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Maximum image width: \(state.maxImageWidth) pixels")
            } header: {
                Text("Derived Settings")
            } footer: {
                Text("These are determined automatically by your preset choice.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.platform) { oldPlatform, newPlatform in
            state.platformMemory[oldPlatform] = ProxyState.PlatformMemory(
                presetId: state.presetId, resolution: state.resolution, colorDepth: state.colorDepth
            )
            if let mem = state.platformMemory[newPlatform] {
                state.isRestoringPlatform = true
                state.presetId = mem.presetId
                state.resolution = mem.resolution
                state.colorDepth = mem.colorDepth
                state.isRestoringPlatform = false
            } else if let first = VintagePreset.forPlatform(newPlatform).first {
                state.presetId = first.id
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.presetId) {
            guard !state.isRestoringPlatform else { return }
            if let preset = VintagePreset.all.first(where: { $0.id == state.presetId }) {
                state.resolution = preset.defaultResolution
                if !preset.supportedColorDepths.contains(state.colorDepth) {
                    state.colorDepth = preset.defaultColorDepth
                }
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.resolution) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.colorDepth) { state.saveSettings(); state.syncConfig() }
    }

    private var transcodingLevelLabel: String {
        switch state.htmlLevel {
        case .minimal: return "Minimal (CSS preserved)"
        case .moderate: return "Moderate (CSS stripped)"
        case .aggressive: return "Aggressive (HTML 3.2)"
        }
    }

    // MARK: - Wayback Machine

    private var waybackMachineView: some View {
        Form {
            Section {
                Toggle("Enable Wayback Mode", isOn: $state.waybackEnabled)
                    .tint(Color.gold)
                    .accessibilityHint("Browse the web as it was in the past using the Internet Archive")
            } footer: {
                Text("Fetches pages from the Internet Archive instead of the live web, letting you browse the web as it was in the past.")
            }

            if state.waybackEnabled {
                Section("Time Travel") {
                    DatePicker("Target date", selection: $state.waybackDate, displayedComponents: .date)
                        .accessibilityLabel("Target date for Wayback Machine browsing")

                    Picker("Date tolerance", selection: $state.waybackToleranceMonths) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("9 months").tag(9)
                        Text("12 months").tag(12)
                        Text("Any date").tag(0)
                    }
                    .accessibilityLabel("Maximum date tolerance for archived snapshots")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.waybackEnabled) {
            if state.waybackEnabled {
                state.waybackDate = state.selectedPreset.suggestedWaybackDate
            }
            state.saveSettings(); state.syncConfig()
        }
        .onChange(of: state.waybackDate) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.waybackToleranceMonths) { state.saveSettings(); state.syncConfig() }
    }

    // MARK: - Request Log

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
                            .accessibilityLabel("Time: \(entry.timestamp.formatted(date: .omitted, time: .shortened))")
                    }
                    .width(min: 70, max: 90)

                    TableColumn("Method") { entry in
                        Text(entry.method)
                            .fontWeight(.medium)
                            .accessibilityLabel("Method: \(entry.method)")
                    }
                    .width(min: 50, max: 60)

                    TableColumn("URL") { entry in
                        HStack(spacing: 4) {
                            if entry.errorMessage != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                    .accessibilityLabel("Error")
                            }
                            Text(entry.url)
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
                        .accessibilityLabel("URL: \(entry.url)")
                    }

                    TableColumn("Status") { entry in
                        Text("\(entry.statusCode)")
                            .foregroundColor(entry.statusCode < 400 ? .primary : .red)
                            .accessibilityLabel("Status: \(entry.statusCode)")
                    }
                    .width(min: 50, max: 60)

                    TableColumn("Size") { entry in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.transcodedSize), countStyle: .file))
                            .accessibilityLabel("Size: \(ByteCountFormatter.string(fromByteCount: Int64(entry.transcodedSize), countStyle: .file))")
                    }
                    .width(min: 60, max: 80)
                }
            }
        }
    }

    // MARK: - Wayback Timeline

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
                        Text(Self.shortURL(entry.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contextMenu {
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.url, forType: .string)
                                }
                            }
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
                                .accessibilityLabel("Date difference: \(delta.label)")
                        }
                    }
                    .width(min: 80, max: 120)
                }
            }
        }
    }

    // MARK: - Helpers

    static func shortURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let host = url.host ?? ""
        let path = url.path
        if path == "/" || path.isEmpty {
            return host
        }
        return host + path
    }

    static func formatWaybackDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private static func formatDateStamp(_ stamp: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        guard let date = f.date(from: stamp) else { return stamp }
        let display = DateFormatter()
        display.dateFormat = "MMM d, yyyy"
        return display.string(from: date)
    }

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

        let color: Color = absDays <= 7 ? .green : absDays <= 90 ? Color.gold : .red
        return (label, color, false)
    }
}

// MARK: - Dashboard Components

struct DashboardStatCard: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.gold)

            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.gold)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(Color.gold.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(detail)")
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gold.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.12), lineWidth: 0.5)
        )
    }
}

struct DashboardEmptyState: View {
    let text: String
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardMiniStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.gold)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let localIP: String
    let port: UInt16
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.gold)
                    .accessibilityHidden(true)

                Text("Welcome to RetroGate")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)

                Text("Browse the modern web from vintage computers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 24)

            // Steps
            VStack(alignment: .leading, spacing: 20) {
                // Step 1 — with embedded address
                HStack(alignment: .top, spacing: 14) {
                    OnboardingBadge(number: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set your HTTP proxy to:")
                            .font(.callout.bold())
                        Text(verbatim: "\(localIP):\(String(port))")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(Color.gold)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Proxy address: \(localIP) port \(String(port))")
                        Text("In your vintage browser's network preferences.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Step 2
                HStack(alignment: .top, spacing: 14) {
                    OnboardingBadge(number: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start browsing")
                            .font(.callout.bold())
                        Text("Navigate to any website. RetroGate fetches, transcodes HTML, and converts images automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Step 3
                HStack(alignment: .top, spacing: 14) {
                    OnboardingBadge(number: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try Wayback mode")
                            .font(.callout.bold())
                        Text("Enable Wayback Machine in the toolbar to browse the web as it was in the era of your vintage OS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 48)

            Spacer()

            // CTA button
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("Start Browsing")
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .frame(width: 180, height: 38)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Color.gold)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .animation(.spring(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
            .accessibilityLabel("Dismiss onboarding and start browsing")
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 500)
    }
}

struct OnboardingBadge: View {
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(.caption, design: .rounded).bold())
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.gold, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Keyboard Shortcut Commands

struct ClearLogAction {
    let perform: () -> Void
}

struct ClearLogActionKey: FocusedValueKey {
    typealias Value = ClearLogAction
}

extension FocusedValues {
    var clearLog: ClearLogAction? {
        get { self[ClearLogActionKey.self] }
        set { self[ClearLogActionKey.self] = newValue }
    }
}

struct RetroGateCommands: Commands {
    @FocusedValue(\.clearLog) var clearLogAction

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Clear Request Log") {
                clearLogAction?.perform()
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - Settings (Cmd+,)

struct SettingsView: View {
    @EnvironmentObject var state: ProxyState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var state: ProxyState
    @State private var pendingPort: UInt16?

    var body: some View {
        Form {
            Section("Proxy Server") {
                HStack {
                    TextField("Port", value: $state.port, format: .number.grouping(.never))
                        .frame(width: 100)
                        .accessibilityLabel("Proxy server port")
                        .onChange(of: state.port) { _, newPort in
                            pendingPort = newPort
                        }
                    if pendingPort != nil {
                        Button("Apply") {
                            state.saveSettings()
                            state.restartProxy()
                            pendingPort = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.gold)
                        .accessibilityLabel("Apply port change and restart proxy")
                    }
                }
            }

            Section("Transcoding") {
                Toggle("Minify HTML", isOn: $state.minifyHTML)
                    .accessibilityLabel("Minify HTML output")
                    .accessibilityHint("Reduces bandwidth by removing whitespace and comments from HTML")

                LabeledContent("Level") {
                    switch state.htmlLevel {
                    case .minimal: Text("Minimal — CSS preserved")
                    case .moderate: Text("Moderate — CSS stripped")
                    case .aggressive: Text("Aggressive — HTML 3.2")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.minifyHTML) { state.saveSettings(); state.syncConfig() }
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject var state: ProxyState

    var body: some View {
        Form {
            Section {
                TextEditor(text: $state.transcodingBypassDomainsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .accessibilityLabel("Transcoding bypass domains")
                    .accessibilityHint("One domain per line. These sites skip HTML transcoding.")
            } header: {
                Text("Transcoding Bypass Domains")
            } footer: {
                Text("One domain per line. These sites skip HTML transcoding.")
            }

            Section {
                TextEditor(text: $state.deadEndpointRedirectsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .accessibilityLabel("Dead endpoint redirects")
                    .accessibilityHint("Format: host equals URL, one per line. Overrides built-in defaults.")
            } header: {
                Text("Dead Endpoint Redirects")
            } footer: {
                Text("Format: host=url (one per line). Overrides built-in defaults.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: state.transcodingBypassDomainsText) { state.saveSettings(); state.syncConfig() }
        .onChange(of: state.deadEndpointRedirectsText) { state.saveSettings(); state.syncConfig() }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.gold)
                .accessibilityHidden(true)

            Text("RetroGate")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("A proxy server that lets vintage computers browse the modern web.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 2) {
                Text("Built with")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text("SwiftNIO · SwiftSoup · CoreGraphics")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.horizontal, 60)

            Text("© 2024-2026 Bruno van Branden (Simplinity)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Menu Bar Extra

struct MenuBarView: View {
    @EnvironmentObject var state: ProxyState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if state.isRunning {
                Label("Proxy Running on :\(String(state.port))", systemImage: "circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.green)
            } else {
                Label("Proxy Stopped", systemImage: "circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red)
            }

            Divider()

            Button(state.isRunning ? "Stop Proxy" : "Start Proxy") {
                state.toggleProxy()
            }

            Toggle("Wayback Machine", isOn: Binding(
                get: { state.waybackEnabled },
                set: { newValue in
                    state.waybackEnabled = newValue
                    if newValue {
                        state.waybackDate = state.selectedPreset.suggestedWaybackDate
                    }
                    state.saveSettings()
                    state.syncConfig()
                }
            ))

            Divider()

            Text("\(state.selectedPreset.osName) — \(state.resolution.label)")
                .font(.caption)

            if state.waybackEnabled {
                let formatter: DateFormatter = {
                    let f = DateFormatter()
                    f.dateStyle = .medium
                    return f
                }()
                Text("Wayback: \(formatter.string(from: state.waybackDate))")
                    .font(.caption)
            }

            if state.requestLog.count > 0 {
                Text("\(state.requestLog.count) requests · \(ByteCountFormatter.string(fromByteCount: state.totalBytesServed, countStyle: .file))")
                    .font(.caption)
            }

            Divider()

            Button("Open RetroGate") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .keyboardShortcut("o")

            Divider()

            Button("Quit RetroGate") {
                if state.isRunning { state.toggleProxy() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        }
    }
}
