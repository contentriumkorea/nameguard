import Foundation
import Darwin

public func physicalPath(_ path: String) -> String {
    guard let pointer = realpath(path, nil) else { return path }
    defer { free(pointer) }
    return String(cString: pointer)
}

public func directoryNames(_ path: String) throws -> [String] {
    // Background jobs may disallow fetching cloud directory listings.
    // Opt in only around directory listing, never regular file content reads.
    let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    guard previous >= 0,
          setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
    return try FileManager.default.contentsOfDirectory(atPath: path)
}

public func normalizedName(_ name: String) -> String? {
    guard name.unicodeScalars.contains(where: { (0x1100...0x11FF).contains($0.value) }) else { return nil }
    let result = name.precomposedStringWithCanonicalMapping
    return Array(name.utf8) == Array(result.utf8) ? nil : result
}

public struct Metadata: Equatable {
    public let inode: UInt64
    public let device: Int32
    public let size: Int64
    public let modified: Int64
    public let nanoseconds: Int64
    public let mode: UInt16
    public var directory: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) }
    public var symlink: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK) }
}
public func metadata(_ path: String) throws -> Metadata {
    var s = stat()
    guard lstat(path, &s) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return Metadata(inode: s.st_ino, device: s.st_dev, size: s.st_size,
                    modified: Int64(s.st_mtimespec.tv_sec), nanoseconds: Int64(s.st_mtimespec.tv_nsec), mode: s.st_mode)
}

public enum RenameResult: String { case renamed, unchanged, skipped }
public func normalizeItem(_ path: String) throws -> RenameResult {
    let before = try metadata(path)
    guard !before.symlink else { return .skipped }
    let name = (path as NSString).lastPathComponent
    guard let normalized = normalizedName(name) else { return .unchanged }
    let parent = (path as NSString).deletingLastPathComponent
    let destination = parent + "/" + normalized
    // APFS treats NFC/NFD as the same lookup. Never overwrite another inode.
    if let existing = try? metadata(destination), (existing.inode != before.inode || existing.device != before.device) {
        throw POSIXError(.EEXIST)
    }
    guard renamex_np(path, destination, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // Check the actual directory entry bytes; Swift String == is normalization-insensitive.
    let names = try directoryNames(parent)
    guard names.contains(where: { Array($0.utf8) == Array(normalized.utf8) }) else {
        throw POSIXError(.ENOTSUP)
    }
    return .renamed
}

public func isOpen(_ path: String, openPaths: [String]) -> Bool {
    let canonical = physicalPath(path).precomposedStringWithCanonicalMapping
    return openPaths.contains {
        let p = $0.precomposedStringWithCanonicalMapping
        return p == canonical || p.hasPrefix(canonical + "/")
    }
}

public func excluded(_ path: String, root: String) -> Bool {
    guard path.hasPrefix(root + "/") else { return true }
    let parts = path.dropFirst(root.count + 1).split(separator: "/")
    let packages: Set<String> = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "fcpbundle", "logicx", "band", "rtfd", "sparsebundle"]
    return parts.contains { component in
        let name = String(component)
        return name.hasPrefix(".") || packages.contains((name as NSString).pathExtension.lowercased())
            || ["node_modules"].contains(name)
    }
}
