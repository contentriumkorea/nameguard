import Foundation
import CryptoKit

@main struct UpdateDownloadSmoke {
    static func main() async throws {
        let fm = FileManager.default
        let zip = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let serverURL = URL(string: CommandLine.arguments[2])!
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let bundle = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/NameGuard Verify \(UUID().uuidString).app")
        try fm.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base); try? fm.removeItem(at: bundle) }
        let unpacked = base.appendingPathComponent("original")
        try runCommand("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        try fm.copyItem(at: unpacked.appendingPathComponent("NameGuard-Desktop/NameGuard Desktop.app"), to: bundle)
        try runCommand("/usr/bin/plutil", ["-replace", "CFBundleShortVersionString", "-string", "1.0.0", bundle.appendingPathComponent("Contents/Info.plist").path])
        try runCommand("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        let updater = UpdateService(directory: base.appendingPathComponent("state").path, bundle: bundle)
        let live = try await updater.check()
        precondition(live != nil && (try! UpdateRelease.isNewer(live!.version, than: "1.0.0")), "Live public GitHub version must be detected")
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let release = UpdateRelease(version: "1.2.0", url: serverURL, size: data.count, sha256: digest)
        let staged = try await updater.prepare(release)
        defer { try? fm.removeItem(at: staged.candidate) }
        precondition(fm.fileExists(atPath: staged.candidate.appendingPathComponent("Contents/Resources/update.sh").path))
        precondition(updater.version == "1.0.0", "Download and staging must not replace the running app")
        let corrupt = UpdateRelease(version: "1.2.0", url: serverURL, size: data.count, sha256: String(repeating: "0", count: 64))
        do { _ = try await updater.prepare(corrupt); fatalError("Corrupt download accepted") }
        catch { precondition(error.localizedDescription.contains("검증")) }
        precondition(updater.version == "1.0.0")
        print("PASS: live public GitHub detection; real URLSession ZIP download, SHA256, archive/app/signature validation and staging; corrupt download rejected without replacing app")
    }
}
