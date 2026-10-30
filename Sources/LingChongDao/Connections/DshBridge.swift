import Darwin
import Foundation
import IslandCore

/// DeepSeek Harness runs external observers as dsh profile bundles: a package
/// that declares `dsh.bundle.patch` and is selected in `dsh.profile.bundles`.
/// 灵宠岛 ships its own bundle, so it appears under the harness' installed
/// plugins and needs no hand-written loader row or third-party bridge package.
public enum DshBridge {
    public static let pluginPackage = "lingchongdao-dsh-hooks"
    public static let rowID = "lingchongdao-hooks"
    /// Only the bundle's runtime files are copied; `cordis.patch.yml` is the layer,
    /// `icon.png` what the harness paints, and `locale/*.json` the display title.
    static let pluginFiles = ["package.json", "index.js", "cordis.patch.yml", "icon.png", "locale/en.json", "locale/zh.json"]
    /// Marker of the 0.1.x loader row, kept only to remove it during migration.
    public static let beginMarker = "# lingchongdao-managed:v1:dsh begin"
    public static let endMarker = "# lingchongdao-managed:v1:dsh end"
    static let pluginTimeout: TimeInterval = 180

    /// The app reserves the `desktop` profile; its manifest proves the profile exists.
    static func profileExists(_ environment: ConnectionEnvironment) -> Bool {
        FileManager.default.fileExists(atPath: environment.dshProfileURL.appendingPathComponent("package.json").path)
    }

