import Foundation
import Darwin
@main struct Smoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("한글.txt".decomposedStringWithCanonicalMapping)
        try Data("unchanged".utf8).write(to: old)
        let info = try metadata(old.path)
        let renamed = try normalizeItem(old.path)
        precondition(renamed == .renamed)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let policyBefore = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = try directoryNames(root.path)
        precondition(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == policyBefore)
        precondition(names.contains { Array($0.utf8) == Array("한글.txt".utf8) })
        let after = try metadata(root.path + "/한글.txt")
        let contents = try Data(contentsOf: root.appendingPathComponent("한글.txt"))
        precondition(after.inode == info.inode)
        precondition(contents == Data("unchanged".utf8))
        precondition(normalizedName("한글.txt") == nil)
        precondition(normalizedName("ascii.txt") == nil)
        precondition(normalizedName("e\u{301}.txt") == nil)
        precondition(normalizedName("ㅎㅏㄴ.txt") == nil)
        precondition(normalizedName("한글.txt".decomposedStringWithCanonicalMapping) != nil)
        precondition(isOpen("/not-existing/폴더", openPaths: ["/not-existing/폴더/asset"]))
        precondition(!isOpen("/not-existing/폴더", openPaths: ["/not-existing/폴더2/asset"]))
        precondition(excluded("/root/A.app/한글", root: "/root"))
        precondition(excluded("/root/.git/한글", root: "/root"))
        precondition(!excluded("/root/A/한글", root: "/root"))
        let link = root.path + "/" + "링크".decomposedStringWithCanonicalMapping
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: old.path)
        let skipped = try normalizeItem(link)
        precondition(skipped == .skipped)
        print("PASS: Unicode byte checks, real APFS rename, content/inode preservation, exclusions, symlink, open descendants")
    }
}
