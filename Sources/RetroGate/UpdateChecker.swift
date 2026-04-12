import AppKit

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }
}

private struct SemanticVersion: Comparable {
    let major: Int, minor: Int, patch: Int

    init?(_ string: String) {
        let cleaned = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        major = parts[0]
        minor = parts[1]
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

@MainActor
enum UpdateChecker {
    private static var hasChecked = false

    static func checkForUpdate() async {
        guard !hasChecked else { return }
        hasChecked = true

        do {
            try await Task.sleep(for: .seconds(2))

            guard let currentString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let current = SemanticVersion(currentString) else { return }

            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Simplinity/retrogate/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("RetroGate/\(currentString)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            guard let latest = SemanticVersion(release.tagName), latest > current else { return }

            let alert = NSAlert()
            alert.messageText = "Update Available"
            var message = "RetroGate \(release.tagName) is available (you have \(currentString))."
            if let notes = release.body, !notes.isEmpty {
                message += "\n\n" + String(notes.prefix(500))
            }
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: release.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            }
        } catch {
            // Fail silently — update check is best-effort
        }
    }
}