    /// A manifest entry alone can survive a broken link, so the resolved package
    /// directory and its bundle patch have to exist before the harness can load it.
    static func pluginInstalled(_ environment: ConnectionEnvironment) -> Bool {
        guard let data = try? Data(contentsOf: environment.dshProfileURL.appendingPathComponent("package.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              dependencies[pluginPackage] != nil else { return false }
        let packageDir = environment.dshProfileURL.appendingPathComponent("node_modules/\(pluginPackage)")
        return pluginFiles.allSatisfy { FileManager.default.fileExists(atPath: packageDir.appendingPathComponent($0).path) }
    }

    static func pluginRoot(_ environment: ConnectionEnvironment) -> URL {
        environment.dshProfileURL.appendingPathComponent("node_modules/\(pluginPackage)")
    }

    /// Compare the linked bundle copy against the one shipped in the app.
    static func updateAvailable(_ environment: ConnectionEnvironment) -> Bool {
        guard pluginInstalled(environment), let bundled = environment.dshPluginSourceURL else { return false }
        let installed = pluginRoot(environment)
        return PluginPackage.needsUpdate(
            bundledVersion: PluginPackage.version(manifestAt: bundled.appendingPathComponent("package.json")),
            installedVersion: PluginPackage.version(manifestAt: installed.appendingPathComponent("package.json")),
            bundledDigest: PluginPackage.digest(files: pluginFiles, root: bundled),
            installedDigest: PluginPackage.digest(files: pluginFiles, root: installed))
    }

    static func profileBundles(_ environment: ConnectionEnvironment) -> [String] {
        guard let data = try? Data(contentsOf: environment.dshProfileURL.appendingPathComponent("package.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else { return [] }
        return bundles
    }

    static func bundleSelected(_ environment: ConnectionEnvironment) -> Bool {
        profileBundles(environment).contains(pluginPackage)
    }

    /// Appends or removes the bundle name while keeping every other manifest key.
    /// Selecting appends to the end, which is where the harness itself would put it.
    static func setBundleSelected(_ selected: Bool, in environment: ConnectionEnvironment) throws {
        let url = environment.dshProfileURL.appendingPathComponent("package.json")
        guard let original = try ConnectionFileStore.readOptional(url),
              var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw ConnectionError.invalidConfiguration(url.path)
        }
        var dsh = root["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        var bundles = profile["bundles"] as? [String] ?? []
        if selected {
            guard !bundles.contains(pluginPackage) else { return }
            bundles.append(pluginPackage)
        } else {
            guard bundles.contains(pluginPackage) else { return }
            bundles.removeAll { $0 == pluginPackage }
        }
        profile["bundles"] = bundles
        dsh["profile"] = profile
        root["dsh"] = dsh
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ConnectionFileStore.writeAtomically(data + Data("\n".utf8), to: url, expected: original)
    }

    /// 0.1.x wrote one loader row into the profile patch. It still works but would
    /// double-report alongside the bundle, so install and disconnect remove it.
    public static func hasManagedRow(_ patchText: String?) -> Bool {
        guard let patchText else { return false }
        return patchText.contains(beginMarker) && patchText.contains(endMarker)
    }

    static func removeLegacyRow(in environment: ConnectionEnvironment) throws -> Bool {
        let url = environment.dshPatchURL
        guard let original = try ConnectionFileStore.readOptional(url),
              let updated = removingManagedRow(existing: text(original)) else { return false }
        try ConnectionFileStore.writeAtomically(Data(updated.utf8), to: url, expected: original)
        return true
    }

    /// nil means there is no owned row to remove; callers must not rewrite the file.
    public static func removingManagedRow(existing: String?) -> String? {
        guard hasManagedRow(existing), let existing else { return nil }
        let lines = strippedLines(existing)
        let remaining = lines.joined(separator: "\n")
        let meaningful = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if meaningful { return remaining + "\n" }
        // Comments alone still need a valid document body.
        return remaining.isEmpty ? "[]\n" : remaining + "\n[]\n"
    }

    /// Everything the review sheet shows before installing the bundle.
    static func preview() -> String {
        """
        # 组合包：\(pluginPackage)
        # 类型：dsh.bundle.patch → cordis.patch.yml
        - insert:
            - id: \(rowID)
              name: '\(pluginPackage)'
        # 启用：向 profile 的 dsh.profile.bundles 追加 '\(pluginPackage)'
        # 事件：SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SubagentStart, SubagentStop
        # 旧版 loader 行（若存在）会被清理，避免重复上报
        """
    }

    static func text(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }

    static func cliURL(appURL: URL?) -> URL? {
        guard let appURL else { return nil }
        let url = appURL.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Registers the copied plugin directory as a profile dependency. A local
    /// directory becomes a `link:` entry, so this never touches the network.
    static func addLocalPlugin(cliURL: URL, pluginDirectory: URL) throws -> String {
        let result = run(cliURL, ["plugin", "--profile", "desktop", "add", pluginDirectory.path], timeout: pluginTimeout)
        guard result.status == 0 else {
            throw ConnectionError.io("登记 dsh 组合包失败：\(summary(result.output))")
        }
        return summary(result.output)
    }

    /// Removes the profile dependency (pnpm remove). The caller deselects the
    /// bundle first so the harness never boots a bundle whose files are gone.
    static func removeLocalPlugin(cliURL: URL, packageName: String) throws -> String {
        let result = run(cliURL, ["plugin", "--profile", "desktop", "remove", packageName], timeout: pluginTimeout)
        guard result.status == 0 else {
            throw ConnectionError.io("卸载 dsh 组合包失败：\(summary(result.output))")
        }
        return summary(result.output)
    }

    private struct RunResult: Sendable {
        let status: Int32
        let output: String
    }

    /// Output goes to a file so a chatty package manager can never block on a full pipe.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> RunResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingchongdao-dsh-\(UUID().uuidString)", isDirectory: true)
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
            return RunResult(status: -1, output: "无法启动 dsh CLI：\(error.localizedDescription)")
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

    private static func strippedLines(_ text: String?) -> [String] {
        guard let text else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var kept: [String] = []
        var inside = false
        for line in lines {
            if line.contains(beginMarker) { inside = true; continue }
            if inside, line.contains(endMarker) { inside = false; continue }
            if inside { continue }
            kept.append(line)
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return kept
    }
}
