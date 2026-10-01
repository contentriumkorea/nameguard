import Foundation
import CryptoKit
import Darwin

struct UpdateRelease {
    let version: String
    let url: URL
    let size: Int
    let sha256: String
    static let repository = "https://github.com/contentriumkorea/nameguard/releases"

    private static func numbers(_ value: String) throws -> [Int] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ Int($0) != nil }) else { throw serviceError("버전 정보를 확인할 수 없습니다.") }
        return parts.map { Int($0)! } + (parts.count == 2 ? [0] : [])
    }
    static func isNewer(_ candidate: String, than current: String) throws -> Bool {
        let a = try numbers(candidate), b = try numbers(current)
        for index in 0..<3 where a[index] != b[index] { return a[index] > b[index] }
        return false
    }
    static func parse(_ data: Data) throws -> UpdateRelease {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["draft"] as? Bool == false, value["prerelease"] as? Bool == false,
              let tag = value["tag_name"] as? String, tag.hasPrefix("v"),
              value["html_url"] as? String == repository + "/tag/" + tag,
              let assets = value["assets"] as? [[String: Any]] else { throw serviceError("새 버전 정보를 확인할 수 없습니다.") }
        let version = String(tag.dropFirst()); _ = try numbers(version)
        guard let asset = assets.first(where: { $0["name"] as? String == "NameGuard.zip" }),
              asset["browser_download_url"] as? String == repository + "/download/" + tag + "/NameGuard.zip",
              let url = URL(string: repository + "/download/" + tag + "/NameGuard.zip"),
              let size = asset["size"] as? Int, size > 0, size <= 64 * 1024 * 1024,
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw serviceError("검증 가능한 업데이트 파일이 없습니다. 잠시 후 다시 시도해 주세요.")
        }
        return UpdateRelease(version: version, url: url, size: size, sha256: String(digest.dropFirst(7)))
    }
}

final class UpdateService {
    let directory: String
    let bundle: URL
    init(directory: String, bundle: URL) { self.directory = directory; self.bundle = bundle }
    var version: String { Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0" }

    func check() async throws -> UpdateRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/contentriumkorea/nameguard/releases/latest")!)
        request.timeoutInterval = 20; request.setValue("NameGuard", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw serviceError("새 버전을 확인하지 못했습니다. 인터넷 연결을 확인해 주세요.") }
        let release = try UpdateRelease.parse(data)
        return try UpdateRelease.isNewer(release.version, than: version) ? release : nil
    }
    static func validateDownload(_ data: Data, release: UpdateRelease) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.size, hash == release.sha256 else { throw serviceError("다운로드한 파일 검증에 실패했습니다. 기존 앱은 유지됩니다.") }
    }
    static func validateEntries(_ entries: [String]) throws {
        guard !entries.isEmpty else { throw serviceError("압축 파일이 비어 있습니다.") }
        for entry in entries {
            guard (entry.hasPrefix("NameGuard-Desktop/") || entry.hasPrefix("__MACOSX/")),
                  !entry.contains("\\"), !entry.split(separator: "/").contains("..") else { throw serviceError("잘못된 업데이트 압축 파일입니다.") }
        }
    }
    func prepare(_ release: UpdateRelease) async throws -> (workspace: URL, candidate: URL, token: String) {
        let fm = FileManager.default
        let realBundle = bundle.resolvingSymlinksInPath()
        guard realBundle.path == bundle.path, !bundle.path.contains("/AppTranslocation/"), !bundle.path.hasPrefix("/Volumes/"),
              bundle.deletingLastPathComponent().path == fm.homeDirectoryForCurrentUser.path + "/Applications",
              fm.isWritableFile(atPath: bundle.path), fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            throw serviceError("먼저 설치.command로 사용자 응용프로그램 폴더에 설치해 주세요.")
        }
        let token = UUID().uuidString.lowercased()
        let workspace = URL(fileURLWithPath: directory).appendingPathComponent("updates/" + token)
        let candidate = URL(fileURLWithPath: bundle.path + ".nameguard-update-" + token + ".app")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var request = URLRequest(url: release.url); request.timeoutInterval = 120
            let (download, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw serviceError("업데이트를 내려받지 못했습니다.") }
            defer { try? fm.removeItem(at: download) }
            let attributes = try fm.attributesOfItem(atPath: download.path)
            guard attributes[.size] as? Int == release.size else { throw serviceError("업데이트 파일 크기가 다릅니다.") }
            let data = try Data(contentsOf: download); try Self.validateDownload(data, release: release)
            let zip = workspace.appendingPathComponent("update.zip"); try data.write(to: zip)
            let entries = try runCommand("/usr/bin/unzip", ["-Z1", zip.path]).split(separator: "\n").map(String.init)
            try Self.validateEntries(entries)
            let unpacked = workspace.appendingPathComponent("unpacked")
            try runCommand("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let enumerator = fm.enumerator(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw serviceError("앱 압축을 풀지 못했습니다.") }
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw serviceError("업데이트에 잘못된 링크가 있습니다.") }
            }
            let app = unpacked.appendingPathComponent("NameGuard-Desktop/NameGuard Desktop.app")
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == "local.nameguard.desktop.app",
                  info?["CFBundleExecutable"] as? String == "nameguard", info?["CFBundleShortVersionString"] as? String == release.version else { throw serviceError("업데이트 앱의 버전이 다릅니다.") }
            try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            try fm.copyItem(at: app, to: candidate)
            if Bundle(url: bundle)?.bundleIdentifier == "local.nameguard.app" {
                try runCommand("/usr/bin/plutil", ["-replace", "CFBundleIdentifier", "-string", "local.nameguard.app", candidate.appendingPathComponent("Contents/Info.plist").path])
                try runCommand("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.nameguard.app", candidate.path])
            }
            try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
            return (workspace, candidate, token)
        } catch {
            try? fm.removeItem(at: candidate); try? fm.removeItem(at: workspace); throw error
        }
    }
    func install(_ staged: (workspace: URL, candidate: URL, token: String), version: String) throws {
        let source = bundle.appendingPathComponent("Contents/Resources/update.sh")
        let helper = staged.workspace.appendingPathComponent("install.sh")
        try Data(contentsOf: source).write(to: helper, options: .atomic)
        let log = staged.workspace.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [helper.path, String(getpid()), bundle.path, staged.candidate.path, staged.workspace.path, staged.token, version, directory, "300"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = output
        try child.run()
    }
}
