import Foundation
import Darwin

@main struct MenuLifecycle {
    static func wait(_ predicate: () -> Bool, timeout: Double = 25) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NSError(domain: "MenuLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for worker"])
    }

    static func main() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        let state = base.appendingPathComponent("state")
        for url in [a, b, state] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        let configURL = state.appendingPathComponent("config.json")
        var config = Configuration()
        config.roots = [a.path]; config.quietSeconds = 3; config.directoryQuietSeconds = 3; config.protectedApps = []
        try JSONEncoder().encode(config).write(to: configURL)
        let pendingName = "제거후유지.txt".decomposedStringWithCanonicalMapping
        try Data("keep bytes".utf8).write(to: a.appendingPathComponent(pendingName))
        let session = MenuSession(directory: state.path, configPath: configURL.path, executable: executable)
        try session.start()
        defer { session.stop() }
        try wait { session.snapshot().pending > 0 }
        try session.changeRoots(removing: a.path)
        Thread.sleep(forTimeInterval: 4)
        let untouched = try FileManager.default.contentsOfDirectory(atPath: a.path)
        precondition(untouched.contains { Array($0.utf8) == Array(pendingName.utf8) })
        let empty = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        precondition(empty.roots == [])

        try Data("second".utf8).write(to: b.appendingPathComponent("추가.txt".decomposedStringWithCanonicalMapping))
        try session.changeRoots(adding: [b.path])
        try wait { (try? FileManager.default.contentsOfDirectory(atPath: b.path))?.contains { Array($0.utf8) == Array("추가.txt".utf8) } == true }
        try session.togglePause()
        precondition(session.snapshot().title == "일시중지")
        let held = "멈춤.txt".decomposedStringWithCanonicalMapping
        try Data("paused".utf8).write(to: b.appendingPathComponent(held))
        Thread.sleep(forTimeInterval: 4)
        let heldNames = try FileManager.default.contentsOfDirectory(atPath: b.path)
        precondition(heldNames.contains { Array($0.utf8) == Array(held.utf8) })
        try session.togglePause()
        try wait { (try? FileManager.default.contentsOfDirectory(atPath: b.path))?.contains { Array($0.utf8) == Array("멈춤.txt".utf8) } == true }
        session.stop()
        precondition(session.snapshot().title == "감시 중단")
        let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        precondition(saved.roots == [physicalPath(b.path)], "Selected folder must persist as its physical path")
        let defaults = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        precondition(defaults.roots == nil && defaults.quietSeconds == 10)
        print("PASS: removed-root pending work cancelled, add root, pause/resume, worker exit, preserved configuration")
    }
}
