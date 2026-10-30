import Combine
import Foundation
import IslandCore

public actor HookConnectionService {
    private struct PreparedRecord: Sendable {
        let plan: HookInstallationPlan
        let originalConfiguration: Data?
        let mergedConfiguration: Data
        let originalManifest: Data?
        let helperDigest: String
        let legacyConfiguration: LegacyConfiguration?
        let hooksEnabledState: HooksEnabledState?
    }

    private struct LegacyConfiguration: Sendable {
        let url: URL
        let original: Data
        let cleaned: Data
    }

    public let environment: ConnectionEnvironment
    private var prepared: [ProviderID: PreparedRecord] = [:]

    public init(environment: ConnectionEnvironment) { self.environment = environment }

    public func check(provider: ProviderID) async -> ProviderConnection {
        let detection = await ProviderDetector.detect(provider: provider, environment: environment)
        var connection = ProviderConnection(provider: provider, displayName: Self.name(provider), detection: detection,
                                            status: .notInstalled, capabilities: Self.capabilities(provider),
                                            message: "尚未安装灵宠岛 Hook。", hookPreview: "", installedHookCount: 0, expectedHookCount: 0, lastEventAt: nil)
        do {
            let definitions = try definitions(provider)
            connection.expectedHookCount = definitions.count
            connection.hookPreview = try HookConfigurationEditor.preview(definitions: definitions, provider: provider)
            let original = try ConnectionFileStore.readOptional(detection.configurationURL)
            let manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
            let inspection = try HookConfigurationEditor.inspect(provider: provider, existing: original, definitions: definitions, recognizedCommands: recognizedCommands(provider, manifest: manifest, definitions: definitions), path: detection.configurationURL.path)
            connection.installedHookCount = inspection.ownedHookCount
            if let legacy = try legacyConfiguration(provider: provider, manifest: manifest, definitions: definitions) {
                connection.status = .needsRepair
                connection.message = "发现旧版本误装在 \(legacy.url.path) 的灵宠岛 Hook。Qoder CN 实际读取 \(detection.configurationURL.path)，请预览并迁移连接。"
            } else if inspection.ownedHookCount == 0 {
                connection.status = detection.isDetected ? .notInstalled : .notDetected
                connection.message = detection.isDetected ? "已检测到 \(Self.name(provider))。预览配置后可安装连接。" : (provider == .codebuddy || provider == .workbuddy ? "未找到 \(Self.name(provider)) 桌面应用；仍可预览连接配置。" : "未找到桌面应用或 CLI；仍可预览连接配置。")
            } else if !inspection.isComplete {
                connection.status = .needsRepair
                connection.message = inspection.ownedHookCount == definitions.count
                    ? "已找到全部灵宠岛 Hook，但名称或配置版本需要更新。预览修复后，每项会显示明确的用途。"
                    : "找到 \(inspection.ownedHookCount) 条灵宠岛 Hook，预期 \(definitions.count) 条。请预览修复配置。"
            } else if HookConfigurationEditor.configurationHooksDisabled(existing: original, provider: provider) {
                connection.status = .needsRepair
                connection.message = "Hook 已写入，但 \(detection.configurationURL.path) 的 hooks.enabled 为 false，ZCode 不会执行这些命令。请预览修复并开启配置 Hook。"
            } else if !(try helperIsHealthy(manifest)) {
                connection.status = .needsRepair
                connection.message = "Hook 配置存在，但固定位置的 helper 缺失、不可执行或与安装记录不符。"
            } else {
                connection.status = provider == .codex ? .needsReview : .installed
                connection.message = provider == .codex
                    ? "配置已安装；请回到 Codex 的“审查钩子”（CLI 可用 /hooks）确认本次定义，再用新任务验证。未读取或修改 Codex 信任状态。"
                    : "配置已安装；请在 \(Self.name(provider)) 中检查 Hook 设置，再开启新会话验证。配置存在不等于 Runtime 已加载。"
            }
        } catch {
            connection.status = .configurationError
            connection.message = error.localizedDescription
        }
        return connection
    }

    public func prepare(provider: ProviderID) throws -> HookInstallationPlan {
        let definitions = try definitions(provider)
        let configurationURL = environment.configurationURL(for: provider)
        let original = try ConnectionFileStore.readOptional(configurationURL)
        let originalManifest = try ConnectionFileStore.readOptional(environment.manifestURL)
        let manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        let legacy = try legacyConfiguration(provider: provider, manifest: manifest, definitions: definitions)
        let merged = try HookConfigurationEditor.install(provider: provider, existing: original, definitions: definitions,
                                                         recognizedCommands: recognizedCommands(provider, manifest: manifest, definitions: definitions), path: configurationURL.path)
        guard let source = environment.helperSourceURL, FileManager.default.isExecutableFile(atPath: source.path) else {
            throw ConnectionError.helperUnavailable(environment.helperSourceURL?.path ?? "lingchongdao-hook")
        }
        let sourceData = try Data(contentsOf: source)
        let helperDigest = ConnectionFileStore.digest(sourceData)
        try validateHelperReplacement(sourceDigest: helperDigest, manifest: manifest)
        let instructions: String
        if provider == .codex {
            instructions = "安装不会自动信任 Hook。请回到 Codex 的“审查钩子”（CLI 可用 /hooks），检查来源、完整命令与权限，再确认灵宠岛的当前定义；定义改变后需要重新审阅。若存在 inline TOML Hooks，Codex 会同时加载两者并提示。请新建低风险任务验证。现存桌面会话是否加载这组 Hooks 以实际事件为准。"
        } else if provider == .qoder {
            instructions = "Qoder CN 与 Qoder CN IDE 可共用当前 Hook 配置。请在来源设置中刷新并检查灵宠岛命令，再发起低风险新任务验证；消息会按识别到的实际应用分开显示。现有项目级 Hook 会继续合并生效。"
        } else if provider == .zcode {
            instructions = "ZCode 默认不加载配置文件中的 Hook，安装会把 \(configurationURL.path) 的 hooks.enabled 设为 true，并写入 7 个用户级事件。ZCode 在会话启动时读取一份配置快照，请新建会话验证；项目级 Hook 当前不会执行。岛内仅处理简单 Bash 权限请求，其余操作请回 ZCode 处理。"
        } else {
            instructions = "只同步任务与工具进展，权限与问题回来源应用处理。保留现有配置与 Hook，覆盖前自动备份。安装后开启新会话生效。"
        }
        let migrationSummary = legacy.map { "同时将旧路径 \($0.url.path) 中仅属于灵宠岛的 Hook 移除；旧文件同样备份，其他设置保留。" } ?? ""
        let plan = HookInstallationPlan(id: UUID(), provider: provider, displayName: Self.name(provider), configurationURL: configurationURL,
                                        helperURL: environment.installedHelperURL, sourceHelperURL: source, socketPath: environment.socketPath,
                                        hookPreview: try HookConfigurationEditor.preview(definitions: definitions, provider: provider),
                                        hookLabels: definitions.map { $0.statusMessage ?? HookStatusMessages.message(for: $0.event) ?? $0.event },
                                        hookShortLabels: definitions.map { HookStatusMessages.shortLabel(for: $0.event) },
                                        summary: "写入 \(definitions.count) 条灵宠岛 Hook；保留现有设置与 Hook，覆盖前在同目录备份。helper 复制到固定位置，应用移动后配置仍有效。" + migrationSummary,
                                        reviewInstructions: instructions,
                                        documentationURL: Self.documentationURL(provider),
                                        createsConfiguration: original == nil, preparedAt: Date())
        prepared[provider] = PreparedRecord(plan: plan, originalConfiguration: original, mergedConfiguration: merged,
                                             originalManifest: originalManifest, helperDigest: helperDigest, legacyConfiguration: legacy,
                                             hooksEnabledState: HookConfigurationEditor.hooksEnabledState(existing: original, provider: provider))
        return plan
    }

    /// Must follow prepare(): the file and helper are compared with the reviewed snapshot.
    public func install(provider: ProviderID) throws {
        guard let record = prepared[provider] else { throw ConnectionError.reviewRequired }
        guard try ConnectionFileStore.readOptional(record.plan.configurationURL) == record.originalConfiguration,
              try ConnectionFileStore.readOptional(environment.manifestURL) == record.originalManifest else { throw ConnectionError.configurationChanged }
        if let legacy = record.legacyConfiguration {
            guard try ConnectionFileStore.readOptional(legacy.url) == legacy.original else { throw ConnectionError.configurationChanged }
        }
        let helper = try Data(contentsOf: record.plan.sourceHelperURL)
        guard ConnectionFileStore.digest(helper) == record.helperDigest else { throw ConnectionError.helperChanged }
        var manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        try validateHelperReplacement(sourceDigest: record.helperDigest, manifest: manifest)
        let existingHelper = try ConnectionFileStore.readOptional(environment.installedHelperURL)
        if existingHelper != helper {
            try ConnectionFileStore.writeAtomically(helper, to: environment.installedHelperURL, expected: existingHelper, newPermissions: 0o700)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: environment.installedHelperURL.path)
        manifest.helperSHA256 = record.helperDigest
        // Keep known historical commands so a partial migration can be retried safely.
        manifest.ownedCommands[provider.rawValue] = recognizedCommands(provider, manifest: manifest, definitions: try definitions(provider)).sorted()
        if let state = record.hooksEnabledState {
            var states = manifest.hooksEnabledStates ?? [:]
            states[provider.rawValue] = state
            manifest.hooksEnabledStates = states
        }
        try writeManifest(manifest, expected: record.originalManifest)
        try ConnectionFileStore.writeAtomically(record.mergedConfiguration, to: record.plan.configurationURL, expected: record.originalConfiguration)
        if let legacy = record.legacyConfiguration {
            try ConnectionFileStore.writeAtomically(legacy.cleaned, to: legacy.url, expected: legacy.original)
        }
        prepared.removeValue(forKey: provider)
    }

    /// Pre-plugin installs wrote command hooks into the provider's own config. The
    /// plugin path must clear them so an event is never reported twice.
    public func hasOwnedHooks(provider: ProviderID) throws -> Bool {
        let definitions = try definitions(provider)
        let manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        let url = environment.configurationURL(for: provider)
        let inspection = try HookConfigurationEditor.inspect(provider: provider, existing: try ConnectionFileStore.readOptional(url),
                                                            definitions: definitions,
                                                            recognizedCommands: recognizedCommands(provider, manifest: manifest, definitions: definitions),
                                                            path: url.path)
        return inspection.ownedHookCount > 0
    }

    public func remove(provider: ProviderID) throws {
        let definitions = try definitions(provider)
        let configurationURL = environment.configurationURL(for: provider)
        let original = try ConnectionFileStore.readOptional(configurationURL)
        let manifestData = try ConnectionFileStore.readOptional(environment.manifestURL)
        var manifest = try ConnectionFileStore.readManifest(environment.manifestURL)
        let commands = recognizedCommands(provider, manifest: manifest, definitions: definitions)
        let restoreHooksEnabled = manifest.hooksEnabledStates?[provider.rawValue]
        if let updated = try HookConfigurationEditor.remove(provider: provider, existing: original, recognizedCommands: commands,
                                                           restoreHooksEnabled: restoreHooksEnabled, path: configurationURL.path) {
            try ConnectionFileStore.writeAtomically(updated, to: configurationURL, expected: original)
        }
        if let legacy = try legacyConfiguration(provider: provider, manifest: manifest, definitions: definitions) {
            try ConnectionFileStore.writeAtomically(legacy.cleaned, to: legacy.url, expected: legacy.original)
        }
        var manifestChanged = false
        if manifest.ownedCommands.removeValue(forKey: provider.rawValue) != nil { manifestChanged = true }
        if var states = manifest.hooksEnabledStates, states.removeValue(forKey: provider.rawValue) != nil {
            manifest.hooksEnabledStates = states.isEmpty ? nil : states
            manifestChanged = true
        }
        if manifestChanged { try writeManifest(manifest, expected: manifestData) }
        // Retain the helper: another project-local hook may refer to the same fixed executable.
        prepared.removeValue(forKey: provider)
    }

    /// Only remove exact commands managed by 灵宠岛; Qoder IDE settings remain intact.
    private func legacyConfiguration(provider: ProviderID, manifest: HookInstallationManifest, definitions: [ManagedHookDefinition]) throws -> LegacyConfiguration? {
        guard provider == .qoder else { return nil }
        let url = environment.homeDirectoryURL.appendingPathComponent(".qoder/settings.json")
        guard url.path != environment.configurationURL(for: provider).path,
              let original = try ConnectionFileStore.readOptional(url),
              ["lingchongdao-managed:v1:qoder", "ai-island-managed:v1:qoder"].contains(where: String(decoding: original, as: UTF8.self).contains),
              let cleaned = try HookConfigurationEditor.remove(provider: .qoder, existing: original,
                  recognizedCommands: recognizedCommands(provider, manifest: manifest, definitions: definitions), path: url.path) else { return nil }
        return LegacyConfiguration(url: url, original: original, cleaned: cleaned)
    }

    private func definitions(_ provider: ProviderID) throws -> [ManagedHookDefinition] {
        if provider == .qoder, let reason = environment.qoderConfigurationError { throw ConnectionError.io(reason) }
        return try HookConfigurationEditor.definitions(provider: provider, helperURL: environment.installedHelperURL, socketPath: environment.socketPath)
    }

    private func recognizedCommands(_ provider: ProviderID, manifest: HookInstallationManifest, definitions: [ManagedHookDefinition]) -> Set<String> {
        // A marker alone never establishes ownership. Historical commands must
        // also be recorded in our manifest and name an exact known helper path.
        let legacySupport = environment.homeDirectoryURL.appendingPathComponent("Library/Application Support/AIIsland")
        let helpers = [environment.installedHelperURL,
                       environment.applicationSupportURL.appendingPathComponent("bin/ai-island-hook"),
                       legacySupport.appendingPathComponent("bin/ai-island-hook")]
        let prefixes = helpers.map { HookConfigurationEditor.shellQuote($0.path) + " --provider \(provider.rawValue) --socket " }
        let suffixes = [" # lingchongdao-managed:v1:\(provider.rawValue)", " # ai-island-managed:v1:\(provider.rawValue)"]
        let recorded = (manifest.ownedCommands[provider.rawValue] ?? []).filter { command in
            prefixes.contains(where: command.hasPrefix) && suffixes.contains(where: command.hasSuffix)
        }
        return Set(recorded).union(definitions.map(\.command))
    }

    private func validateHelperReplacement(sourceDigest: String, manifest: HookInstallationManifest) throws {
        guard let existing = try ConnectionFileStore.readOptional(environment.installedHelperURL) else { return }
        let existingDigest = ConnectionFileStore.digest(existing)
        guard existingDigest == sourceDigest || existingDigest == manifest.helperSHA256 else { throw ConnectionError.unownedHelper(environment.installedHelperURL.path) }
    }

    private func helperIsHealthy(_ manifest: HookInstallationManifest) throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: environment.installedHelperURL.path),
              let data = try ConnectionFileStore.readOptional(environment.installedHelperURL),
              let digest = manifest.helperSHA256 else { return false }
        return ConnectionFileStore.digest(data) == digest
    }

    private func writeManifest(_ manifest: HookInstallationManifest, expected: Data?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        try ConnectionFileStore.writeAtomically(data, to: environment.manifestURL, expected: expected)
    }

    public static func name(_ provider: ProviderID) -> String {
        switch provider { case .qoder: "Qoder CN / IDE"; case .claude: "Claude Code"; case .codex: "Codex"; case .zcode: "ZCode"; case .dsh: "DeepSeek Harness"; case .codebuddy: "CodeBuddy CN"; case .workbuddy: "WorkBuddy"; case .generic: "其他来源" }
    }
    public static func capabilities(_ provider: ProviderID) -> [ConnectionCapability] {
        switch provider {
        case .claude: return [.lifecycle, .activity, .limitedApproval, .returnToSource]
        case .codebuddy, .workbuddy: return [.lifecycle, .activity, .returnToSource]
        // ZCode exposes no verified conversation deep link, so it never claims return-to-source.
        case .zcode: return [.lifecycle, .activity, .limitedApproval]
        // The DeepSeek Harness bridge has no permission-request event.
        case .dsh: return [.lifecycle, .activity]
        default: return [.lifecycle, .activity, .limitedApproval, .returnToSource]
        }
    }
    private static func documentationURL(_ provider: ProviderID) -> URL {
        let url: String
        switch provider {
        case .claude: url = "https://code.claude.com/docs/en/hooks"
        case .codex: url = "https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks"
        case .zcode: url = "https://zcode.z.ai/cn/docs/hooks"
        case .dsh: url = "https://github.com/deepseek-ai/deepseek-harness"
        case .qoder, .generic: url = "https://docs.qoder.cn/qoder/hooks"
        case .codebuddy: url = "https://www.codebuddy.cn/docs/ide/Features/Hooks"
        case .workbuddy: url = "https://www.workbuddy.cn/docs/workbuddy/Plugins"
        }
        return URL(string: url)!
    }
}

