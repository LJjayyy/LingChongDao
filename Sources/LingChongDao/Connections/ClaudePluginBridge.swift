import Darwin
import Foundation

/// Uses Claude's public plugin CLI. Only this plugin's installation record is
/// inspected; conversation history and credentials are never read.
public enum ClaudePluginBridge {
    public static let marketplaceName = "lingchongdao-local"
    public static let pluginName = "lingchongdao"
    public static let pluginID = "lingchongdao@lingchongdao-local"
    static let files = [".claude-plugin/plugin.json", "hooks/hooks.json", "scripts/forward-hook.sh", "assets/icon.png"]

    static func packageRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.applicationSupportURL.appendingPathComponent("claude-plugin", isDirectory: true)
    }

    static func bundledRoot(_ environment: ConnectionEnvironment) -> URL? {
        environment.claudePluginSourceURL?.appendingPathComponent("plugins/\(pluginName)", isDirectory: true)
    }

    /// Desktop downloads a versioned, standalone native CLI. Search only its
    /// documented app-owned runtime folder, newest version first, without PATH
    /// changes or installing another runtime.
    static func desktopCLIs(_ environment: ConnectionEnvironment) -> [URL] {
        let root = environment.homeDirectoryURL.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let fm = FileManager.default
        let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var result: [URL] = []
        for version in versions.filter({ $0.lastPathComponent.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil })
            .sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }).prefix(12) {
            let builds = (try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
            for build in builds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(12) {
                let cli = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: cli.path) { result.append(cli) }
            }
        }
        return result
    }

    static func installedRoot(_ environment: ConnectionEnvironment) -> URL? {
        let url = environment.claudeHomeURL.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? ConnectionFileStore.readOptional(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let records = plugins[pluginID] as? [[String: Any]],
              let path = records.first(where: { ($0["scope"] as? String) == "user" })?["installPath"] as? String,
              path.hasPrefix("/") else { return nil }
        let installed = URL(fileURLWithPath: path, isDirectory: true)
        // The CLI's user cache is the only installation location we manage.
        let cache = environment.claudeHomeURL.appendingPathComponent("plugins/cache/\(marketplaceName)/\(pluginName)", isDirectory: true)
        guard installed.standardizedFileURL.path.hasPrefix(cache.standardizedFileURL.path + "/"),
              (try? ConnectionFileStore.readOptional(installed.appendingPathComponent(files[0]))) != nil else { return nil }
        return installed
    }

    static func enabled(_ environment: ConnectionEnvironment) -> Bool {
        guard let data = try? ConnectionFileStore.readOptional(environment.claudeHomeURL.appendingPathComponent("settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["disableAllHooks"] as? Bool != true,
              let plugins = root["enabledPlugins"] as? [String: Any] else { return false }
        return plugins[pluginID] as? Bool == true
    }

    static func updateAvailable(_ environment: ConnectionEnvironment) -> Bool {
        guard let installed = installedRoot(environment), let bundled = bundledRoot(environment) else { return false }
        return PluginPackage.needsUpdate(
            bundledVersion: PluginPackage.version(manifestAt: bundled.appendingPathComponent(files[0])),
            installedVersion: PluginPackage.version(manifestAt: installed.appendingPathComponent(files[0])),
            bundledDigest: PluginPackage.digest(files: files, root: bundled),
            installedDigest: PluginPackage.digest(files: files, root: installed))
    }

    static func registeredSource(_ environment: ConnectionEnvironment) throws -> String? {
        let file = environment.claudeHomeURL.appendingPathComponent("plugins/known_marketplaces.json")
        guard let data = try ConnectionFileStore.readOptional(file) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionError.invalidConfiguration(file.path)
        }
        guard let record = root[marketplaceName] as? [String: Any] else { return nil }
        guard let source = record["source"] as? [String: Any], source["source"] as? String == "directory",
              let path = source["path"] as? String else {
            throw ConnectionError.io("Claude 中已有同名插件市场，来源不属于灵宠岛，已保留。")
        }
        return path
    }

    static func install(cli: URL, environment: ConnectionEnvironment) throws {
        let directory = packageRoot(environment)
        if let source = try registeredSource(environment) {
            guard URL(fileURLWithPath: source).standardizedFileURL == directory.standardizedFileURL else {
                throw ConnectionError.io("Claude 中已有同名插件市场，路径不属于灵宠岛，已保留：\(source)")
            }
        } else {
            try run(cli, ["plugin", "marketplace", "add", directory.path, "--scope", "user"], environment: environment)
        }
        // Local directory marketplaces read the copied catalog directly. Update
        // refreshes an existing cache without uninstalling a working plugin first.
        if installedRoot(environment) != nil {
            try run(cli, ["plugin", "update", pluginID, "--scope", "user"], environment: environment)
            // Claude keys its cache by version: update can be a no-op when the
            // version is unchanged but files need repair. Reinstall only our
            // user-scoped plugin through the official CLI in that case.
            if let installed = installedRoot(environment),
               let bundled = bundledRoot(environment),
               PluginPackage.digest(files: files, root: installed) != PluginPackage.digest(files: files, root: bundled) {
                try run(cli, ["plugin", "uninstall", pluginID, "--scope", "user"], environment: environment)
                try run(cli, ["plugin", "install", pluginID, "--scope", "user"], environment: environment)
            }
        } else {
            try run(cli, ["plugin", "install", pluginID, "--scope", "user"], environment: environment)
        }
        let settingsURL = environment.claudeHomeURL.appendingPathComponent("settings.json")
        let settingsData = try ConnectionFileStore.readOptional(settingsURL) ?? Data("{}".utf8)
        let settings = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        if (settings?["enabledPlugins"] as? [String: Any])?[pluginID] as? Bool != true {
            try run(cli, ["plugin", "enable", pluginID, "--scope", "user"], environment: environment)
        }
    }

    static func uninstall(cli: URL, environment: ConnectionEnvironment) throws {
        guard let source = try registeredSource(environment),
              URL(fileURLWithPath: source).standardizedFileURL == packageRoot(environment).standardizedFileURL else {
            throw ConnectionError.io("无法确认 Claude 插件市场归属，未卸载。")
        }
        try run(cli, ["plugin", "uninstall", pluginID, "--scope", "user"], environment: environment)
        // Keep the local marketplace registration: another project-scoped install
        // may still use it. No other scope or plugin is removed.
    }

    static func run(_ cli: URL, _ arguments: [String], environment: ConnectionEnvironment) throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("lcd-claude-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("output")
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConnectionError.io("无法创建 Claude CLI 输出文件。")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.currentDirectoryURL = temporary
        var variables = ProcessInfo.processInfo.environment
        variables["CLAUDE_CONFIG_DIR"] = environment.claudeHomeURL.path
        for key in ["ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "NODE_PATH", "CLAUDECODE"] { variables.removeValue(forKey: key) }
        process.environment = variables
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline { usleep(30_000) }
        if process.isRunning {
            process.terminate(); usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ConnectionError.io("Claude 插件操作超时，请在 Claude 的插件管理中检查。")
        }
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 8192) ?? Data()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConnectionError.io("Claude 插件操作失败：\(text.prefix(900))")
        }
    }
}
