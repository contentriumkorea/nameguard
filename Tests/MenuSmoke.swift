import Foundation

@main struct MenuSmoke {
    static func main() throws {
        let now = Date()
        let live: [String: Any] = ["pid": 42, "updated": ISO8601DateFormatter().string(from: now),
            "roots": ["/tmp/root"], "pending": 2, "renamedThisRun": 3,
            "scanDirectoriesRemaining": 0, "scanRetriesRemaining": 0, "paused": ""]
        precondition(MenuSnapshot(status: live, runningPID: nil, paused: false, now: now).title == "감시 중단")
        precondition(MenuSnapshot(status: live, runningPID: 99, paused: false, now: now).title == "시작 중")
        precondition(MenuSnapshot(status: live, runningPID: 42, paused: false, now: now).title == "감시 중")
        precondition(MenuSnapshot(status: live, runningPID: 42, paused: true, now: now).title == "일시중지")
        precondition(MenuSnapshot(status: live, runningPID: 42, paused: false, now: now.addingTimeInterval(60)).title == "응답 확인 필요")
        var state = live
        state["scanDirectoriesRemaining"] = 1
        precondition(MenuSnapshot(status: state, runningPID: 42, paused: false, now: now).title == "검사 중")
        state["paused"] = "열린 파일 사용 중"
        precondition(MenuSnapshot(status: state, runningPID: 42, paused: false, now: now).title == "변경 보류")
        state["paused"] = ""
        state["scanRetriesRemaining"] = 1
        precondition(MenuSnapshot(status: state, runningPID: 42, paused: false, now: now).title == "오류 확인 필요")
        state["scanRetriesRemaining"] = 0
        state["roots"] = [String]()
        precondition(MenuSnapshot(status: state, runningPID: 42, paused: false, now: now).title == "폴더를 선택해 주세요")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let configURL = base.appendingPathComponent("config.json")
        let original: [String: Any] = ["quietSeconds": 17, "excludedPaths": ["/keep"], "futureOption": true]
        try JSONSerialization.data(withJSONObject: original).write(to: configURL)
        let store = MenuConfiguration(url: configURL)
        try store.setRoots(["/new", "/new", "/other"])
        let saved = try store.read()
        precondition(saved["quietSeconds"] as? Int == 17)
        precondition(saved["excludedPaths"] as? [String] == ["/keep"])
        precondition(saved["futureOption"] as? Bool == true)
        precondition(saved["roots"] as? [String] == ["/new", "/other"])
        try store.setRoots([])
        let emptyRoots = try store.read()["roots"] as? [String]
        precondition(emptyRoots == [])
        let before = try Data(contentsOf: configURL)
        do { try store.setRoots(["relative/path"]); fatalError("Relative roots accepted") } catch {}
        let afterRejectedPath = try Data(contentsOf: configURL)
        precondition(afterRejectedPath == before)
        try Data("broken".utf8).write(to: configURL)
        do { try store.setRoots(["/new"]); fatalError("Corrupt settings overwritten") } catch {}
        let afterCorrupt = try Data(contentsOf: configURL)
        precondition(afterCorrupt == Data("broken".utf8))
        print("PASS: live-process status, stale heartbeat, pause, scan, errors, settings preservation and validation")
    }
}