@MainActor
public final class ConnectionManager: ObservableObject {
    @Published public private(set) var connections: [ProviderConnection]
    private let service: HookConnectionService
    private let environment: ConnectionEnvironment
    private var observations: [ProviderID: Date] = [:]
    private let pluginService: CodexPluginService
    private var pluginOperation = false
    private let dshService: DshConnectionService
    private let zcodeService: ZcodeConnectionService
    private let claudeService: ClaudeConnectionService
    private let qoderService: QoderConnectionService

    public convenience init(helperURL: URL? = nil, socketPath: String = BridgePaths.defaultSocketPath) {
        self.init(environment: .live(helperURL: helperURL, socketPath: socketPath))
    }

    public init(environment: ConnectionEnvironment) {
        let hooks = HookConnectionService(environment: environment)
        self.service = hooks
        self.environment = environment
        self.pluginService = CodexPluginService(environment: environment, hooks: hooks)
        self.dshService = DshConnectionService(environment: environment)
        self.zcodeService = ZcodeConnectionService(environment: environment)
        self.qoderService = QoderConnectionService(environment: environment)
        self.claudeService = ClaudeConnectionService(environment: environment)
        self.connections = [ProviderID.qoder, .codex, .claude, .zcode, .dsh, .codebuddy, .workbuddy].map { provider in
            ProviderConnection(provider: provider, displayName: HookConnectionService.name(provider),
                               detection: ProviderDetection(configurationURL: environment.configurationURL(for: provider)), status: .notInstalled,
                               capabilities: HookConnectionService.capabilities(provider), message: "正在检查应用与 Hook 配置。", hookPreview: "",
                               installedHookCount: 0, expectedHookCount: 0, lastEventAt: nil)
        }
    }

