import CryptoKit
import Darwin
import Foundation

struct HookInstallationManifest: Codable, Sendable {
    var version = 1
    var helperSHA256: String?
    var ownedCommands: [String: [String]] = [:]
    /// ZCode's pre-install `hooks.enabled` value, so disconnect can restore it.
    /// Optional so installations written by earlier versions keep decoding.
    var hooksEnabledStates: [String: HooksEnabledState]?
}

enum ConnectionFileStore {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func readOptional(_ url: URL) throws -> Data? {
        try validateExistingFile(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func readManifest(_ url: URL) throws -> HookInstallationManifest {
        guard let data = try readOptional(url) else { return HookInstallationManifest() }
        do {
            let manifest = try JSONDecoder().decode(HookInstallationManifest.self, from: data)
            guard manifest.version == 1 else { throw ConnectionError.invalidManifest }
            return manifest
        } catch { throw ConnectionError.invalidManifest }
    }

    /// Refuse symlinks or another user's files rather than silently following / replacing them.
    static func validateExistingFile(_ url: URL) throws {
        // Foundation may shorten an existing /private/tmp path to /tmp during
        // standardization. /tmp itself is a system symlink, so checking that
        // rewritten path would reject an originally symlink-free path. Inspect
        // the exact path used for I/O instead; never resolve arbitrary links.
        let path = url.path
        var components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard url.isFileURL, path.hasPrefix("/"), !components.isEmpty,
              !components.contains("."), !components.contains("..") else { throw ConnectionError.unsafePath(path) }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { throw ConnectionError.unsafePath(path) }
        } else if errno != ENOENT { throw ConnectionError.io(String(cString: strerror(errno))) }
        components.removeLast()
        while !components.isEmpty {
            let directory = "/" + components.joined(separator: "/")
            var parentInfo = stat()
            if lstat(directory, &parentInfo) == 0 {
                guard (parentInfo.st_mode & S_IFMT) == S_IFDIR else { throw ConnectionError.unsafePath(directory) }
            } else if errno != ENOENT { throw ConnectionError.io(String(cString: strerror(errno))) }
            components.removeLast()
        }
    }

    private static func createPrivateDirectories(_ url: URL) throws {
        let fm = FileManager.default
        var missing: [URL] = []
        var current = url
        while !fm.fileExists(atPath: current.path) && current.path != "/" {
            missing.append(current)
            current.deleteLastPathComponent()
        }
        for directory in missing.reversed() {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    /// The backup is completed before the destination changes. A same-directory rename is atomic.
    /// Existing-file metadata (including ACLs/xattrs on macOS) is copied to the replacement first.
    @discardableResult
    static func writeAtomically(_ data: Data, to url: URL, expected: Data?, newPermissions: Int = 0o600) throws -> URL? {
        try validateExistingFile(url)
        guard try readOptional(url) == expected else { throw ConnectionError.configurationChanged }
        let fm = FileManager.default
        try createPrivateDirectories(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lingchongdao-\(UUID().uuidString).tmp")
        var backup: URL?
        defer { try? fm.removeItem(at: temporary) }
        if expected != nil {
            let backupURL = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).lingchongdao-backup-\(backupTimestamp())-\(UUID().uuidString.prefix(8))")
            try fm.copyItem(at: url, to: backupURL)
            backup = backupURL
            // Keep the original mode/ACL on the replacement, not a new default mode.
            try fm.copyItem(at: url, to: temporary)
        } else {
            guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: newPermissions]) else { throw ConnectionError.io("无法创建临时文件") }
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // Catch an editor that changed the file while the backup / replacement was being prepared.
        guard try readOptional(url) == expected else { throw ConnectionError.configurationChanged }
        guard rename(temporary.path, url.path) == 0 else { throw ConnectionError.io(String(cString: strerror(errno))) }
        return backup
    }

    private static func backupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
