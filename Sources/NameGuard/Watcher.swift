import Foundation
import AppKit
import CoreServices
import Darwin

public struct Configuration: Codable {
    public var roots: [String]? = nil
    public var quietSeconds: Double = 10
    public var directoryQuietSeconds: Double = 30
    public var excludedPaths: [String] = []
    public var protectedApps: [String] = ["Adobe Premiere", "After Effects", "Adobe Media Encoder", "DaVinci Resolve", "Final Cut", "Logic Pro", "Adobe Photoshop", "Adobe Illustrator", "Adobe InDesign", "Lightroom"]
    public init() {}
    enum CodingKeys: String, CodingKey {
        case roots, quietSeconds, directoryQuietSeconds, excludedPaths, protectedApps
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent([String].self, forKey: .roots)
        quietSeconds = try values.decodeIfPresent(Double.self, forKey: .quietSeconds) ?? quietSeconds
        directoryQuietSeconds = try values.decodeIfPresent(Double.self, forKey: .directoryQuietSeconds) ?? directoryQuietSeconds
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? excludedPaths
        protectedApps = try values.decodeIfPresent([String].self, forKey: .protectedApps) ?? protectedApps
    }
}

public func discoverRoots(_ config: Configuration) -> [String] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var candidates = config.roots ?? [home + "/Desktop", home + "/Dropbox"]
    if config.roots == nil {
        let cloud = home + "/Library/CloudStorage"
        if let names = try? fm.contentsOfDirectory(atPath: cloud) {
            candidates += names.filter { $0 == "Dropbox" || $0.hasPrefix("Dropbox-") || $0.hasPrefix("Dropbox (") }.map { cloud + "/" + $0 }
        }
        // Dropbox's local account metadata also covers custom and legacy locations.
        if let data = fm.contents(atPath: home + "/.dropbox/info.json"),
           let accounts = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] {
            candidates += accounts.values.compactMap { $0["path"] as? String }
        }
    }
    var result: [String] = []
    for path in candidates {
        let real = physicalPath((path as NSString).expandingTildeInPath)
        guard let info = try? metadata(real), info.directory else { continue }
        if !result.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
            result.removeAll { $0.hasPrefix(real + "/") }
            result.append(real)
        }
    }
    return result.sorted()
}

public final class Logger {
    let path: String
    public init(directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = directory + "/events.jsonl"
    }
    public func write(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["time"] = ISO8601DateFormatter().string(from: Date())
        object["event"] = event
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(10)
        let fm = FileManager.default
        if ((try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) > 5_000_000 {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { fputs("NameGuard log write failed: \(error)\n", stderr) }
        }
    }
}

// Limit lsof runtime. Read through a pipe concurrently so large output cannot deadlock.
public func openFilePaths() throws -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-n", "-P", "-F0n", "-u", String(getuid())]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else { throw POSIXError(.EBUSY) }
    let names: [String] = data.split(separator: 0).compactMap { field in
        // Each process/file record may start with a newline; names may contain newlines.
        var bytes = field
        if bytes.first == 10 { bytes = bytes.dropFirst() }
        guard bytes.first == 110 else { return nil }
        let name = String(decoding: bytes.dropFirst(), as: UTF8.self)
        return name.hasPrefix("/") ? name : nil
    }
    return Array(Set(names)).map { physicalPath($0).precomposedStringWithCanonicalMapping }
}

struct Pending {
    var info: Metadata
    var due: Date
    var eventPriority: Bool
}

public final class Watcher {
    let config: Configuration
    let directory: String
    let log: Logger
    let auditOnly: Bool
    var roots: [String] = []
    var streams: [FSEventStreamRef] = []
    var pending: [String: Pending] = [:]
    var scans: Set<String> = []
    var failedScans: [String: Date] = [:]
    var scansInFlight: Set<String> = []
    let scanQueue = DispatchQueue(label: "local.nameguard.directory-scan", qos: .utility, attributes: .concurrent)
    var timer: DispatchSourceTimer?
    var lastDiscovery = Date.distantPast
    var lastStatus = Date.distantPast
    var pauseReason = ""
    var renamed = 0
    var failures = 0
    var pendingErrors: Set<String> = []
    var auditCandidates = 0
    var history: [String: [Double]] = [:]
    var lockFD: Int32 = -1

    public init(config: Configuration, directory: String, auditOnly: Bool = false) throws {
        self.config = config; self.directory = directory; self.auditOnly = auditOnly
        log = try Logger(directory: directory)
        if let data = FileManager.default.contents(atPath: directory + "/history.json"),
           let saved = try? JSONDecoder().decode([String: [Double]].self, from: data) { history = saved }
    }

