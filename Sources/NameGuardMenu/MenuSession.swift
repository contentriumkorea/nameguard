import Foundation
import Darwin
#if canImport(NameGuard)
import NameGuard
#endif

// All methods run on one background queue owned by MenuApp, never the AppKit thread.
final class MenuSession {
    let directory: String
    let configuration: MenuConfiguration
    let executable: String
    private var process: Process?
    private var output: FileHandle?
    private var lockFD: Int32 = -1
    private var ownsLock = false
    private var paused = false
    private var error = ""
    private var renamedBeforeRestart = 0
    var healthy: Bool { ownsLock && (paused || process?.isRunning == true) }

    init(directory: String, configPath: String, executable: String) {
        self.directory = directory
        self.configuration = MenuConfiguration(url: URL(fileURLWithPath: configPath))
        self.executable = executable
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        lockFD = open(directory + "/menu.lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: "NameGuard", code: 3, userInfo: [NSLocalizedDescriptionKey: "NameGuard 메뉴가 이미 실행 중입니다."])
        }
        // Do not pass the UI's lock to a child process.
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        ownsLock = true
        if !FileManager.default.fileExists(atPath: configuration.url.path) {
            var defaults = Configuration()
            defaults.roots = [FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop"]
            try FileManager.default.createDirectory(at: configuration.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(defaults).write(to: configuration.url, options: .atomic)
        }
        if let data = FileManager.default.contents(atPath: directory + "/menu.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            paused = object["paused"] as? Bool ?? false
        }
        if !paused { try launch() }
    }

    private func loadConfiguration() throws -> Configuration {
        let data = try Data(contentsOf: configuration.url)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.quietSeconds.isFinite, config.directoryQuietSeconds.isFinite,
              config.quietSeconds >= 1, config.directoryQuietSeconds >= config.quietSeconds else {
            throw NSError(domain: "NameGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "설정의 대기 시간이 잘못되었습니다."])
        }
        return config
    }

    private func ensureOwnership() throws {
        guard ownsLock else {
            throw NSError(domain: "NameGuard", code: 3, userInfo: [NSLocalizedDescriptionKey: "다른 NameGuard 메뉴가 실행 중입니다. 이 메뉴를 종료해 주세요."])
        }
    }

    private func launch() throws {
        _ = try loadConfiguration()
        let logURL = URL(fileURLWithPath: directory + "/menu-worker.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        output = try FileHandle(forWritingTo: logURL)
        try output?.seekToEnd()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--watch", "--config", configuration.url.path, "--state-dir", directory,
                           "--parent-pid", String(getpid())]
        child.standardOutput = output
        child.standardError = output
        try child.run()
        process = child
        error = ""
    }

    private func status() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: directory + "/status.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func snapshot() -> MenuSnapshot {
        let state = status()
        let pid = process.flatMap { $0.isRunning ? $0.processIdentifier : nil }
        var result = MenuSnapshot(status: state, runningPID: pid, paused: paused)
        if let roots = (try? configuration.read())?["roots"] as? [String] { result.roots = roots }
        result.renamed += renamedBeforeRestart
        if !error.isEmpty { result.title = "오류 확인 필요"; result.detail = error }
        else if !paused, let child = process, !child.isRunning {
            result.detail = "감시기가 종료됐습니다. 다시 시작을 눌러 주세요. (\(child.terminationStatus))"
        }
        return result
    }

    func stop() {
        if let child = process {
            let state = status()
            if (state["pid"] as? NSNumber)?.int32Value == child.processIdentifier {
                renamedBeforeRestart += state["renamedThisRun"] as? Int ?? 0
            }
            if child.isRunning {
                child.terminate()
                let timeout = DispatchWorkItem { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                child.waitUntilExit()
                timeout.cancel()
            }
        }
        process = nil
        try? output?.close()
        output = nil
    }

    private func savePause(_ value: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["paused": value])
        try data.write(to: URL(fileURLWithPath: directory + "/menu.json"), options: .atomic)
        paused = value
    }

    func togglePause() throws {
        try ensureOwnership()
        if paused { try savePause(false); try launch() }
        else { stop(); try savePause(true) }
    }

    func restart() throws {
        try ensureOwnership()
        stop()
        try savePause(false)
        try launch()
    }

    func changeRoots(adding: [String] = [], removing: String? = nil) throws {
        try ensureOwnership()
        let config = try loadConfiguration()
        // For existing users, capture all discovered Desktop/Dropbox roots before switching to an explicit list.
        var roots = config.roots ?? discoverRoots(config)
        if let removing { roots.removeAll { $0 == removing } }
        for path in adding {
            let canonical = physicalPath(path)
            guard let info = try? metadata(canonical), info.directory else {
                throw NSError(domain: "NameGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "폴더를 찾을 수 없습니다: \(path)"])
            }
            if !roots.contains(canonical) { roots.append(canonical) }
        }
        // Stop AND reap the old worker before saving: no queued rename can run in a removed root after success.
        stop()
        do { try configuration.setRoots(roots) }
        catch { if !paused { try? launch() }; throw error }
        if !paused { try launch() }
    }

    func report(_ failure: Error) { error = failure.localizedDescription }

    deinit {
        if lockFD >= 0 { close(lockFD) }
    }
}
