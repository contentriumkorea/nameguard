import Foundation

struct MenuSnapshot {
    var title: String
    var detail: String = ""
    var roots: [String] = []
    var renamed: Int = 0
    var pending: Int = 0
    var paused: Bool

    init(status: [String: Any], runningPID: Int32?, paused: Bool, now: Date = Date()) {
        self.paused = paused
        roots = status["roots"] as? [String] ?? []
        if paused { title = "일시중지"; return }
        guard let pid = runningPID else { title = "감시 중단"; return }
        guard (status["pid"] as? NSNumber)?.int32Value == pid else { title = "시작 중"; return }
        guard let updated = status["updated"] as? String,
              let date = ISO8601DateFormatter().date(from: updated),
              (-5...15).contains(now.timeIntervalSince(date)) else {
            title = "응답 확인 필요"; detail = "감시기의 상태 기록이 갱신되지 않았습니다."; return
        }
        renamed = status["renamedThisRun"] as? Int ?? 0
        pending = status["pending"] as? Int ?? 0
        let reason = status["paused"] as? String ?? ""
        if !reason.isEmpty { title = "변경 보류"; detail = reason }
        else if (status["scanRetriesRemaining"] as? Int ?? 0) > 0 || (status["pendingErrors"] as? Int ?? 0) > 0 {
            title = "오류 확인 필요"; detail = "다시 시도할 항목이 있습니다. 로그를 확인해 주세요."
        }
        else if roots.isEmpty { title = "폴더를 선택해 주세요" }
        else if (status["scanDirectoriesRemaining"] as? Int ?? 0) > 0 { title = "검사 중" }
        else { title = "감시 중" }
    }
}

struct MenuConfiguration {
    let url: URL

    func read() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NameGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "설정 파일 형식이 잘못되었습니다."])
        }
        return object
    }

    func setRoots(_ roots: [String]) throws {
        guard roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw NSError(domain: "NameGuard", code: 2, userInfo: [NSLocalizedDescriptionKey: "감시 폴더는 절대 경로여야 합니다."])
        }
        var object = try read() // Preserve delays, exclusions, app protections and future keys.
        var unique: [String] = []
        for path in roots where !unique.contains(path) { unique.append(path) }
        object["roots"] = unique
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }
}
