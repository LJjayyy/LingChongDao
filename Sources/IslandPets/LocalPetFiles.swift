import Foundation

// These readers intentionally return bytes from the installed application at runtime.
// No provider artwork is included in this package or copied into its build products.
enum PetLimits {
    static let manifest = 1 * 1024 * 1024
    static let state = 16 * 1024 * 1024
    static let image = 32 * 1024 * 1024
    static let cache = 64 * 1024 * 1024
    static let asarHeader = 32 * 1024 * 1024
}

func petFileStamp(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw PetSourceError.invalid("宠物素材不是普通文件") }
    return "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
}

func petReadLimited(_ url: URL, limit: Int) throws -> Data {
    let attrs = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attrs.isRegularFile == true, let size = attrs.fileSize, size >= 0, size <= limit else {
        throw PetSourceError.invalid("宠物素材文件超过大小限制")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw PetSourceError.invalid("宠物素材文件超过大小限制") }
    return data
}

func petSafeChild(_ relative: String, under directory: URL) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\0") else {
        throw PetSourceError.invalid("无效的宠物素材路径")
    }
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw PetSourceError.invalid("宠物素材路径越界")
    }
    let base = directory.resolvingSymlinksInPath().standardizedFileURL
    let child = directory.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard child.path.hasPrefix(base.path + "/") else { throw PetSourceError.invalid("宠物素材路径越界") }
    return child
}

func petJSON(_ data: Data) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw PetSourceError.invalid("宠物配置必须为 JSON 对象")
    }
    return dictionary
}

func petIsImage(_ data: Data) -> Bool {
    if data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
       String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" { return true }
    return data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
}

final class PetASARArchive {
    let url: URL
    let revision: String
    private let root: [String: Any]
    private let payloadOffset: UInt64
    private let fileSize: UInt64

    init(url: URL) throws {
        self.url = url
        revision = try petFileStamp(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 16), bytes.count == 16 else { throw PetSourceError.invalid("ASAR 文件头不完整") }
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) } }
        let headerSize = Int(u32(4)), jsonSize = Int(u32(12))
        guard headerSize >= 8, jsonSize > 0, jsonSize <= PetLimits.asarHeader, jsonSize <= headerSize - 8 else {
            throw PetSourceError.invalid("ASAR 文件头越界")
        }
        fileSize = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        payloadOffset = UInt64(8 + headerSize)
        guard payloadOffset <= fileSize else { throw PetSourceError.invalid("ASAR 数据区越界") }
        guard let json = try handle.read(upToCount: jsonSize), json.count == jsonSize else { throw PetSourceError.invalid("ASAR 索引不完整") }
        root = try petJSON(json)
    }

    private func entry(_ path: String) throws -> [String: Any]? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.contains("\\") else {
            throw PetSourceError.invalid("ASAR 素材路径越界")
        }
        var node = root
        for component in components {
            guard let files = node["files"] as? [String: Any], let child = files[String(component)] as? [String: Any] else { return nil }
            node = child
        }
        guard node["link"] == nil else { throw PetSourceError.invalid("ASAR 素材链接不受支持") }
        return node
    }

    func names(in directory: String) throws -> [String] {
        guard let node = try entry(directory), let files = node["files"] as? [String: Any] else { return [] }
        return files.keys.sorted()
    }

    func resourceStamp(_ path: String) throws -> String? {
        guard let item = try entry(path), item["size"] != nil else { return nil }
        if item["unpacked"] as? Bool == true {
            let outside = URL(fileURLWithPath: url.path + ".unpacked", isDirectory: true)
            return try petFileStamp(petSafeChild(path, under: outside))
        }
        return revision + "|" + path
    }

    func read(_ path: String, limit: Int) throws -> Data? {
        guard let item = try entry(path) else { return nil }
        guard let number = item["size"] as? NSNumber, number.doubleValue >= 0, number.doubleValue <= Double(limit) else {
            throw PetSourceError.invalid("ASAR 素材超过大小限制")
        }
        let size = number.intValue
        if item["unpacked"] as? Bool == true {
            return try petReadLimited(petSafeChild(path, under: URL(fileURLWithPath: url.path + ".unpacked", isDirectory: true)), limit: limit)
        }
        guard let value = item["offset"] as? String, let offset = UInt64(value), offset <= fileSize,
              UInt64(size) <= fileSize, payloadOffset <= fileSize - UInt64(size), offset <= fileSize - payloadOffset - UInt64(size) else {
            throw PetSourceError.invalid("ASAR 素材偏移越界")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: payloadOffset + offset)
        guard let data = try handle.read(upToCount: size), data.count == size else { throw PetSourceError.invalid("ASAR 素材不完整") }
        return data
    }
}