    func allowed(_ path: String) -> Bool {
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }), !excluded(path, root: root) else { return false }
        if config.excludedPaths.contains(where: {
            let p = ($0 as NSString).expandingTildeInPath
            return path == p || path.hasPrefix(p + "/")
        }) { return false }
        // Do not traverse symlinks or rename through an ancestor that became one.
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor != root {
            guard ancestor.hasPrefix(root + "/"), let m = try? metadata(ancestor), m.directory, !m.symlink else { return false }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return true
    }

    func enqueue(_ path: String, eventPriority: Bool = false) {
        guard allowed(path), let info = try? metadata(path), !info.symlink else { return }
        if normalizedName((path as NSString).lastPathComponent) != nil {
            if auditOnly { auditCandidates += 1; return }
            pending[path] = Pending(info: info, due: Date().addingTimeInterval(info.directory ? config.directoryQuietSeconds : config.quietSeconds), eventPriority: eventPriority || (pending[path]?.eventPriority ?? false))
        }
        // Descendant writes postpone a parent's rename too.
        var parent = (path as NSString).deletingLastPathComponent
        while roots.contains(where: { parent.hasPrefix($0 + "/") }) {
            if var item = pending[parent] {
                item.due = Date().addingTimeInterval(config.directoryQuietSeconds)
                pending[parent] = item
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    func scan(_ path: String) {
        guard roots.contains(path) || allowed(path), let info = try? metadata(path), !info.symlink else { return }
        if !roots.contains(path) { enqueue(path) }
        guard info.directory else { return }
        if auditOnly {
            finishScan(path, result: Result { try directoryNames(path) })
        } else {
            guard !scansInFlight.contains(path) else { return }
            scansInFlight.insert(path)
            scanQueue.async { [weak self] in
                let result = Result { try directoryNames(path) }
                DispatchQueue.main.async {
                    self?.scansInFlight.remove(path)
                    self?.finishScan(path, result: result)
                }
            }
        }
    }

    func finishScan(_ path: String, result: Result<[String], Error>) {
        do {
            for name in try result.get() {
                let child = path + "/" + name
                guard allowed(child) else { continue }
                enqueue(child)
                if let childInfo = try? metadata(child), childInfo.directory, !childInfo.symlink { scans.insert(child) }
            }
            failedScans.removeValue(forKey: path)
        } catch {
            failures += 1
            failedScans[path] = Date().addingTimeInterval(300)
            log.write("scan_error", ["path": path, "error": "\(error)"])
        }
        if !auditOnly { pumpScans() }
    }

    func pumpScans() {
        for _ in 0..<2 {
            guard scansInFlight.count < 2, let path = scans.first else { break }
            scans.remove(path)
            scan(path)
        }
    }

    // Events may spell an entry differently from the bytes persisted on disk.
    func actualEntry(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        do {
            return try directoryNames(parent).first(where: { $0 == name }).map { parent + "/" + $0 }
        } catch {
            failedScans[parent] = Date().addingTimeInterval(300)
            return nil
        }
    }

    func event(_ path: String, flags: FSEventStreamEventFlags) {
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if flags & recovery != 0 {
            for root in roots {
                if path == root || root.hasPrefix(path + "/") { scans.insert(root) }
                else if path.hasPrefix(root + "/") { scans.insert(path) }
            }
            log.write("event_recovery", ["path": path, "flags": flags])
        }
        guard allowed(path), let actual = actualEntry(path) else { return }
        enqueue(actual, eventPriority: true)
        let newDirectory = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 && flags & newDirectory != 0 {
            scans.insert(actual)
        }
    }

    func refreshRoots() throws {
        let discovered = discoverRoots(config)
        guard discovered != roots || streams.isEmpty else { return }
        let previous = roots
        roots = discovered
        for stream in streams { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        streams = []
        var watched = roots
        let cloud = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/CloudStorage"
        if config.roots == nil && FileManager.default.fileExists(atPath: cloud) { watched.append(cloud) }
        if !watched.isEmpty {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, context, count, paths, flags, _ in
                guard let context else { return }
                let watcher = Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue()
                let entries = unsafeBitCast(paths, to: NSArray.self) as! [String]
                for i in 0..<count { watcher.event(entries[i], flags: flags[i]) }
            }
            let options = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf)
            guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, options) else { throw POSIXError(.EIO) }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); throw POSIXError(.EIO) }
            streams.append(stream)
        }
        // Subscribe first, then inspect existing entries to avoid an installation-time gap.
        for root in roots where !previous.contains(root) { scans.insert(root) }
        log.write("watching", ["roots": roots])
    }

    func writeStatus() {
        let object: [String: Any] = ["updated": ISO8601DateFormatter().string(from: Date()), "pid": getpid(),
            "roots": roots, "pending": pending.count, "renamedThisRun": renamed,
            "errorsThisRun": failures, "scanDirectoriesRemaining": scans.count + scansInFlight.count,
            "scanRetriesRemaining": failedScans.count, "paused": pauseReason, "mode": "watch"]
            .merging(["pendingErrors": pendingErrors.count]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: directory + "/status.json"), options: .atomic)
        }
    }

    func pause(_ reason: String) {
        if pauseReason != reason { pauseReason = reason; log.write("pause", ["reason": reason]); writeStatus() }
    }

    func tick() {
        let now = Date()
        for (path, due) in failedScans where due <= now { scans.insert(path) }
        failedScans = failedScans.filter { $0.value > now }
        if now.timeIntervalSince(lastDiscovery) >= 60 {
            lastDiscovery = now
            do { try refreshRoots() } catch { failures += 1; log.write("watch_error", ["error": "\(error)"]) }
        }
        pumpScans()
        if now.timeIntervalSince(lastStatus) >= 2 { lastStatus = now; writeStatus() }
        let due = pending.filter { $0.value.due <= now }.sorted {
            if $0.value.eventPriority != $1.value.eventPriority { return $0.value.eventPriority }
            if $0.value.due != $1.value.due { return $0.value.due < $1.value.due }
            return $0.key.count > $1.key.count
        }.map(\.key)
        guard !due.isEmpty else { if pending.isEmpty { pause("") }; return }
        let busy = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter { name in
            config.protectedApps.contains { name.localizedCaseInsensitiveContains($0) }
        }
        guard busy.isEmpty else { pause("편집 프로그램 실행 중: " + busy.joined(separator: ", ")); return }
        let opened: [String]
        do { opened = try openFilePaths() }
        catch { pause("열린 파일 확인 실패: \(error)"); return }
        pause("")
        var historyChanged = false
        var deferred = false
        var cooldown = false
        for key in due.prefix(100) {
            guard let item = pending[key] else { continue }
            guard allowed(key), let path = actualEntry(key), let current = try? metadata(path) else { pending.removeValue(forKey: key); pendingErrors.remove(key); continue }
            guard normalizedName((path as NSString).lastPathComponent) != nil else { pending.removeValue(forKey: key); pendingErrors.remove(key); continue }
            guard current == item.info else { pending.removeValue(forKey: key); enqueue(path); continue }
            if isOpen(path, openPaths: opened) { pending[key]?.due = now.addingTimeInterval(30); deferred = true; continue }
            let identity = "\(current.device):\(current.inode)"
            let recent = (history[identity] ?? []).filter { now.timeIntervalSince1970 - $0 < 3600 }
            if recent.count >= 3 {
                pending[key]?.due = Date(timeIntervalSince1970: recent[0] + 3601)
                cooldown = true
                log.write("cooldown", ["path": path, "reason": "same inode normalized 3 times/hour; possible sync loop"])
                continue
            }
            do {
                // Recheck metadata immediately before the non-overwriting operation.
                guard try metadata(path) == current else { enqueue(path); continue }
                let result = try normalizeItem(path)
                pending.removeValue(forKey: key)
                pendingErrors.remove(key)
                if result == .renamed {
                    renamed += 1
                    history[identity] = recent + [now.timeIntervalSince1970]
                    historyChanged = true
                    log.write("renamed", ["from": path, "to": (path as NSString).deletingLastPathComponent + "/" + (normalizedName((path as NSString).lastPathComponent) ?? ""), "inode": current.inode])
                }
            } catch {
                failures += 1
                pendingErrors.insert(key)
                pending[key]?.due = now.addingTimeInterval(300)
                log.write("rename_error", ["path": path, "error": "\(error)"])
            }
        }
        if historyChanged {
            history = history.filter { $0.value.contains { now.timeIntervalSince1970 - $0 < 3600 } }
            if let data = try? JSONEncoder().encode(history) { try? data.write(to: URL(fileURLWithPath: directory + "/history.json"), options: .atomic) }
        }
        if deferred { pause("열린 파일 사용 중") }
        else if cooldown { pause("동기화 반복 감지 · 잠시 보류") }
        writeStatus()
    }

    public func audit() -> Int {
        roots = discoverRoots(config)
        scans.formUnion(roots)
        while let path = scans.first { scans.remove(path); scan(path) }
        print("Roots: \(roots.joined(separator: ", "))\nNFD Korean candidates: \(auditCandidates)\nScan errors: \(failures)")
        return failures
    }

    public func run(parentPID: Int32? = nil) throws {
        lockFD = open(directory + "/daemon.lock", O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        try refreshRoots()
        log.write("started", ["pid": getpid()])
        writeStatus()
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer?.schedule(deadline: .now(), repeating: 2)
        timer?.setEventHandler { [weak self] in
            if let parentPID, getppid() != parentPID { exit(0) }
            self?.tick()
        }
        timer?.resume()
        RunLoop.main.run()
    }
}