    public func refresh() async {
        for provider in [ProviderID.qoder, .codex, .claude, .zcode, .dsh, .codebuddy, .workbuddy] { await check(provider: provider) }
    }

    public func check(provider: ProviderID) async {
        guard !pluginOperation || ![ProviderID.codex, .dsh, .zcode, .qoder, .claude].contains(provider) else { return }
        var connection = provider == .codex ? await pluginService.check()
            : provider == .dsh ? await dshService.check()
            : provider == .zcode ? await zcodeService.check()
            : provider == .qoder ? await qoderService.check()
            : provider == .claude ? await claudeService.check()
            : await service.check(provider: provider)
        if let date = observations[provider] {
            connection.lastEventAt = date
            if connection.hasInstalledHooks && connection.status == .installed {
                connection.status = .connected
                connection.message = provider == .codebuddy || provider == .workbuddy || provider == .dsh
                    ? "已收到 \(HookConnectionService.name(provider)) 实际 Hook 活动。权限决定、问题回复与完整对话请返回来源应用。"
                    : provider == .claude ? "已收到 Claude 实际 Hook 活动；岛内支持单次批准可完整预览的 Bash 和网页搜索，其余回来源处理。"
                    : "已收到来源实际 Hook 活动。岛内仅处理支持的 Bash 权限请求；问题回复和复杂操作请返回来源。"
            }
        }
        update(connection)
    }

