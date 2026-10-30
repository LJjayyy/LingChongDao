import CoreFoundation
import Darwin
import Foundation

/// Legacy identifiers are intentionally retained only here and in exact hook
/// ownership checks. Never merge two data stores or adopt an arbitrary symlink.
public enum RuntimeIdentityMigration {
    public static let legacyBundleIdentifier = "local.ai-island.app"
    public static let bundleIdentifier = "local.lingchongdao.app"

    public static func migrateSupport(in base: URL) throws {
        let old = base.appendingPathComponent("AIIsland", isDirectory: true)
        let new = base.appendingPathComponent("LingChongDao", isDirectory: true)
        try ConnectionFileStore.validateExistingFile(new.appendingPathComponent(".migration-path-check"))
        let oldInfo = try info(old)
        let newInfo = try info(new)
        if let oldInfo, (oldInfo.st_mode & S_IFMT) == S_IFLNK {
            guard oldInfo.st_uid == getuid(),
                  try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == new.path,
                  let newInfo, newInfo.st_uid == getuid(), (newInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw ConnectionError.unsafePath(old.path)
            }
            try copyLegacyHelper(in: new)
            return
        }
        if let oldInfo {
            guard oldInfo.st_uid == getuid(), (oldInfo.st_mode & S_IFMT) == S_IFDIR else { throw ConnectionError.unsafePath(old.path) }
            guard newInfo == nil else { throw ConnectionError.io("旧版与新版数据目录同时存在，已保留两者，请先人工处理冲突：\(old.path)；\(new.path)") }
            try validateTree(old)
            // Validate helper ownership before changing any location.
            try validateLegacyHelper(in: old)
            guard rename(old.path, new.path) == 0 else { throw ConnectionError.io(String(cString: strerror(errno))) }
        } else if let newInfo {
            guard newInfo.st_uid == getuid(), (newInfo.st_mode & S_IFMT) == S_IFDIR else { throw ConnectionError.unsafePath(new.path) }
        } else {
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try copyLegacyHelper(in: new)
        // Cached commands still point at the legacy socket and executable.
        // symlink() fails rather than replacing a concurrently created path.
        guard symlink(new.path, old.path) == 0 else { throw ConnectionError.io("无法建立旧连接兼容路径：\(String(cString: strerror(errno)))") }
    }

    /// Only application-owned preferences are copied, and only into absent keys.
    /// Pass persistent domains rather than dictionaryRepresentation (which also
    /// contains global/system preferences and registered defaults).
    public static func mergedPreferences(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        let booleans: Set<String> = ["island.enabled", "island.idleVisible", "island.additionalDisplays", "island.haptics", "sources.qoder", "sources.codex", "sources.generic"]
        var result = current
        for (key, value) in legacy where current[key] == nil {
            if booleans.contains(key), let number = value as? NSNumber,
               CFGetTypeID(number) == CFBooleanGetTypeID() { result[key] = value }
            else if ["island.widthPercent", "island.heightPercent"].contains(key),
                    let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { result[key] = value }
            else if key.hasPrefix("draft."), let draft = value as? String { result[key] = String(draft.prefix(20_000)) }
        }
        return result
    }

    public static func migratePreferences(defaults: UserDefaults = .standard) {
        let current = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) ?? [:]
        let merged = mergedPreferences(legacy: legacy, current: current)
        // Individual keys preserve concurrent unrelated preference updates.
        for (key, value) in merged where current[key] == nil { defaults.set(value, forKey: key) }
    }

    private static func info(_ url: URL) throws -> stat? {
        var result = stat()
        if lstat(url.path, &result) == 0 { return result }
        if errno == ENOENT { return nil }
        throw ConnectionError.io(String(cString: strerror(errno)))
    }

    private static func validateTree(_ root: URL) throws {
        guard let entry = try info(root), entry.st_uid == getuid(),
              [S_IFDIR, S_IFREG, S_IFSOCK].contains(entry.st_mode & S_IFMT) else { throw ConnectionError.unsafePath(root.path) }
        if entry.st_mode & S_IFMT == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try validateTree(child) }
        }
    }

    private static func validateLegacyHelper(in directory: URL) throws {
        let oldHelper = directory.appendingPathComponent("bin/ai-island-hook")
        guard let bytes = try ConnectionFileStore.readOptional(oldHelper) else { return }
        let manifest = try ConnectionFileStore.readManifest(directory.appendingPathComponent("hook-installation.json"))
        guard manifest.helperSHA256 == ConnectionFileStore.digest(bytes),
              FileManager.default.isExecutableFile(atPath: oldHelper.path) else { throw ConnectionError.unownedHelper(oldHelper.path) }
    }

    private static func copyLegacyHelper(in directory: URL) throws {
        let newHelper = directory.appendingPathComponent("bin/lingchongdao-hook")
        // An existing canonical helper is never overwritten by migration.
        if try ConnectionFileStore.readOptional(newHelper) != nil { return }
        try validateLegacyHelper(in: directory)
        if let bytes = try ConnectionFileStore.readOptional(directory.appendingPathComponent("bin/ai-island-hook")) {
            try ConnectionFileStore.writeAtomically(bytes, to: newHelper, expected: nil, newPermissions: 0o700)
        }
    }
}
