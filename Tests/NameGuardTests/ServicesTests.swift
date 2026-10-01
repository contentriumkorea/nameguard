import XCTest
@testable import NameGuardMenu

final class ServicesTests: XCTestCase {
    func testInstalledBundleUsesSameSettingsWhenOpenedDirectly() {
        XCTAssertEqual(AppLocation.defaultDirectory(executable: "/Users/a/Applications/NameGuard Desktop.app/Contents/MacOS/nameguard", home: "/Users/a"), "/Users/a/Library/Application Support/NameGuardDesktop")
        XCTAssertEqual(AppLocation.defaultDirectory(executable: "/Users/a/Applications/NameGuard.app/Contents/MacOS/nameguard", home: "/Users/a"), "/Users/a/Library/Application Support/NameGuard")
    }
    func testNumericVersionsAndInvalidReleases() throws {
        XCTAssertTrue(try UpdateRelease.isNewer("1.10.0", than: "1.2"))
        XCTAssertFalse(try UpdateRelease.isNewer("1.1.0", than: "1.2.0"))
        XCTAssertThrowsError(try UpdateRelease.isNewer("1.3-beta", than: "1.2"))
        let valid: [String: Any] = ["tag_name": "v1.3.0", "html_url": "https://github.com/contentriumkorea/nameguard/releases/tag/v1.3.0", "draft": false, "prerelease": false,
            "assets": [["name": "NameGuard.zip", "browser_download_url": "https://github.com/contentriumkorea/nameguard/releases/download/v1.3.0/NameGuard.zip", "size": 123, "digest": "sha256:" + String(repeating: "a", count: 64)]]]
        let release = try UpdateRelease.parse(JSONSerialization.data(withJSONObject: valid))
        XCTAssertEqual(release.version, "1.3.0")
        var bad = valid; bad["prerelease"] = true
        XCTAssertThrowsError(try UpdateRelease.parse(JSONSerialization.data(withJSONObject: bad)))
        bad = valid; bad["assets"] = [["name": "NameGuard.zip", "browser_download_url": "https://example.com/evil.zip", "size": 123, "digest": "sha256:" + String(repeating: "a", count: 64)]]
        XCTAssertThrowsError(try UpdateRelease.parse(JSONSerialization.data(withJSONObject: bad)))
        bad = valid; bad["assets"] = [["name": "NameGuard.zip", "browser_download_url": release.url.absoluteString, "size": 123]]
        XCTAssertThrowsError(try UpdateRelease.parse(JSONSerialization.data(withJSONObject: bad)))
    }
    func testArchiveTraversalAndCorruptedDownloadsAreRejected() throws {
        XCTAssertNoThrow(try UpdateService.validateEntries(["NameGuard-Desktop/NameGuard Desktop.app/Contents/Info.plist"]))
        for entry in ["/tmp/evil", "NameGuard-Desktop/../../evil", "NameGuard-Desktop/evil\\file", "Other.app/file"] {
            XCTAssertThrowsError(try UpdateService.validateEntries([entry]))
        }
        let release = UpdateRelease(version: "1.3.0", url: URL(string: "https://example.com")!, size: 3, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try UpdateService.validateDownload(Data("abc".utf8), release: release))
    }
    func testLoginPreferenceKeepsConfigAndPauseUntouched() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = base.appendingPathComponent("config.json"), pause = base.appendingPathComponent("menu.json")
        try Data("folders untouched".utf8).write(to: config)
        try Data("{\"paused\":true}".utf8).write(to: pause)
        let login = LoginStartup(executable: "/tmp/example/NameGuard Desktop.app/Contents/MacOS/nameguard", directory: base.path, home: base.path, run: { _, _ in "" })
        try login.setEnabled(true)
        XCTAssertTrue(login.isEnabled)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: login.agentURL), format: nil) as! [String: Any]
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [login.executable, "--menu", "--state-dir", base.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        try login.setEnabled(false)
        XCTAssertFalse(login.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: login.agentURL.path))
        XCTAssertEqual(try Data(contentsOf: config), Data("folders untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: pause), Data("{\"paused\":true}".utf8))
    }
}