    @discardableResult
    public func prepare(provider: ProviderID) async throws -> HookInstallationPlan {
        guard provider != .codex else { throw ConnectionError.io("Codex 请使用插件一键安装。") }
        if provider == .claude { return try await claudeService.prepare() }
        if provider == .dsh {
            let plan = try await dshService.prepare()
            if let index = connections.firstIndex(where: { $0.provider == provider }) { connections[index].hookPreview = plan.hookPreview }
            return plan
        }
        if provider == .zcode {
            let plan = try await zcodeService.prepare()
            if let index = connections.firstIndex(where: { $0.provider == provider }) { connections[index].hookPreview = plan.hookPreview }
            return plan
        }
        if provider == .qoder {
            let plan = try await qoderService.prepare()
            if let index = connections.firstIndex(where: { $0.provider == provider }) { connections[index].hookPreview = plan.hookPreview }
            return plan
        }
        let plan = try await service.prepare(provider: provider)
        if let index = connections.firstIndex(where: { $0.provider == provider }) { connections[index].hookPreview = plan.hookPreview }
        return plan
    }

    public func install(provider: ProviderID) async throws {
        guard provider != .codex else { throw ConnectionError.io("Codex 请使用插件一键安装。") }
        if provider == .claude { try await installClaudePlugin(); return }
        if provider == .dsh { try await dshService.install() }
        else if provider == .zcode { try await zcodeService.installDirectly() }
        else if provider == .qoder { try await qoderService.installDirectly() }
        else { try await service.install(provider: provider) }
        observations.removeValue(forKey: provider)
        await check(provider: provider)
    }

