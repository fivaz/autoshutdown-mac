import Foundation
import ServiceManagement

/// Starting at login without an installer.
///
/// On macOS 13 and later this is `SMAppService`, which registers the app bundle itself
/// and shows up in System Settings under General > Login Items. Nothing is written
/// outside the bundle, which is what lets the app ship as a plain drag-and-drop .app.
///
/// Older systems fall back to a LaunchAgent in the user's own Library.
enum LoginItem {

    static let label = "com.fivaz.autoshutdown"

    private static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// A LaunchAgent left behind by an older installer package or by install.sh.
    /// Both would launch the app a second time at login, so the app steps aside
    /// rather than registering itself on top of them.
    static var conflictingAgent: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist"),
            legacyAgentURL,
        ]
        if #available(macOS 13.0, *) {
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        // Below macOS 13 the user-level agent is our own mechanism, not a conflict.
        return FileManager.default.fileExists(atPath: candidates[0].path) ? candidates[0] : nil
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: legacyAgentURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                NSLog("AutoShutdown: login item change failed: \(error.localizedDescription)")
                return false
            }
        }
        return enabled ? writeLegacyAgent() : removeLegacyAgent()
    }

    // MARK: macOS 12 fallback

    private static func writeLegacyAgent() -> Bool {
        let executable = Bundle.main.executableURL?.path ?? ""
        guard !executable.isEmpty else { return false }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        do {
            try FileManager.default.createDirectory(
                at: legacyAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: legacyAgentURL, options: .atomic)
            run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", legacyAgentURL.path])
            return true
        } catch {
            NSLog("AutoShutdown: could not write login item: \(error.localizedDescription)")
            return false
        }
    }

    private static func removeLegacyAgent() -> Bool {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: legacyAgentURL)
        return true
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
