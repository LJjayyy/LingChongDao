import Foundation
import IslandCore

/// ZCode connection: install 灵宠岛's own plugin marketplace through ZCode's
/// bundled CLI, so the integration is a native ZCode plugin that appears in
/// Plugin Management. The pre-plugin command hooks are removed on install.
public actor ZcodeConnectionService {
    public let environment: ConnectionEnvironment
    private static let expectedEventCount = 7
    private let hooks: HookConnectionService

    private struct Prepared: Sendable {
        let plan: HookInstallationPlan
        let configOriginal: Data?
        let helperSource: URL
        let packageSource: URL
        let helperDigest: String
        let packageDigest: String
        let appURL: URL
    }
    private var prepared: Prepared?

    public init(environment: ConnectionEnvironment) {
        self.environment = environment
        self.hooks = HookConnectionService(environment: environment)
    }

    public func check() async -> ProviderConnection {
        let detection = await ProviderDetector.detect(provider: .zcode, environment: environment)
        var connection = ProviderConnection(provider: .zcode, displayName: HookConnectionService.name(.zcode), detection: detection,
                                            status: .notDetected, capabilities: HookConnectionService.capabilities(.zcode),
                                            message: "", hookPreview: "", installedHookCount: 0,
                                            expectedHookCount: Self.expectedEventCount, lastEventAt: nil)
        let active = ZcodePluginBridge.isActive(environment)
        let installed = ZcodePluginBridge.pluginInstalled(environment)
        let hasHelper = helperIsHealthy()
        let legacy = (try? await hooks.hasOwnedHooks(provider: .zcode)) ?? false
        // Active plugins and pre-plugin command hooks both count as a configured
        // connection, so the card offers repair/uninstall during migration.
        connection.installedHookCount = (active || legacy) ? Self.expectedEventCount : 0
        connection.hookPreview = Self.preview()
        if active && hasHelper && !legacy {
            connection.status = .installed
            if ZcodePluginBridge.updateAvailable(environment) {
                connection.pluginUpdateAvailable = true
                connection.message = "插件有新版本，点「更新插件」刷新；完成后请重启 ZCode，再开启新会话。"
            } else {
                connection.message = "插件已安装并启用，可在 ZCode 的「插件管理 → 已安装」里看到并开关；刚安装请重启 ZCode，再开启新会话验证。简单 Bash 权限可在岛内处理；守护模式下安全规则的危险命令确认只在 ZCode 内出现（来源不对此触发 Hook）。"
            }
        } else if active || installed || ZcodePluginBridge.marketplaceInstalled(environment) {
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
                ? "已检测到 ZCode。点「一键安装插件」即可安装灵宠岛 ZCode 插件（本地插件市场，离线可用，会出现在 ZCode 的插件管理里）。"
                : "未找到 ZCode 桌面应用；仍可安装。"
        }
        return connection
    }

    public func prepare() async throws -> HookInstallationPlan {
        let detection = await ProviderDetector.detect(provider: .zcode, environment: environment)
        guard let appURL = detection.appURL, ZcodePluginBridge.cli(appURL) != nil else {
            throw ConnectionError.io("未找到 ZCode 自带的插件 CLI，无法安装插件。请确认应用安装完整。")
        }
        guard let helperSource = environment.helperSourceURL,
              FileManager.default.isExecutableFile(atPath: helperSource.path) else {
            throw ConnectionError.helperUnavailable(environment.helperSourceURL?.path ?? "lingchongdao-hook")
        }
        guard let packageSource = environment.zcodePluginSourceURL, try packageIsComplete(packageSource) else {
            throw ConnectionError.io("当前构建未包含完整的 ZCode 插件包（Contents/Resources/ZcodePlugin）。请使用完整应用。")
        }
        let helperDigest = ConnectionFileStore.digest(try Data(contentsOf: helperSource))
        let packageDigest = try packageDigest(packageSource)
        let configOriginal = try ConnectionFileStore.readOptional(environment.zcodeHomeURL.appendingPathComponent("cli/config.json"))
        let plan = HookInstallationPlan(
            id: UUID(), provider: .zcode, displayName: HookConnectionService.name(.zcode),
            configurationURL: ZcodePluginBridge.packageRoot(environment),
            helperURL: environment.installedHelperURL, sourceHelperURL: helperSource, socketPath: environment.socketPath,
            hookPreview: Self.preview(),
            hookLabels: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"]
                .compactMap { HookStatusMessages.message(for: $0) ?? $0 },
            summary: "把 ZCode 插件市场复制到 \(ZcodePluginBridge.packageRoot(environment).path)，用 ZCode 自带 CLI 把它注册为本地插件市场并安装 \(ZcodePluginBridge.pluginID)；同时清理旧版写进 cli/config.json 的灵宠岛命令，避免重复上报。插件位于 ZCode 的「插件管理 → 已安装」，可自行开关或卸载。",
            reviewInstructions: "安装不依赖网络。完成后请完全退出并重启 ZCode，再开启新会话验证；插件以包内脚本调用 \(environment.installedHelperURL.lastPathComponent)，灵宠岛未运行时交回 ZCode 正常处理。",
            documentationURL: URL(string: "https://zcode.z.ai/cn/docs/hooks")!,
            createsConfiguration: !ZcodePluginBridge.marketplaceInstalled(environment), preparedAt: Date())
        prepared = Prepared(plan: plan, configOriginal: configOriginal, helperSource: helperSource, packageSource: packageSource,
                            helperDigest: helperDigest, packageDigest: packageDigest, appURL: appURL)
        return plan
    }

    public func install() async throws {
        guard let record = prepared else { throw ConnectionError.reviewRequired }
        let configURL = environment.zcodeHomeURL.appendingPathComponent("cli/config.json")
        guard try ConnectionFileStore.readOptional(configURL) == record.configOriginal else {
            throw ConnectionError.configurationChanged
        }
        guard try ConnectionFileStore.digest(Data(contentsOf: record.helperSource)) == record.helperDigest,
              try packageDigest(record.packageSource) == record.packageDigest else { throw ConnectionError.helperChanged }
        try installHelper(record: record)
        try ZcodePluginBridge.installPackage(from: record.packageSource, to: ZcodePluginBridge.packageRoot(environment))
        _ = try await Task.detached(priority: .userInitiated) {
            try ZcodePluginBridge.installMarketplace(appURL: record.appURL, directory: ZcodePluginBridge.packageRoot(self.environment))
        }.value
        guard ZcodePluginBridge.isActive(environment) else {
            throw ConnectionError.io("插件安装后未出现在 ZCode 插件列表，请在 ZCode 的插件管理中检查。")
        }
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
        let detection = await ProviderDetector.detect(provider: .zcode, environment: environment)
        guard let appURL = detection.appURL else {
            throw ConnectionError.io("未找到 ZCode 桌面应用，无法卸载插件。")
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try ZcodePluginBridge.uninstall(appURL: appURL)
        }.value
        ZcodePluginBridge.removePackage(environment)
        try await removeLegacyHooks()
        prepared = nil
    }

    /// Legacy generic removal path (ConnectionManager.remove) uninstalls the plugin.
    public func remove() async throws {
        try await uninstall()
    }

    private func removeLegacyHooks() async throws {
        guard try await hooks.hasOwnedHooks(provider: .zcode) else { return }
        try await hooks.remove(provider: .zcode)
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
            "marketplace.json",
            "plugins/\(ZcodePluginBridge.pluginName)/.zcode-plugin/plugin.json",
            "plugins/\(ZcodePluginBridge.pluginName)/hooks/hooks.json",
            "plugins/\(ZcodePluginBridge.pluginName)/scripts/forward-hook.sh",
            "plugins/\(ZcodePluginBridge.pluginName)/icon.png"
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
        # 本地插件市场：\(ZcodePluginBridge.marketplaceName)
        marketplace.json
          └─ plugins/\(ZcodePluginBridge.pluginName)
               ├─ .zcode-plugin/plugin.json   （hooks → hooks/hooks.json）
               ├─ hooks/hooks.json            （7 个事件，脚本调用灵宠岛 helper）
               └─ scripts/forward-hook.sh     （灵宠岛未运行时返回 {}）
        # 安装方式：ZCode 自带 CLI → plugins marketplace add + plugins install
        # 旧版写入 cli/config.json 的灵宠岛命令会被清理，避免重复上报
        """
    }
}