    public func remove(provider: ProviderID) async throws {
        if provider == .claude { try await uninstallClaudePlugin(); return }
        if provider == .codex { try await removeCodexPlugin(); return }
        if provider == .dsh { try await dshService.remove() }
        else if provider == .zcode { try await zcodeService.uninstall() }
        else if provider == .qoder { try await qoderService.uninstall() }
        else { try await service.remove(provider: provider) }
        observations.removeValue(forKey: provider)
        await check(provider: provider)
    }

    public func recordEvent(provider: ProviderID, at date: Date = Date()) {
        observations[provider] = date
        guard let index = connections.firstIndex(where: { $0.provider == provider }) else { return }
        connections[index].lastEventAt = date
        if connections[index].hasInstalledHooks && (connections[index].status == .installed || connections[index].status == .connected) {
            connections[index].status = .connected
            connections[index].message = "已收到实际 Hook 活动；完整对话与问题回复仍由来源应用处理。"
        }
    }

    public func installClaudePlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await claudeService.installDirectly() }
        catch { pluginOperation = false; await check(provider: .claude); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .claude)
        await check(provider: .claude)
    }

    public func uninstallClaudePlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await claudeService.uninstall() }
        catch { pluginOperation = false; await check(provider: .claude); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .claude)
        await check(provider: .claude)
    }

    public func installCodexPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await pluginService.install() }
        catch { pluginOperation = false; await check(provider: .codex); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .codex)
        await check(provider: .codex)
    }

    public func installDshPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await dshService.installDirectly() }
        catch { pluginOperation = false; await check(provider: .dsh); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .dsh)
        await check(provider: .dsh)
    }

    public func uninstallDshPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await dshService.uninstall() }
        catch { pluginOperation = false; await check(provider: .dsh); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .dsh)
        await check(provider: .dsh)
    }

    public func installZcodePlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await zcodeService.installDirectly() }
        catch { pluginOperation = false; await check(provider: .zcode); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .zcode)
        await check(provider: .zcode)
    }

    public func uninstallZcodePlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await zcodeService.uninstall() }
        catch { pluginOperation = false; await check(provider: .zcode); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .zcode)
        await check(provider: .zcode)
    }

    public func installQoderPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await qoderService.installDirectly() }
        catch { pluginOperation = false; await check(provider: .qoder); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .qoder)
        await check(provider: .qoder)
    }

    public func uninstallQoderPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await qoderService.uninstall() }
        catch { pluginOperation = false; await check(provider: .qoder); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .qoder)
        await check(provider: .qoder)
    }

    public func removeCodexPlugin() async throws {
        guard !pluginOperation else { throw ConnectionError.io("插件操作正在进行。") }
        pluginOperation = true
        do { try await pluginService.remove() }
        catch { pluginOperation = false; await check(provider: .codex); throw error }
        pluginOperation = false
        observations.removeValue(forKey: .codex)
        await check(provider: .codex)
    }

    private func update(_ connection: ProviderConnection) {
        if let index = connections.firstIndex(where: { $0.provider == connection.provider }) { connections[index] = connection }
    }
}
