import XCTest
import Foundation
import Darwin
@testable import NameGuard

final class NormalizationTests: XCTestCase {
    var root: String = ""
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }
    func testKoreanOnlyAndByteComparison() {
        XCTAssertEqual(normalizedName("한글.txt".decomposedStringWithCanonicalMapping), "한글.txt")
        XCTAssertNil(normalizedName("한글.txt"))
        XCTAssertNil(normalizedName("hello.txt"))
        XCTAssertNil(normalizedName("e\u{301}.txt"))
        XCTAssertNil(normalizedName("ㅎㅏㄴ.txt"))
    }
    func testActualAPFSRenamePreservesContentAndInode() throws {
        let old = "한글.txt".decomposedStringWithCanonicalMapping
        let path = root + "/" + old
        try Data("unchanged".utf8).write(to: URL(fileURLWithPath: path))
        let before = try metadata(path)
        XCTAssertEqual(try normalizeItem(path), .renamed)
        let names = try FileManager.default.contentsOfDirectory(atPath: root)
        XCTAssertEqual(Array(names[0].utf8), Array("한글.txt".utf8))
        XCTAssertEqual(try metadata(root + "/한글.txt").inode, before.inode)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/한글.txt")), Data("unchanged".utf8))
        XCTAssertEqual(try normalizeItem(root + "/한글.txt"), .unchanged)
    }
    func testFolderAndSymlink() throws {
        let folder = root + "/" + "폴더".decomposedStringWithCanonicalMapping
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        try Data([1,2,3]).write(to: URL(fileURLWithPath: folder + "/asset"))
        XCTAssertEqual(try normalizeItem(folder), .renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/폴더/asset"))
        let link = root + "/" + "링크".decomposedStringWithCanonicalMapping
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root + "/폴더")
        XCTAssertEqual(try normalizeItem(link), .skipped)
    }
    func testOpenDescendantBlocksFolderButNotSibling() {
        XCTAssertTrue(isOpen("/tmp/폴더", openPaths: ["/tmp/폴더/movie.mov"]))
        XCTAssertFalse(isOpen("/tmp/폴더", openPaths: ["/tmp/폴더2/movie.mov"]))
        XCTAssertTrue(isOpen("/tmp/한글", openPaths: ["/tmp/한글".decomposedStringWithCanonicalMapping]))
    }
    func testExcludedPackageAndHiddenComponents() {
        XCTAssertTrue(excluded("/tmp/root/A.app/한글", root: "/tmp/root"))
        XCTAssertTrue(excluded("/tmp/root/.git/한글", root: "/tmp/root"))
        XCTAssertFalse(excluded("/tmp/root/폴더/한글.mov", root: "/tmp/root"))
    }
}
