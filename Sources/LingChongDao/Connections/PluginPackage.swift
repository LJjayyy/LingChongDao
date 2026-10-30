import Foundation
import IslandCore

/// Shared comparisons for native plugin packages. The bundled package
/// is the source of truth: a newer manifest version, or different content at the
/// same version, means the host still carries an older install.
enum PluginPackage {
    static func version(manifestAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["version"] as? String
    }

    static func digest(files: [String], root: URL) -> String? {
        var data = Data()
        for name in files {
            guard let file = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
            data.append(Data(name.utf8))
            data.append(file)
        }
        return ConnectionFileStore.digest(data)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let lhs = components(candidate), let rhs = components(installed) else {
            return candidate != installed
        }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func needsUpdate(bundledVersion: String?, installedVersion: String?,
                            bundledDigest: @autoclosure () -> String?,
                            installedDigest: @autoclosure () -> String?) -> Bool {
        guard let bundled = bundledVersion, let installed = installedVersion else { return false }
        if bundled != installed { return isNewer(bundled, than: installed) }
        return bundledDigest() != installedDigest()
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(whereSeparator: { $0 == "." || $0 == "-" })
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            let digits = part.prefix(while: \.isNumber)
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            result.append(value)
        }
        return result
    }
}
