import Darwin
import Foundation
import IslandCore

/// Qoder CN exposes a native plugin system: `.qoder-plugin/plugin.json` with a
/// hooks file, installed by the bundled `qoderclicn` CLI (local directory
/// installs are supported) and enabled through `settings.json`.
public enum QoderPluginBridge {
    public static let pluginName = "lingchongdao-qoder"
    public static var pluginID: String { "\(pluginName)@local" }
    static let pluginTimeout: TimeInterval = 120

    /// The CLI lives in the Qoder home as `bin/qoderclicn/qoderclicn-<version>`.
    static func cliURL(_ environment: ConnectionEnvironment) -> URL? {
        let directory = environment.qoderHomeURL.appendingPathComponent("bin/qoderclicn", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let candidates = names.filter { $0.hasPrefix("qoderclicn-") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func packageRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.applicationSupportURL.appendingPathComponent("qoder-plugin", isDirectory: true)
    }

    static func cacheRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.qoderHomeURL.appendingPathComponent("plugins/cache/local/\(pluginName)", isDirectory: true)
    }

    /// nil means the config has no opinion, in which case Qoder treats it as enabled.
    static func pluginEnabled(_ environment: ConnectionEnvironment) -> Bool? {
        guard let data = try? Data(contentsOf: environment.qoderHomeURL.appendingPathComponent("settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = root["enabledPlugins"] as? [String: Any] else { return nil }
        return enabled[pluginID] as? Bool
    }

    /// Any cached version with a manifest proves the CLI installed the plugin.
    static func pluginInstalled(_ environment: ConnectionEnvironment) -> Bool {
        installedRoot(environment) != nil
    }

    static let packageFiles = [".qoder-plugin/plugin.json", ".qoder-plugin/qoder-hooks.json", "scripts/forward-hook.sh", "assets/icon.png"]

    static func installedRoot(_ environment: ConnectionEnvironment) -> URL? {
        let root = cacheRoot(environment)
        guard let versions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return versions.filter { version in
            FileManager.default.fileExists(atPath: version.appendingPathComponent(".qoder-plugin/plugin.json").path)
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.first
    }

    static func bundledRoot(_ environment: ConnectionEnvironment) -> URL? {
        environment.qoderPluginSourceURL
    }

    /// Compare the installed cache with the bundled plugin; equal versions still
    /// report an update when the shipped files differ.
    static func updateAvailable(_ environment: ConnectionEnvironment) -> Bool {
        guard let installed = installedRoot(environment), let bundled = bundledRoot(environment) else { return false }
        return PluginPackage.needsUpdate(
            bundledVersion: PluginPackage.version(manifestAt: bundled.appendingPathComponent(".qoder-plugin/plugin.json")),
            installedVersion: PluginPackage.version(manifestAt: installed.appendingPathComponent(".qoder-plugin/plugin.json")),
            bundledDigest: PluginPackage.digest(files: packageFiles, root: bundled),
            installedDigest: PluginPackage.digest(files: packageFiles, root: installed))
    }

    static func isActive(_ environment: ConnectionEnvironment) -> Bool {
        pluginInstalled(environment) && pluginEnabled(environment) != false
    }

    static func installPackage(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".qoder-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    static func removePackage(_ environment: ConnectionEnvironment) {
        try? FileManager.default.removeItem(at: packageRoot(environment))
    }

    /// Qoder's extension list paints `icon_url` from the installed record; local
    /// directory installs leave it empty. Encode the packaged icon once so the
    /// row shows 灵宠岛's logo instead of the generic plugin artwork.
    static func tagInstalledIcon(_ environment: ConnectionEnvironment) throws {
        let iconURL = packageRoot(environment).appendingPathComponent("assets/icon.png")
        guard let iconData = try? Data(contentsOf: iconURL) else { return }
        let recordURL = environment.qoderHomeURL.appendingPathComponent("plugins/installed_plugins_v2.json")
        guard let original = try ConnectionFileStore.readOptional(recordURL),
              var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var plugins = root["plugins"] as? [String: Any],
              var entries = plugins[pluginID] as? [[String: Any]], !entries.isEmpty else { return }
        let icon = "data:image/png;base64," + iconData.base64EncodedString()
        guard entries.contains(where: { ($0["icon_url"] as? String) != icon }) else { return }
        for index in entries.indices { entries[index]["icon_url"] = icon }
        plugins[pluginID] = entries
        root["plugins"] = plugins
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ConnectionFileStore.writeAtomically(updated + Data("\n".utf8), to: recordURL, expected: original)
    }

    /// Local directory installs are supported directly; reinstall replaces the
    /// cached copy so an updated package takes effect.
    static func installLocalPlugin(cliURL: URL, directory: URL) throws -> String {
        _ = run(cliURL, ["plugins", "uninstall", pluginName], timeout: pluginTimeout)
        let result = run(cliURL, ["plugins", "install", directory.path, "-s", "user"], timeout: pluginTimeout)
        guard result.status == 0 else {
            throw ConnectionError.io("安装 Qoder 插件失败：\(summary(result.output))")
        }
        return summary(result.output)
    }

    static func uninstall(cliURL: URL) throws -> String {
        let result = run(cliURL, ["plugins", "uninstall", pluginName], timeout: pluginTimeout)
        guard result.status == 0 else {
            throw ConnectionError.io("卸载 Qoder 插件失败：\(summary(result.output))")
        }
        return summary(result.output)
    }

    private struct RunResult: Sendable {
        let status: Int32
        let output: String
    }

    /// Output goes to a file so a chatty CLI can never block on a pipe.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> RunResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingchongdao-qoder-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])) != nil,
              FileManager.default.createFile(atPath: directory.appendingPathComponent("output.txt").path, contents: nil) else {
            return RunResult(status: -1, output: "无法创建临时输出文件")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.txt")
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return RunResult(status: -1, output: "无法写入临时输出文件")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch {
            try? handle.close()
            return RunResult(status: -1, output: "无法启动 Qoder CLI：\(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        var timedOut = false
        if process.isRunning {
            process.terminate(); usleep(300_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            timedOut = true
        }
        try? handle.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let text = String(decoding: data.suffix(8192), as: UTF8.self)
        return RunResult(status: timedOut ? -2 : process.terminationStatus,
                         output: timedOut ? "命令在 \(Int(timeout)) 秒后未结束。\n" + text : text)
    }

    private static func summary(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.suffix(3).joined(separator: " | ").prefix(400))
    }
}
