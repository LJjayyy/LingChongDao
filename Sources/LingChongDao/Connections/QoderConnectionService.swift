import Foundation
import IslandCore

/// Qoder CN connection: install 灵宠岛's own `.qoder-plugin` package through the
/// bundled `qoderclicn` CLI so it appears in Qoder's plugin management. The
/// pre-plugin command hooks in `settings.json` (and the 0.1.x `~/.qoder` copy)
/// are removed on install so events are never reported twice.
public actor QoderConnectionService {
    public let environment: ConnectionEnvironment
    private static let expectedEventCount = 12
    private let hooks: HookConnectionService

    private struct Prepared: Sendable {
        let plan: HookInstallationPlan
        let settingsOriginal: Data?
        let helperSource: URL
        let packageSource: URL
        let helperDigest: String
        let packageDigest: String
        let cliURL: URL
    }
    private var prepared: Prepared?

    public init(environment: ConnectionEnvironment) {
        self.environment = environment
        self.hooks = HookConnectionService(environment: environment)
    }

    public func check() async -> ProviderConnection {
        let detection = await ProviderDetector.detect(provider: .qoder, environment: environment)
        var connection = ProviderConnection(provider: .qoder, displayName: HookConnectionService.name(.qoder), detection: detection,
                                            status: .notDetected, capabilities: HookConnectionService.capabilities(.qoder),
                                            message: "", hookPreview: "", installedHookCount: 0,
                                            expectedHookCount: Self.expectedEventCount, lastEventAt: nil)
        let active = QoderPluginBridge.isActive(environment)
        let installed = QoderPluginBridge.pluginInstalled(environment)
        let hasHelper = helperIsHealthy()
        let legacy = await hasLegacyHooks()
        connection.installedHookCount = (active || legacy) ? Self.expectedEventCount : 0
        connection.hookPreview = Self.preview()
        if active && hasHelper && !legacy {
            connection.status = .installed
            if QoderPluginBridge.updateAvailable(environment) {
                connection.pluginUpdateAvailable = true
                connection.message = "插件有新版本，点「更新插件」刷新；完成后请重启 Qoder，再开启新会话。"
            } else {
                connection.message = "插件已安装并启用，同步任务与等待权限状态；权限确认请在 Qoder 处理。安装更新后请重启 Qoder，再开启新会话验证。"
            }
        } else if active || installed || legacy {
            connection.status = .needsRepair
            let missing = [
                installed ? nil : "插件安装",
                active ? nil : "插件启用",
                hasHelper ? nil : "helper",
                legacy ? "旧版配置 Hook 需要清理" : nil
            ].compactMap { $0 }.joined(separator: "、")
            connection.message = "发现不完整的接入：缺少\(missing)。请点「修复插件接入」。"
        } else {
            connection.status = detection.isDetected ? .notInstalled : .notDetected
            connection.message = detection.isDetected
                ? "已检测到 Qoder。点「一键安装插件」即可安装灵宠岛 Qoder 插件（本地插件包，离线可用，会出现在 Qoder 的插件管理里）。"
                : "未找到 Qoder CN 桌面应用；仍可安装。"
        }
        return connection
    }

    public func prepare() async throws -> HookInstallationPlan {
        guard let cliURL = QoderPluginBridge.cliURL(environment) else {
            throw ConnectionError.io("未找到 Qoder 自带的 qoderclicn，无法安装插件。请先启动一次 Qoder。")
        }
        guard let helperSource = environment.helperSourceURL,
              FileManager.default.isExecutableFile(atPath: helperSource.path) else {
            throw ConnectionError.helperUnavailable(environment.helperSourceURL?.path ?? "lingchongdao-hook")
        }
        guard let packageSource = environment.qoderPluginSourceURL, try packageIsComplete(packageSource) else {
            throw ConnectionError.io("当前构建未包含完整的 Qoder 插件包（Contents/Resources/QoderPlugin）。请使用完整应用。")
        }
        let helperDigest = ConnectionFileStore.digest(try Data(contentsOf: helperSource))
        let packageDigest = try packageDigest(packageSource)
        let settingsOriginal = try ConnectionFileStore.readOptional(environment.configurationURL(for: .qoder))
        let plan = HookInstallationPlan(
            id: UUID(), provider: .qoder, displayName: HookConnectionService.name(.qoder),
            configurationURL: QoderPluginBridge.packageRoot(environment),
            helperURL: environment.installedHelperURL, sourceHelperURL: helperSource, socketPath: environment.socketPath,
            hookPreview: Self.preview(),
            hookLabels: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
                         "Stop", "SessionEnd", "SubagentStart", "SubagentStop", "Notification", "StopFailure"]
                .compactMap { HookStatusMessages.message(for: $0) ?? $0 },
            summary: "把 Qoder 插件包复制到 \(QoderPluginBridge.packageRoot(environment).path)，用 Qoder 自带的 qoderclicn 以本地目录方式安装（\(QoderPluginBridge.pluginID)），并清理旧版写进 settings.json 的灵宠岛命令。插件可在 Qoder 的插件管理中开关或卸载。",
            reviewInstructions: "安装不依赖网络。完成后请重启 Qoder（CN 桌面端与 IDE 共用这份插件），再开启新会话验证；插件以包内脚本调用 \(environment.installedHelperURL.lastPathComponent)，灵宠岛未运行时交回 Qoder 正常处理。",
            documentationURL: URL(string: "https://docs.qoder.cn/qoder/hooks")!,
            createsConfiguration: !QoderPluginBridge.pluginInstalled(environment), preparedAt: Date())
        prepared = Prepared(plan: plan, settingsOriginal: settingsOriginal, helperSource: helperSource, packageSource: packageSource,
                            helperDigest: helperDigest, packageDigest: packageDigest, cliURL: cliURL)
        return plan
    }

    public func install() async throws {
        guard let record = prepared else { throw ConnectionError.reviewRequired }
        let settingsURL = environment.configurationURL(for: .qoder)
        guard try ConnectionFileStore.readOptional(settingsURL) == record.settingsOriginal else {
            throw ConnectionError.configurationChanged
        }
        guard try ConnectionFileStore.digest(Data(contentsOf: record.helperSource)) == record.helperDigest,
              try packageDigest(record.packageSource) == record.packageDigest else { throw ConnectionError.helperChanged }
        try installHelper(record: record)
        try QoderPluginBridge.installPackage(from: record.packageSource, to: QoderPluginBridge.packageRoot(environment))
        let directory = QoderPluginBridge.packageRoot(environment)
        _ = try await Task.detached(priority: .userInitiated) {
            try QoderPluginBridge.installLocalPlugin(cliURL: record.cliURL, directory: directory)
        }.value
        guard QoderPluginBridge.isActive(environment) else {
            throw ConnectionError.io("插件安装后未出现在 Qoder 插件列表，请在 Qoder 的插件管理中检查。")
        }
        try QoderPluginBridge.tagInstalledIcon(environment)
        try await removeLegacyHooks()
        var manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        let manifestData = try ConnectionFileStore.readOptional(environment.manifestURL)
        manifest.helperSHA256 = record.helperDigest
        try writeManifest(manifest, expected: manifestData)
        prepared = nil
    }

    public func installDirectly() async throws {
        _ = try await prepare()
        try await install()
    }

    public func uninstall() async throws {
        guard let cliURL = QoderPluginBridge.cliURL(environment) else {
            throw ConnectionError.io("未找到 Qoder 自带的 qoderclicn，无法卸载插件。")
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try QoderPluginBridge.uninstall(cliURL: cliURL)
        }.value
        QoderPluginBridge.removePackage(environment)
        try await removeLegacyHooks()
        prepared = nil
    }

    public func remove() async throws {
        try await uninstall()
    }

    /// Covers both the CN settings file and the 0.1.x `~/.qoder/settings.json` copy.
    private func hasLegacyHooks() async -> Bool {
        if (try? await hooks.hasOwnedHooks(provider: .qoder)) == true { return true }
        let legacy = environment.homeDirectoryURL.appendingPathComponent(".qoder/settings.json")
        guard let data = try? Data(contentsOf: legacy), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("lingchongdao-managed:v1:qoder") || text.contains("ai-island-managed:v1:qoder")
    }

    private func removeLegacyHooks() async throws {
        try await hooks.remove(provider: .qoder)
    }

    private func installHelper(record: Prepared) throws {
        let source = try Data(contentsOf: record.helperSource)
        let existing = try ConnectionFileStore.readOptional(environment.installedHelperURL)
        if let existing {
            let manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
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

    private func packageFiles() -> [String] {
        [
            ".qoder-plugin/plugin.json",
            ".qoder-plugin/qoder-hooks.json",
            "scripts/forward-hook.sh",
            "assets/icon.png"
        ]
    }

    private func packageIsComplete(_ source: URL) throws -> Bool {
        for name in packageFiles() {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
        }
        return true
    }

    private func packageDigest(_ source: URL) throws -> String {
        var data = Data()
        for name in packageFiles() {
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

    private static func preview() -> String {
        """
        # Qoder 插件：\(QoderPluginBridge.pluginName)
        .qoder-plugin/plugin.json      （displayName / description / logo）
          └─ .qoder-plugin/qoder-hooks.json   （12 个事件）
               └─ scripts/forward-hook.sh     （灵宠岛未运行时返回 {}）
        # 安装方式：qoderclicn plugins install <目录> -s user
        # 旧版写入 settings.json 的灵宠岛命令会被清理，避免重复上报
        """
    }
}
