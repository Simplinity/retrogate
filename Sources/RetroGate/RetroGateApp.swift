import SwiftUI
import Logging
import ProxyServer
import HTMLTranscoder

@main
struct RetroGateApp: App {
    @StateObject private var proxyState = ProxyState()

    init() {
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
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 680, height: 520)

        Settings {
            SettingsView()
                .environmentObject(proxyState)
        }
    }
}

// MARK: - App State

@MainActor
class ProxyState: ObservableObject {
    @Published var isRunning = true
    @Published var port: UInt16 = 8080
    @Published var waybackEnabled = false
    @Published var waybackDate = Date()
    @Published var transcodingLevel: TranscodingLevel = .aggressive
    @Published var maxImageWidth: Int = 640
    @Published var imageQuality: Double = 0.6
    @Published var requestLog: [RequestLogEntry] = []

    private var server: ProxyServer?
    private var serverTask: Task<Void, Never>?

    init() {
        startProxy()
    }

    enum TranscodingLevel: String, CaseIterable, Identifiable {
        case minimal = "Minimal (TLS bridge only)"
        case moderate = "Moderate (simplify HTML)"
        case aggressive = "Aggressive (HTML 3.2)"

        var id: String { rawValue }

        var htmlLevel: HTMLTranscoder.Level {
            switch self {
            case .minimal: return .minimal
            case .moderate: return .moderate
            case .aggressive: return .aggressive
            }
        }
    }

    func toggleProxy() {
        if isRunning {
            startProxy()
        } else {
            stopProxy()
        }
    }

    /// Push current UI settings to the running server's shared config.
    func syncConfig() {
        guard let server = server else { return }
        server.sharedConfig.value = ProxyConfiguration(
            transcodingLevel: transcodingLevel.htmlLevel,
            waybackEnabled: waybackEnabled,
            waybackDate: waybackDate,
            maxImageWidth: maxImageWidth,
            imageQuality: imageQuality,
            onRequestLogged: server.sharedConfig.value.onRequestLogged
        )
    }

    private func startProxy() {
        let config = ProxyConfiguration(
            transcodingLevel: transcodingLevel.htmlLevel,
            waybackEnabled: waybackEnabled,
            waybackDate: waybackDate,
            maxImageWidth: maxImageWidth,
            imageQuality: imageQuality,
            onRequestLogged: { [weak self] entry in
                Task { @MainActor in
                    self?.requestLog.insert(RequestLogEntry(
                        timestamp: Date(),
                        method: entry.method,
                        url: entry.url,
                        statusCode: entry.statusCode,
                        originalSize: entry.originalSize,
                        transcodedSize: entry.transcodedSize
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
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Proxy") {
                    Label("Dashboard", systemImage: "gauge")
                        .tag(SidebarItem.dashboard)
                    Label("Request Log", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.requestLog)
                }
                Section("Settings") {
                    Label("Transcoding", systemImage: "doc.richtext")
                    Label("Wayback Machine", systemImage: "clock.arrow.circlepath")
                    Label("Network", systemImage: "network")
                }
            }
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case .dashboard:
                dashboardView
            case .requestLog:
                requestLogView
            }
        }
    }

    private var dashboardView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: state.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(state.isRunning ? .green : .secondary)

                Toggle(isOn: Binding(
                    get: { state.isRunning },
                    set: { newValue in
                        state.isRunning = newValue
                        state.toggleProxy()
                    }
                )) {
                    Text(state.isRunning ? "Proxy Running" : "Proxy Stopped")
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .labelsHidden()

                if state.isRunning {
                    Text("Configure your vintage Mac's HTTP proxy to:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(localIP):\(state.port)")
                        .font(.system(.title2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding()

            GroupBox("Wayback Machine") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Wayback Mode", isOn: $state.waybackEnabled)
                    if state.waybackEnabled {
                        DatePicker("Browse the web as it was on:", selection: $state.waybackDate, displayedComponents: .date)
                    }
                }
                .padding(4)
            }

            GroupBox("Transcoding") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Level", selection: $state.transcodingLevel) {
                        ForEach(ProxyState.TranscodingLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Max image width: \(state.maxImageWidth)px")
                        Slider(value: .init(
                            get: { Double(state.maxImageWidth) },
                            set: { state.maxImageWidth = Int($0) }
                        ), in: 320...1024, step: 64)
                    }
                }
                .padding(4)
            }

            Spacer()
        }
        .padding()
        .onChange(of: state.transcodingLevel) { state.syncConfig() }
        .onChange(of: state.waybackEnabled) { state.syncConfig() }
        .onChange(of: state.waybackDate) { state.syncConfig() }
        .onChange(of: state.maxImageWidth) { state.syncConfig() }
        .onChange(of: state.imageQuality) { state.syncConfig() }
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
}

struct SettingsView: View {
    @EnvironmentObject var state: ProxyState

    var body: some View {
        Form {
            TextField("Port", value: $state.port, format: .number)
        }
        .padding()
        .frame(width: 400)
    }
}
