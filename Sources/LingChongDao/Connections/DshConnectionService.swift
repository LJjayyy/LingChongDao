import Foundation
import IslandCore

/// DeepSeek Harness connection: copy 灵宠岛's own helper and dsh bundle to stable
/// locations, register the bundle as a `desktop` profile dependency through the
/// application's own `dsh` CLI, and select it in `dsh.profile.bundles` so it shows
/// up as an installed dsh plugin. No third-party bridge package is involved.
public actor DshConnectionService {
    public let environment: ConnectionEnvironment
    private static let expectedEventCount = 7

    private struct Prepared: Sendable {
        let plan: HookInstallationPlan
        let patchOriginal: Data?
        let profileManifestOriginal: Data?
        let helperSource: URL
        let pluginSource: URL
        let helperDigest: String
        let pluginDigest: String
        let cliURL: URL
    }
    private var prepared: Prepared?

    public init(environment: ConnectionEnvironment) { self.environment = environment }

    public func check() async -> ProviderConnection {
        let detection = await ProviderDetector.detect(provider: .dsh, environment: environment)
        var connection = ProviderConnection(provider: .dsh, displayName: HookConnectionService.name(.dsh), detection: detection,
                                            status: .notDetected, capabilities: HookConnectionService.capabilities(.dsh),
                                            message: "", hookPreview: "", installedHookCount: 0,
                                            expectedHookCount: Self.expectedEventCount, lastEventAt: nil)
        guard DshBridge.profileExists(environment) else {
            connection.message = "未找到 DeepSeek Harness 的 desktop profile（\(environment.dshProfileURL.path)）。请先启动一次 DeepSeek Harness。"
            return connection
        }
        connection.hookPreview = DshBridge.preview()
        let hasPlugin = DshBridge.pluginInstalled(environment)
        let hasBundle = DshBridge.bundleSelected(environment)
        let hasHelper = helperIsHealthy()
        let patchData: Data? = (try? ConnectionFileStore.readOptional(environment.dshPatchURL)) ?? nil
        let hasLegacyRow = DshBridge.hasManagedRow(DshBridge.text(patchData))
        // Selecting the bundle is the user-visible "installed" state: the card then
        // offers repair/uninstall even if a copied file is out of date.
        connection.installedHookCount = hasBundle ? Self.expectedEventCount : 0
        if hasBundle && hasPlugin && hasHelper && !hasLegacyRow {
            connection.status = .installed
            if DshBridge.updateAvailable(environment) {
                connection.pluginUpdateAvailable = true
                connection.message = "组合包有新版本，点「更新插件」刷新；更新后请完全退出并重启 DeepSeek Harness。"
            } else {
                connection.message = "已作为 dsh 组合包安装，可在 DeepSeek Harness 的「插件 → 已安装插件」里看到并开关；请完全退出并重启 DeepSeek Harness，再开启新会话验证。插件只上报活动，权限请求仍在来源处理。"
            }
        } else if hasPlugin && hasHelper && !hasBundle && !hasLegacyRow {
            connection.status = .notInstalled
            connection.message = "组合包已安装，但在 DeepSeek Harness 中未启用。点「修复插件接入」重新启用，或到 dsh 的插件页开启它。"
        } else if hasBundle || hasPlugin || hasLegacyRow {
            connection.status = .needsRepair
            let missing = [
                hasBundle ? nil : "组合包启用",
                hasPlugin ? nil : "组合包依赖",
                hasHelper ? nil : "helper",
                hasLegacyRow ? "旧版 loader 行需要清理" : nil
            ].compactMap { $0 }.joined(separator: "、")
            connection.message = "发现不完整的接入：缺少\(missing)。请点「修复插件接入」。"
        } else {
            connection.status = detection.isDetected ? .notInstalled : .notDetected
            connection.message = detection.isDetected
                ? "已检测到 DeepSeek Harness。点「一键安装插件」即可安装灵宠岛 dsh 组合包（随应用分发，离线可用，会出现在 dsh 的已安装插件里）。"
                : "未找到 DeepSeek Harness 桌面应用；仍可安装。"
        }
        return connection
    }

    public func prepare() async throws -> HookInstallationPlan {
        guard DshBridge.profileExists(environment) else {
            throw ConnectionError.io("未找到 DeepSeek Harness 的 desktop profile；请先启动一次应用。")
        }
        let detection = await ProviderDetector.detect(provider: .dsh, environment: environment)
        guard let cliURL = DshBridge.cliURL(appURL: detection.appURL) else {
            throw ConnectionError.io("未找到 DeepSeek Harness 自带的 dsh CLI，无法登记组合包。请确认应用安装完整。")
        }
        guard let helperSource = environment.helperSourceURL,
              FileManager.default.isExecutableFile(atPath: helperSource.path) else {
            throw ConnectionError.helperUnavailable(environment.helperSourceURL?.path ?? "lingchongdao-hook")
        }
        guard let pluginSource = environment.dshPluginSourceURL, try pluginIsComplete(pluginSource) else {
            throw ConnectionError.io("当前构建未包含完整的 dsh 组合包（Contents/Resources/DshPlugin）。请使用完整应用。")
        }
        let helperDigest = ConnectionFileStore.digest(try Data(contentsOf: helperSource))
        let pluginDigest = try pluginDigest(pluginSource)
        let patchOriginal = try ConnectionFileStore.readOptional(environment.dshPatchURL)
        let manifestOriginal = try ConnectionFileStore.readOptional(environment.dshProfileURL.appendingPathComponent("package.json"))
        let plan = HookInstallationPlan(
            id: UUID(), provider: .dsh, displayName: HookConnectionService.name(.dsh),
            configurationURL: environment.dshProfileURL.appendingPathComponent("package.json"),
            helperURL: environment.installedHelperURL, sourceHelperURL: helperSource, socketPath: environment.socketPath,
            hookPreview: DshBridge.preview(),
            hookLabels: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop"]
                .compactMap { HookStatusMessages.message(for: $0) ?? $0 },
            summary: "把灵宠岛自带的 dsh 组合包复制到 \(environment.dshPluginInstallURL.path)，用应用自带 dsh 以离线方式登记到 desktop profile，并把 \(DshBridge.pluginPackage) 追加到 dsh.profile.bundles。之后它会出现在 DeepSeek Harness 的「插件 → 已安装插件」里，可自行开关。helper 复制到固定位置；profile 文件写入前会备份。",
            reviewInstructions: "安装不依赖任何第三方 Hook 桥接包。完成后请完全退出并重启 DeepSeek Harness，再开启新会话验证；插件只上报活动，不参与模型决策，权限请求仍在来源处理。断开连接会取消启用，但保留组合包依赖，便于随时重连。",
            documentationURL: URL(string: "https://github.com/deepseek-ai/deepseek-harness")!,
            createsConfiguration: patchOriginal == nil, preparedAt: Date())
        prepared = Prepared(plan: plan, patchOriginal: patchOriginal, profileManifestOriginal: manifestOriginal,
                            helperSource: helperSource, pluginSource: pluginSource,
                            helperDigest: helperDigest, pluginDigest: pluginDigest, cliURL: cliURL)
        return plan
    }

    public func install() async throws {
        guard let record = prepared else { throw ConnectionError.reviewRequired }
        let manifestURL = environment.dshProfileURL.appendingPathComponent("package.json")
        guard try ConnectionFileStore.readOptional(environment.dshPatchURL) == record.patchOriginal,
              try ConnectionFileStore.readOptional(manifestURL) == record.profileManifestOriginal else {
            throw ConnectionError.configurationChanged
        }
        guard try ConnectionFileStore.digest(Data(contentsOf: record.helperSource)) == record.helperDigest,
              try pluginDigest(record.pluginSource) == record.pluginDigest else { throw ConnectionError.helperChanged }
        let manifestData = try ConnectionFileStore.readOptional(environment.manifestURL)
        var manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        try installHelper(record: record, manifest: manifest)
        try installPlugin(from: record.pluginSource)
        let pluginDirectory = environment.dshPluginInstallURL
        _ = try await Task.detached(priority: .userInitiated) {
            try DshBridge.addLocalPlugin(cliURL: record.cliURL, pluginDirectory: pluginDirectory)
        }.value
        guard DshBridge.pluginInstalled(environment) else {
            throw ConnectionError.io("组合包登记后仍未解析到 desktop profile，请在 DeepSeek Harness 中检查插件管理。")
        }
        try DshBridge.setBundleSelected(true, in: environment)
        _ = try DshBridge.removeLegacyRow(in: environment)
        manifest.helperSHA256 = record.helperDigest
        try writeManifest(manifest, expected: manifestData)
        prepared = nil
    }

    /// Disabling keeps the dependency and the copied bundle so reconnecting is one
    /// click; the harness' own plugin page can remove it entirely.
    public func remove() throws {
        try DshBridge.setBundleSelected(false, in: environment)
        _ = try DshBridge.removeLegacyRow(in: environment)
        prepared = nil
    }

    /// The plugin-card install: snapshot and apply in one step, like the Codex card.
    public func installDirectly() async throws {
        _ = try await prepare()
        try await install()
    }

    /// Plugin-card uninstall: stop loading it first, then remove the profile
    /// dependency and the copied bundle. The shared helper stays for other sources.
    public func uninstall() async throws {
        let detection = await ProviderDetector.detect(provider: .dsh, environment: environment)
        guard let cliURL = DshBridge.cliURL(appURL: detection.appURL) else {
            throw ConnectionError.io("未找到 DeepSeek Harness 自带的 dsh CLI，无法卸载组合包。")
        }
        try DshBridge.setBundleSelected(false, in: environment)
        _ = try DshBridge.removeLegacyRow(in: environment)
        let packageName = DshBridge.pluginPackage
        _ = try await Task.detached(priority: .userInitiated) {
            try DshBridge.removeLocalPlugin(cliURL: cliURL, packageName: packageName)
        }.value
        try? FileManager.default.removeItem(at: environment.dshPluginInstallURL)
        prepared = nil
    }

    private func installHelper(record: Prepared, manifest: HookInstallationManifest) throws {
        let source = try Data(contentsOf: record.helperSource)
        let existing = try ConnectionFileStore.readOptional(environment.installedHelperURL)
        if let existing {
            let existingDigest = ConnectionFileStore.digest(existing)
            guard existingDigest == record.helperDigest || existingDigest == manifest.helperSHA256 else {
                throw ConnectionError.unownedHelper(environment.installedHelperURL.path)
            }
        }
        if existing != source {
            try ConnectionFileStore.writeAtomically(source, to: environment.installedHelperURL, expected: existing, newPermissions: 0o700)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: environment.installedHelperURL.path)
    }

    /// Only the bundle's runtime files are copied; stale extra files stay untouched.
    private func installPlugin(from source: URL) throws {
        let destination = environment.dshPluginInstallURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in DshBridge.pluginFiles {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            let target = destination.appendingPathComponent(name)
            let previous = try ConnectionFileStore.readOptional(target)
            if previous != data { try ConnectionFileStore.writeAtomically(data, to: target, expected: previous) }
        }
    }

    private func pluginIsComplete(_ source: URL) throws -> Bool {
        for name in DshBridge.pluginFiles {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
        }
        return true
    }

    private func pluginDigest(_ source: URL) throws -> String {
        var data = Data()
        for name in DshBridge.pluginFiles {
            data.append(Data(name.utf8))
            data.append(try Data(contentsOf: source.appendingPathComponent(name)))
        }
        return ConnectionFileStore.digest(data)
    }

    private func helperIsHealthy() -> Bool {
        let path = environment.installedHelperURL.path
        guard FileManager.default.isExecutableFile(atPath: path),
              let data = try? ConnectionFileStore.readOptional(environment.installedHelperURL),
              let digest = (try? ConnectionFileStore.readManifest(environment.manifestURL))?.helperSHA256 else { return false }
        return ConnectionFileStore.digest(data) == digest
    }

    private func writeManifest(_ manifest: HookInstallationManifest, expected: Data?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        try ConnectionFileStore.writeAtomically(data, to: environment.manifestURL, expected: expected)
    }
}
