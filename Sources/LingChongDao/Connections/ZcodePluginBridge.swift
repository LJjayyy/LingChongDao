import Darwin
import Foundation
import IslandCore

/// ZCode exposes a native plugin system: a marketplace directory holds one
/// `.zcode-plugin` package whose `hooks/hooks.json` runs without any profile
/// switch. 灵宠岛 installs its own local marketplace through the bundled CLI, so
/// the integration shows up in ZCode's Plugin Management and can be toggled
/// there. Only stable paths and CLI output are read.
public enum ZcodePluginBridge {
    public static let marketplaceName = "lingchongdao-local"
    public static let pluginName = "lingchongdao-zcode"
    public static var pluginID: String { "\(pluginName)@\(marketplaceName)" }
    static let pluginTimeout: TimeInterval = 120

    static func cli(_ appURL: URL?) -> (executable: URL, script: URL)? {
        guard let appURL else { return nil }
        let executable = appURL.appendingPathComponent("Contents/MacOS/ZCode")
        let script = appURL.appendingPathComponent("Contents/Resources/glm/zcode.cjs")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return (executable, script)
    }

    /// Stable copy of the marketplace + plugin inside 灵宠岛's support directory.
    static func packageRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.applicationSupportURL.appendingPathComponent("zcode-plugin", isDirectory: true)
    }

    static func marketplaceRepository(_ environment: ConnectionEnvironment) -> URL {
        environment.zcodeHomeURL.appendingPathComponent("cli/plugins/marketplaces/\(marketplaceName)", isDirectory: true)
    }

    static func cacheRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.zcodeHomeURL.appendingPathComponent("cli/plugins/cache/\(marketplaceName)/\(pluginName)", isDirectory: true)
    }

    static func marketplaceInstalled(_ environment: ConnectionEnvironment) -> Bool {
        FileManager.default.fileExists(atPath: marketplaceRepository(environment).appendingPathComponent("marketplace.json").path)
    }

    /// Any cached version with a manifest proves ZCode installed the plugin.
    static func pluginInstalled(_ environment: ConnectionEnvironment) -> Bool {
        installedRoot(environment) != nil
    }

    static let packageFiles = [".zcode-plugin/plugin.json", "hooks/hooks.json", "scripts/forward-hook.sh", "icon.png"]

    static func installedRoot(_ environment: ConnectionEnvironment) -> URL? {
        let root = cacheRoot(environment)
        guard let versions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return versions.filter { version in
            FileManager.default.fileExists(atPath: version.appendingPathComponent(".zcode-plugin/plugin.json").path)
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.first
    }

    static func bundledRoot(_ environment: ConnectionEnvironment) -> URL? {
        environment.zcodePluginSourceURL?.appendingPathComponent("plugins/\(pluginName)", isDirectory: true)
    }

    /// Compare the newest installed cache against the bundled package; equal
    /// versions still report an update when the shipped files differ.
    static func updateAvailable(_ environment: ConnectionEnvironment) -> Bool {
        guard let installed = installedRoot(environment), let bundled = bundledRoot(environment) else { return false }
        return PluginPackage.needsUpdate(
            bundledVersion: PluginPackage.version(manifestAt: bundled.appendingPathComponent(".zcode-plugin/plugin.json")),
            installedVersion: PluginPackage.version(manifestAt: installed.appendingPathComponent(".zcode-plugin/plugin.json")),
            bundledDigest: PluginPackage.digest(files: packageFiles, root: bundled),
            installedDigest: PluginPackage.digest(files: packageFiles, root: installed))
    }

    /// nil means the config has no opinion, in which case ZCode treats it as enabled.
    static func pluginEnabled(_ environment: ConnectionEnvironment) -> Bool? {
        guard let data = try? Data(contentsOf: environment.zcodeHomeURL.appendingPathComponent("cli/config.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let enabled = plugins["enabledPlugins"] as? [String: Any] else { return nil }
        return enabled[pluginID] as? Bool
    }

    static func isActive(_ environment: ConnectionEnvironment) -> Bool {
        pluginInstalled(environment) && pluginEnabled(environment) != false
    }

    static func installPackage(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".zcode-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        try injectIcon(into: destination)
    }

    /// ZCode paints a plugin's `listing.icon`; local marketplace entries carry none,
    /// so the packaged PNG is embedded as a data URL in the copied marketplace file.
    static func injectIcon(into packageRoot: URL) throws {
        let iconURL = packageRoot.appendingPathComponent("plugins/\(pluginName)/icon.png")
        guard let iconData = try? Data(contentsOf: iconURL) else { return }
        let manifestURL = packageRoot.appendingPathComponent("marketplace.json")
        guard let original = try? Data(contentsOf: manifestURL),
              var root = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var plugins = root["plugins"] as? [[String: Any]],
              let index = plugins.firstIndex(where: { ($0["name"] as? String) == pluginName }) else { return }
        let icon = "data:image/png;base64," + iconData.base64EncodedString()
        guard (plugins[index]["icon"] as? String) != icon else { return }
        plugins[index]["icon"] = icon
        root["plugins"] = plugins
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ConnectionFileStore.writeAtomically(updated + Data("\n".utf8), to: manifestURL, expected: original)
    }

    static func removePackage(_ environment: ConnectionEnvironment) {
        try? FileManager.default.removeItem(at: packageRoot(environment))
    }

    /// Re-registers a fresh marketplace snapshot, then installs the plugin.
    /// ZCode copies the marketplace directory, so an update needs the remove/add pair.
    static func installMarketplace(appURL: URL, directory: URL) throws -> String {
        guard let cli = cli(appURL) else {
            throw ConnectionError.io("未找到 ZCode 自带的插件 CLI，无法安装插件。")
        }
        _ = run(cli, ["plugins", "uninstall", pluginName, "-s", "user", "--force"], timeout: pluginTimeout)
        _ = run(cli, ["plugins", "marketplace", "remove", marketplaceName], timeout: pluginTimeout)
        let added = run(cli, ["plugins", "marketplace", "add", directory.path, "--scope", "user"], timeout: pluginTimeout)
        guard added.status == 0 else {
            throw ConnectionError.io("注册 ZCode 插件市场失败：\(summary(added.output))")
        }
        let installed = run(cli, ["plugins", "install", pluginID, "-s", "user"], timeout: pluginTimeout)
        guard installed.status == 0 else {
            throw ConnectionError.io("安装 ZCode 插件失败：\(summary(installed.output))")
        }
        return summary(installed.output)
    }

    static func uninstall(appURL: URL) throws -> String {
        guard let cli = cli(appURL) else {
            throw ConnectionError.io("未找到 ZCode 自带的插件 CLI，无法卸载插件。")
        }
        let removed = run(cli, ["plugins", "uninstall", pluginName, "-s", "user", "--force"], timeout: pluginTimeout)
        _ = run(cli, ["plugins", "marketplace", "remove", marketplaceName], timeout: pluginTimeout)
        guard removed.status == 0 else {
            throw ConnectionError.io("卸载 ZCode 插件失败：\(summary(removed.output))")
        }
        return summary(removed.output)
    }

    private struct RunResult: Sendable {
        let status: Int32
        let output: String
    }

    /// The app has no standalone `node`; its Electron binary runs the bundled CLI
    /// as Node. Output goes to a file so a chatty CLI can never block on a pipe.
    private static func run(_ cli: (executable: URL, script: URL), _ arguments: [String], timeout: TimeInterval) -> RunResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingchongdao-zcode-\(UUID().uuidString)", isDirectory: true)
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
        process.executableURL = cli.executable
        process.arguments = [cli.script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch {
            try? handle.close()
            return RunResult(status: -1, output: "无法启动 ZCode CLI：\(error.localizedDescription)")
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
