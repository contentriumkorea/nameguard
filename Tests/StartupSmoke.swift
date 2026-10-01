import Foundation
import Darwin

@main struct StartupSmoke {
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let state = base.appendingPathComponent("Library/Application Support/NameGuardDesktop")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{\"roots\":[],\"protectedApps\":[]}".utf8).write(to: state.appendingPathComponent("config.json"))
        try Data("{\"paused\":true}".utf8).write(to: state.appendingPathComponent("menu.json"))
        let login = LoginStartup(executable: URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path, directory: state.path, home: base.path)
        let target = "gui/\(getuid())/\(login.label)"
        defer {
            _ = try? runCommand("/bin/launchctl", ["bootout", target])
            _ = try? runCommand("/bin/launchctl", ["enable", target])
            try? FileManager.default.removeItem(at: base)
        }
        try runCommand("/bin/launchctl", ["disable", target])
        try login.setEnabled(true)
        precondition(login.isEnabled, "Previously disabled launchd job must be enabled again")
        for cycle in 0..<2 {
            print("Startup verification cycle \(cycle): enabling and registering", terminator: "\n")
            try login.setEnabled(true)
            do { try runCommand("/bin/launchctl", ["bootstrap", "gui/\(getuid())", login.agentURL.path]) }
            catch {
                print("Startup bootstrap failed in cycle \(cycle): \(error)")
                print((try? runCommand("/bin/launchctl", ["print", target])) ?? "Job not loaded")
                print((try? runCommand("/bin/launchctl", ["print-disabled", "gui/\(getuid())"])) ?? "Disabled status unavailable")
                throw error
            }
            Thread.sleep(forTimeInterval: 3)
            let running = try runCommand("/bin/launchctl", ["print", target])
            precondition(running.contains("state = running"), "RunAtLoad must start the real native menu app")
            if cycle == 1 {
                try login.setEnabled(false)
                let stillRunning = try runCommand("/bin/launchctl", ["print", target])
                precondition(stillRunning.contains("state = running"), "Disabling next-login startup must keep the current app running")
            }
            try runCommand("/bin/launchctl", ["bootout", target])
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, (try? runCommand("/bin/launchctl", ["print", target])) != nil {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        try login.setEnabled(false)
        precondition(!login.isEnabled)
        precondition(!FileManager.default.fileExists(atPath: login.agentURL.path))
        let saved = try String(contentsOf: state.appendingPathComponent("menu.json"), encoding: .utf8)
        precondition(saved == "{\"paused\":true}")
        print("PASS: disabled login job repaired, real RunAtLoad menu startup twice, startup disable, pause settings retained")
    }
}
