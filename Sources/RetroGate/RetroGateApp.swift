import SwiftUI
import Logging

@main
struct RetroGateApp: App {
    @StateObject private var proxyState = ProxyState()
    
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
    @Published var isRunning = false
    @Published var port: UInt16 = 8080
    @Published var waybackEnabled = false
    @Published var waybackDate = Date()
    @Published var transcodingLevel: TranscodingLevel = .aggressive
    @Published var maxImageWidth: Int = 640
    @Published var imageQuality: Double = 0.6
    @Published var requestLog: [RequestLogEntry] = []
    
    enum TranscodingLevel: String, CaseIterable, Identifiable {
        case minimal = "Minimal (TLS bridge only)"
        case moderate = "Moderate (simplify HTML)"
        case aggressive = "Aggressive (HTML 3.2)"
        
        var id: String { rawValue }
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
        // TODO: resolve actual local IP
        "192.168.1.x"
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List {
                Section("Proxy") {
                    Label("Dashboard", systemImage: "gauge")
                    Label("Request Log", systemImage: "list.bullet.rectangle")
                }
                Section("Settings") {
                    Label("Transcoding", systemImage: "doc.richtext")
                    Label("Wayback Machine", systemImage: "clock.arrow.circlepath")
                    Label("Network", systemImage: "network")
                }
            }
            .listStyle(.sidebar)
        } detail: {
            // Dashboard
            VStack(spacing: 24) {
                // Big on/off toggle
                VStack(spacing: 8) {
                    Image(systemName: state.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(state.isRunning ? .green : .secondary)
                    
                    Toggle(isOn: $state.isRunning) {
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
                
                // Wayback toggle
                GroupBox("Wayback Machine") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Wayback Mode", isOn: $state.waybackEnabled)
                        if state.waybackEnabled {
                            DatePicker("Browse the web as it was on:", selection: $state.waybackDate, displayedComponents: .date)
                        }
                    }
                    .padding(4)
                }
                
                // Transcoding
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
