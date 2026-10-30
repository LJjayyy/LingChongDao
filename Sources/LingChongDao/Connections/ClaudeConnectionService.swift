import Foundation
import IslandCore

public actor ClaudeConnectionService {
    public let environment: ConnectionEnvironment
    private struct Prepared {
        let plan: HookInstallationPlan
        let cli: URL
        let package: URL
        let packageDigest: String
        let helperDigest: String
    }
    private var prepared: Prepared?
    public init(environment: ConnectionEnvironment) { self.environment = environment }

    public func check() async -> ProviderConnection {
        let detection = await ProviderDetector.detect(provider: .claude, environment: environment)
        var connection = ProviderConnection(provider: .claude, displayName: "Claude Code", detection: detection,
            status: .notInstalled, capabilities: HookConnectionService.capabilities(.claude), message: "",
            hookPreview: Self.preview, installedHookCount: 0, expectedHookCount: 12, lastEventAt: nil)
        let installed = ClaudePluginBridge.installedRoot(environment)
        let enabled = ClaudePluginBridge.enabled(environment)
        connection.installedHookCount = installed == nil ? 0 : 12
        let hasUpdate = ClaudePluginBridge.updateAvailable(environment)
        if let installed, enabled, helperIsHealthy(),
           hasUpdate || PluginPackage.digest(files: ClaudePluginBridge.files, root: installed) != nil {
            connection.status = .installed
            connection.pluginUpdateAvailable = hasUpdate
            connection.message = connection.pluginUpdateAvailable
                ? "插件有新版本，点「更新插件」刷新，随后重启 Claude 并开启新会话。"
                : "插件已安装并启用。请重启 Claude 并开启新的本机会话验证；可在岛内批准一次或拒绝简单 Bash 和网页搜索；复杂操作与问题回复回 Claude 处理。"
        } else if installed != nil {
            connection.status = .needsRepair
            connection.message = "插件文件、启用状态或 helper 需要检查。点「修复插件接入」；若 Claude 全局禁用了 Hooks，请在 Claude 中自行调整。"
        } else {
            connection.status = detection.isDetected ? .notInstalled : .notDetected
            connection.message = detection.isDetected
                ? "支持本机 CLI、Claude App 的 Code 和 IDE。点「安装插件」安装到 Claude 用户范围；支持单次审批，复杂操作回来源核对。"
                : "未找到 Claude App 或 CLI。请先安装并启动一次 Claude Code。"
        }
        return connection
    }

    public func prepare() async throws -> HookInstallationPlan {
        let detection = await ProviderDetector.detect(provider: .claude, environment: environment)
        guard let cli = detection.cliURL else {
            throw ConnectionError.io("未找到 Claude Code CLI 或 Claude App 的本地引擎。请先在 Claude App 打开 Code 的本地会话，或安装 Claude Code CLI。")
        }
        guard let helper = environment.helperSourceURL, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConnectionError.helperUnavailable(environment.helperSourceURL?.path ?? "lingchongdao-hook")
        }
        guard let package = environment.claudePluginSourceURL,
              let root = ClaudePluginBridge.bundledRoot(environment),
              let digest = PluginPackage.digest(files: ClaudePluginBridge.files, root: root),
              (try? ConnectionFileStore.readOptional(package.appendingPathComponent(".claude-plugin/marketplace.json"))) != nil else {
            throw ConnectionError.io("当前构建未包含完整的 Claude 插件包，请使用完整应用。")
        }
        if let source = try ClaudePluginBridge.registeredSource(environment),
           URL(fileURLWithPath: source).standardizedFileURL != ClaudePluginBridge.packageRoot(environment).standardizedFileURL {
            throw ConnectionError.io("Claude 已有同名插件市场，已保留：\(source)")
        }
        let plan = HookInstallationPlan(id: UUID(), provider: .claude, displayName: "Claude Code",
            configurationURL: ClaudePluginBridge.packageRoot(environment), helperURL: environment.installedHelperURL,
            sourceHelperURL: helper, socketPath: environment.socketPath, hookPreview: Self.preview,
            hookLabels: ["权限请求", "会话开始", "用户提交", "工具开始与结果", "本轮停止与错误", "会话结束", "子任务", "通知"],
            summary: "安装灵宠岛本地插件市场，并通过 Claude 官方 CLI 在用户范围安装 \(ClaudePluginBridge.pluginID)。CLI、Claude App 的 Code 本地会话和本机 IDE 共用。",
            reviewInstructions: "安装后重启 Claude 并开启新会话。可在岛内单次批准完整展示的 Bash / 网页搜索，拒绝或返回 Claude。最多等待 90 秒，失联、退出或超时回来源处理；不修改长期权限规则。SSH、云端和容器不在本版范围。",
            documentationURL: URL(string: "https://code.claude.com/docs/en/plugins")!,
            createsConfiguration: ClaudePluginBridge.installedRoot(environment) == nil, preparedAt: Date())
        prepared = Prepared(plan: plan, cli: cli, package: package, packageDigest: digest,
                            helperDigest: ConnectionFileStore.digest(try Data(contentsOf: helper)))
        return plan
    }

    public func installDirectly() async throws {
        _ = try await prepare()
        try await install()
    }

    public func install() async throws {
        guard let record = prepared else { throw ConnectionError.reviewRequired }
        let root = record.package.appendingPathComponent("plugins/\(ClaudePluginBridge.pluginName)")
        guard PluginPackage.digest(files: ClaudePluginBridge.files, root: root) == record.packageDigest,
              ConnectionFileStore.digest(try Data(contentsOf: record.plan.sourceHelperURL)) == record.helperDigest else {
            throw ConnectionError.helperChanged
        }
        // Only replace a helper already managed by this application.
        let originalHelper = try ConnectionFileStore.readOptional(environment.installedHelperURL)
        var manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        if let originalHelper {
            let digest = ConnectionFileStore.digest(originalHelper)
            guard digest == record.helperDigest || digest == manifest.helperSHA256 else {
                throw ConnectionError.unownedHelper(environment.installedHelperURL.path)
            }
        }
        let helper = try Data(contentsOf: record.plan.sourceHelperURL)
        if helper != originalHelper {
            try ConnectionFileStore.writeAtomically(helper, to: environment.installedHelperURL, expected: originalHelper, newPermissions: 0o700)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: environment.installedHelperURL.path)
        // Record the shared helper immediately, even if the host CLI later fails.
        let originalManifest = try ConnectionFileStore.readOptional(environment.manifestURL)
        manifest.helperSHA256 = record.helperDigest
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ConnectionFileStore.writeAtomically(try encoder.encode(manifest), to: environment.manifestURL, expected: originalManifest)

        let destination = ClaudePluginBridge.packageRoot(environment)
        try ConnectionFileStore.validateExistingFile(destination.appendingPathComponent(".claude-plugin/marketplace.json"))
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".claude-stage-\(UUID().uuidString)")
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".claude-backup-\(UUID().uuidString)")
        try fm.copyItem(at: record.package, to: staging)
        let hadPackage = fm.fileExists(atPath: destination.path)
        var backedUp = false
        var replaced = false
        do {
            if hadPackage { try fm.moveItem(at: destination, to: backup); backedUp = true }
            try fm.moveItem(at: staging, to: destination)
            replaced = true
            let environment = self.environment
            try await Task.detached(priority: .userInitiated) {
                try ClaudePluginBridge.install(cli: record.cli, environment: environment)
            }.value
            guard let installed = ClaudePluginBridge.installedRoot(environment),
                  PluginPackage.digest(files: ClaudePluginBridge.files, root: installed) == record.packageDigest else {
                throw ConnectionError.io("Claude 尚未加载新版插件文件，请在 Claude 插件管理中检查后重试。")
            }
        } catch {
            if replaced { try? fm.removeItem(at: destination) }
            if backedUp { try? fm.moveItem(at: backup, to: destination) }
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: backup)
        prepared = nil
    }

    public func uninstall() async throws {
        let detection = await ProviderDetector.detect(provider: .claude, environment: environment)
        guard let cli = detection.cliURL else { throw ConnectionError.io("未找到 Claude Code CLI，无法卸载插件。") }
        let environment = self.environment
        try await Task.detached(priority: .userInitiated) {
            try ClaudePluginBridge.uninstall(cli: cli, environment: environment)
        }.value
        guard ClaudePluginBridge.installedRoot(environment) == nil else {
            throw ConnectionError.io("Claude 仍报告用户范围的插件已安装，请在插件管理中检查。")
        }
        prepared = nil
    }

    private func helperIsHealthy() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: environment.installedHelperURL.path),
              let data = try? ConnectionFileStore.readOptional(environment.installedHelperURL),
              let digest = (try? ConnectionFileStore.readManifest(environment.manifestURL))?.helperSHA256 else { return false }
        return ConnectionFileStore.digest(data) == digest
    }

    private static let preview = """
    # 灵宠岛 · Claude Code 用户级插件（12 项事件，含权限请求）
    .claude-plugin/marketplace.json
      └─ plugins/lingchongdao/.claude-plugin/plugin.json
           └─ hooks/hooks.json → scripts/forward-hook.sh
    # 本机 CLI / Claude App Code / IDE 共用；PermissionRequest 最多等待 90 秒
    # 完整预览的 Bash / 网页搜索可单次批准，复杂操作回 Claude；桥不可用时返回 {}
    """
}
