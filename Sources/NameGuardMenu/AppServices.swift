import Foundation
import Darwin

enum AppLocation {
    static func bundle(executable: String) -> URL? {
        let url = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return url.pathExtension == "app" ? url : nil
    }
    static func defaultDirectory(executable: String, home: String) -> String {
        guard let app = bundle(executable: executable) else { return home + "/Library/Application Support/NameGuard" }
        let parent = app.deletingLastPathComponent()
        let root = parent.lastPathComponent == "Applications" && parent.path != "/Applications" ? parent.deletingLastPathComponent().path : home
        return root + "/Library/Application Support/" + (app.lastPathComponent == "NameGuard Desktop.app" ? "NameGuardDesktop" : "NameGuard")
    }
}

public func nameGuardDefaultDirectory(executable: String, home: String) -> String {
    AppLocation.defaultDirectory(executable: executable, home: home)
}

func serviceError(_ message: String) -> NSError {
    NSError(domain: "NameGuard", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
}

@discardableResult
func runCommand(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw serviceError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return output
}

final class LoginStartup {
    let executable: String
    let directory: String
    let home: String
    let label: String
    let agentURL: URL
    private let run: (String, [String]) throws -> String
    private var target: String { "gui/\(getuid())/\(label)" }

    init(executable: String, directory: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         run: @escaping (String, [String]) throws -> String = runCommand) {
        self.executable = executable; self.directory = directory; self.home = home; self.run = run
        label = URL(fileURLWithPath: directory).lastPathComponent == "NameGuard" ? "local.nameguard.agent" : "local.nameguard.desktop.agent"
        agentURL = URL(fileURLWithPath: home + "/Library/LaunchAgents/\(label).plist")
    }
    var isEnabled: Bool {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return false }
        guard let output = try? run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]) else { return false }
        return !output.contains("\"\(label)\" => true")
    }
    func ensureRegistered() throws {
        guard let app = AppLocation.bundle(executable: executable), app.deletingLastPathComponent().path == home + "/Applications" else { return }
        // An absent preference means first launch. Explicitly disabled startup stays disabled.
        let preference = URL(fileURLWithPath: directory + "/login.json")
        if FileManager.default.fileExists(atPath: preference.path) { return }
        try setEnabled(true)
    }
    func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if enabled {
            try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable, "--menu", "--state-dir", directory],
                "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 60, "ProcessType": "Interactive",
                "StandardOutPath": directory + "/launchd.stdout.log", "StandardErrorPath": directory + "/launchd.stderr.log"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
            _ = try run("/bin/launchctl", ["enable", target])
        } else {
            _ = try run("/bin/launchctl", ["disable", target])
            if fm.fileExists(atPath: agentURL.path) { try fm.removeItem(at: agentURL) }
            // Do not bootout: changing next-login behavior must not close the running app.
        }
        try JSONSerialization.data(withJSONObject: ["enabled": enabled]).write(to: URL(fileURLWithPath: directory + "/login.json"), options: .atomic)
    }
}
