import Foundation
import IslandCore

public enum ConnectionStatus: String, Codable, Sendable {
    case notDetected, notInstalled, installed, needsReview, connected, needsRepair, configurationError

    public var title: String {
        switch self {
        case .notDetected: "未检测到"
        case .notInstalled: "未连接"
        case .installed: "已安装，待验证"
        case .needsReview: "待审阅与验证"
        case .connected: "已收到活动"
        case .needsRepair: "配置不完整"
        case .configurationError: "配置需要检查"
        }
    }
}

public enum ConnectionCapability: String, Codable, CaseIterable, Sendable {
    case lifecycle, activity, limitedApproval, returnToSource

    public var title: String {
        switch self {
        case .lifecycle: "任务活动"
        case .activity: "工具进展"
        case .limitedApproval: "部分权限请求"
        case .returnToSource: "返回来源应用"
        }
    }
}

public struct ProviderDetection: Equatable, Sendable {
    public var appURL: URL?
    public var appVersion: String?
    public var cliURL: URL?
    public var cliVersion: String?
    public var cliMessage: String?
    public var configurationURL: URL

    public init(appURL: URL? = nil, appVersion: String? = nil, cliURL: URL? = nil, cliVersion: String? = nil,
                cliMessage: String? = nil, configurationURL: URL) {
        self.appURL = appURL
        self.appVersion = appVersion
        self.cliURL = cliURL
        self.cliVersion = cliVersion
        self.cliMessage = cliMessage
        self.configurationURL = configurationURL
    }

    public var isDetected: Bool { appURL != nil || cliURL != nil }
    public var summary: String {
        var parts: [String] = []
        if let appURL { parts.append(appURL.deletingPathExtension().lastPathComponent + (appVersion.map { " \($0)" } ?? "")) }
        if let cliURL { parts.append(cliURL.lastPathComponent + (cliVersion.map { " \($0)" } ?? "")) }
        return parts.isEmpty ? "未找到桌面应用或 CLI" : parts.joined(separator: " · ")
    }
}

public struct ProviderConnection: Identifiable, Sendable {
    public var id: String { provider.rawValue }
    public var provider: ProviderID
    public var displayName: String
    public var detection: ProviderDetection
    public var status: ConnectionStatus
    public var capabilities: [ConnectionCapability]
    public var message: String
    public var hookPreview: String
    public var installedHookCount: Int
    public var expectedHookCount: Int
    public var lastEventAt: Date?
    /// The bundled plugin is newer (or different) than the installed copy.
    public var pluginUpdateAvailable: Bool = false
    public var hasInstalledHooks: Bool { installedHookCount > 0 }
    public var requiresTrustReview: Bool { provider == .codex && hasInstalledHooks }
}

public struct HookInstallationPlan: Identifiable, Sendable {
    public let id: UUID
    public let provider: ProviderID
    public let displayName: String
    public let configurationURL: URL
    public let helperURL: URL
    public let sourceHelperURL: URL
    public let socketPath: String
    /// Only 灵宠岛's hook fragment. Unrelated user configuration is never exposed in the preview.
    public let hookPreview: String
    public let hookLabels: [String]
    /// Compact per-event labels for chip-style summaries; falls back to `hookLabels` when unset.
    public var hookShortLabels: [String] = []
    public let summary: String
    public let reviewInstructions: String
    public let documentationURL: URL
    public let createsConfiguration: Bool
    public let preparedAt: Date
}

public struct ConnectionEnvironment: Sendable {
    public var homeDirectoryURL: URL
    public var claudeHomeURL: URL
    public var claudePluginSourceURL: URL?
    public var codexHomeURL: URL
    public var zcodeHomeURL: URL
    public var dshHomeURL: URL
    public var codebuddyHomeURL: URL
    public var workbuddyHomeURL: URL
    public var qoderHomeURL: URL
    public var qoderConfigurationError: String?
    public var applicationSupportURL: URL
    public var helperSourceURL: URL?
    public var codexPluginSourceURL: URL?
    /// The 灵宠岛 dsh plugin shipped in `Contents/Resources/DshPlugin`.
    public var dshPluginSourceURL: URL?
    /// The 灵宠岛 ZCode marketplace + plugin in `Contents/Resources/ZcodePlugin`.
    public var zcodePluginSourceURL: URL?
    /// The 灵宠岛 Qoder plugin in `Contents/Resources/QoderPlugin`.
    public var qoderPluginSourceURL: URL?
    public var socketPath: String
    public var applicationDirectories: [URL]
    public var executableSearchDirectories: [URL]
    public var detectCLIVersions: Bool

    public init(homeDirectoryURL: URL, applicationSupportURL: URL? = nil, helperSourceURL: URL? = nil,
                socketPath: String? = nil, applicationDirectories: [URL] = [],
                executableSearchDirectories: [URL] = [], detectCLIVersions: Bool = true,
                codexHomeURL: URL? = nil, qoderHomeURL: URL? = nil, qoderConfigurationError: String? = nil,
                codexPluginSourceURL: URL? = nil, codebuddyHomeURL: URL? = nil, workbuddyHomeURL: URL? = nil,
                zcodeHomeURL: URL? = nil, dshHomeURL: URL? = nil, dshPluginSourceURL: URL? = nil,
                zcodePluginSourceURL: URL? = nil, qoderPluginSourceURL: URL? = nil,
                claudeHomeURL: URL? = nil, claudePluginSourceURL: URL? = nil) {
        self.claudeHomeURL = claudeHomeURL ?? homeDirectoryURL.appendingPathComponent(".claude", isDirectory: true)
        self.claudePluginSourceURL = claudePluginSourceURL
        self.homeDirectoryURL = homeDirectoryURL
        self.codexHomeURL = codexHomeURL ?? homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        self.zcodeHomeURL = zcodeHomeURL ?? homeDirectoryURL.appendingPathComponent(".zcode", isDirectory: true)
        self.dshHomeURL = dshHomeURL ?? homeDirectoryURL.appendingPathComponent(".dsh", isDirectory: true)
        self.qoderHomeURL = qoderHomeURL ?? homeDirectoryURL.appendingPathComponent(".qoder-cn", isDirectory: true)
        self.codebuddyHomeURL = codebuddyHomeURL ?? homeDirectoryURL.appendingPathComponent(".codebuddy", isDirectory: true)
        self.workbuddyHomeURL = workbuddyHomeURL ?? homeDirectoryURL.appendingPathComponent(".workbuddy", isDirectory: true)
        self.qoderConfigurationError = qoderConfigurationError
        let support = applicationSupportURL ?? homeDirectoryURL.appendingPathComponent("Library/Application Support/LingChongDao", isDirectory: true)
        self.applicationSupportURL = support
        self.helperSourceURL = helperSourceURL
        self.codexPluginSourceURL = codexPluginSourceURL
        self.dshPluginSourceURL = dshPluginSourceURL
        self.zcodePluginSourceURL = zcodePluginSourceURL
        self.qoderPluginSourceURL = qoderPluginSourceURL
        self.socketPath = socketPath ?? support.appendingPathComponent("run/bridge.sock").path
        self.applicationDirectories = applicationDirectories
        self.executableSearchDirectories = executableSearchDirectories
        self.detectCLIVersions = detectCLIVersions
    }

    public static func live(helperURL: URL? = nil, socketPath: String = BridgePaths.defaultSocketPath) -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let processEnvironment = ProcessInfo.processInfo.environment
        let pathDirectories = (processEnvironment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let helper = helperURL ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lingchongdao-hook")
        let codexHome = processEnvironment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        var qoderHome: URL?
        var qoderError: String?
        do {
            qoderHome = try resolveQoderHomeURL(homeDirectoryURL: home, environment: processEnvironment,
                                              currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        } catch { qoderError = error.localizedDescription }
        return Self(homeDirectoryURL: home, helperSourceURL: helper, socketPath: socketPath,
                    applicationDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)],
                    executableSearchDirectories: pathDirectories + [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".qoder/bin"), home.appendingPathComponent(".codex/bin")],
                    codexHomeURL: codexHome, qoderHomeURL: qoderHome, qoderConfigurationError: qoderError,
                    codexPluginSourceURL: Bundle.main.resourceURL?.appendingPathComponent("LingChongDaoCodexPlugin", isDirectory: true),
                    codebuddyHomeURL: try? resolveBuddyHomeURL(provider: .codebuddy, homeDirectoryURL: home, environment: processEnvironment,
                        currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)),
                    workbuddyHomeURL: try? resolveBuddyHomeURL(provider: .workbuddy, homeDirectoryURL: home, environment: processEnvironment,
                        currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)),
                    dshPluginSourceURL: Bundle.main.resourceURL?.appendingPathComponent("DshPlugin", isDirectory: true),
                    zcodePluginSourceURL: Bundle.main.resourceURL?.appendingPathComponent("ZcodePlugin", isDirectory: true),
                    qoderPluginSourceURL: Bundle.main.resourceURL?.appendingPathComponent("QoderPlugin", isDirectory: true),
                    claudeHomeURL: processEnvironment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil },
                    claudePluginSourceURL: Bundle.main.resourceURL?.appendingPathComponent("ClaudePlugin", isDirectory: true))
    }

    /// Mirrors Buddy's explicit configuration directory precedence; no user settings are read.
    public static func resolveBuddyHomeURL(provider: ProviderID, homeDirectoryURL: URL, environment: [String: String], currentDirectoryURL: URL) throws -> URL {
        let keys: [String]
        let defaultName: String
        switch provider {
        case .codebuddy: keys = ["CODEBUDDY_CONFIG_DIR"]; defaultName = ".codebuddy"
        case .workbuddy: keys = ["WORKBUDDY_CONFIG_DIR", "CODEBUDDY_CONFIG_DIR"]; defaultName = ".workbuddy"
        default: throw ConnectionError.unsupportedProvider
        }
        if let path = keys.compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) {
            return URL(fileURLWithPath: path, isDirectory: true, relativeTo: currentDirectoryURL).standardizedFileURL
        }
        return homeDirectoryURL.appendingPathComponent(defaultName, isDirectory: true)
    }

    /// Matches Qoder CN's config resolver, including its environment variable precedence.
    /// Relative paths are anchored to the provider process's current directory. No filesystem is read.
    public static func resolveQoderHomeURL(homeDirectoryURL: URL, environment: [String: String], currentDirectoryURL: URL) throws -> URL {
        func resolved(_ path: String) -> URL {
            URL(fileURLWithPath: path.precomposedStringWithCanonicalMapping, isDirectory: true,
                relativeTo: currentDirectoryURL).standardizedFileURL
        }
        if let directory = environment["QODERCN_CONFIG_DIR"], !directory.isEmpty { return resolved(directory) }
        let name = environment["QODERCN_CONFIG_DIR_NAME"].flatMap { $0.isEmpty ? nil : $0 }?.precomposedStringWithCanonicalMapping ?? ".qoder-cn"
        let forbiddenNames: Set<String> = [".git", ".svn", ".hg", ".vscode", ".idea", ".husky", ".github", "node_modules", "bower_components"]
        guard (1...64).contains(name.unicodeScalars.count), name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.hasSuffix("."), name != ".", name != "..",
              name.range(of: #"^[\p{L}\p{N}\p{M}._ -]+$"#, options: .regularExpression) != nil,
              name.range(of: #"^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !forbiddenNames.contains(name.lowercased()) else { throw ConnectionError.invalidQoderDirectoryName }
        let base = environment["QODERCN_CLI_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectoryURL.path
        return resolved(base + "/" + name)
    }

    public var installedHelperURL: URL { applicationSupportURL.appendingPathComponent("bin/lingchongdao-hook") }
    public var manifestURL: URL { applicationSupportURL.appendingPathComponent("hook-installation.json") }

    /// DeepSeek Harness keeps its plugins and loader patches in an app-managed profile.
    /// Hooks live in our own settings file and are mounted by one row in the profile patch.
    public var dshProfileURL: URL { dshHomeURL.appendingPathComponent("profiles/desktop", isDirectory: true) }
    public var dshPatchURL: URL { dshProfileURL.appendingPathComponent("cordis.patch.yml") }
    /// Stable copy of the bundled plugin so the profile link survives app moves.
    public var dshPluginInstallURL: URL { applicationSupportURL.appendingPathComponent("dsh-plugin", isDirectory: true) }
    public func configurationURL(for provider: ProviderID) -> URL {
        switch provider {
        case .qoder: qoderHomeURL.appendingPathComponent("settings.json")
        case .codebuddy: codebuddyHomeURL.appendingPathComponent("settings.json")
        case .workbuddy: workbuddyHomeURL.appendingPathComponent("settings.json")
        case .claude: claudeHomeURL.appendingPathComponent("settings.json")
        case .codex: codexHomeURL.appendingPathComponent("hooks.json")
        case .zcode: zcodeHomeURL.appendingPathComponent("cli/config.json")
        case .dsh: dshProfileURL.appendingPathComponent("package.json")
        case .generic: applicationSupportURL.appendingPathComponent("unsupported.json")
        }
    }
}

public enum ConnectionError: LocalizedError {
    case unsupportedProvider
    case invalidQoderDirectoryName
    case invalidConfiguration(String)
    case unsafePath(String)
    case helperUnavailable(String)
    case unownedHelper(String)
    case reviewRequired
    case configurationChanged
    case helperChanged
    case invalidManifest
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "此来源暂不支持安装 Hook。"
        case .invalidQoderDirectoryName: "QODERCN_CONFIG_DIR_NAME 不是有效的配置目录名称。"
        case .invalidConfiguration(let path): "配置不是有效的 Hooks JSON，未覆盖原文件：\(path)"
        case .unsafePath(let path): "路径是符号链接、不是普通文件或不属于当前用户，未修改：\(path)"
        case .helperUnavailable(let path): "未找到可执行的 Hook helper：\(path)。请使用包含 lingchongdao-hook 的完整应用。"
        case .unownedHelper(let path): "固定位置已有无法确认归属的 helper，未覆盖：\(path)"
        case .reviewRequired: "请先预览本次 Hook 配置，再点击安装。"
        case .configurationChanged: "配置在预览后发生了变化。请重新预览，原文件未覆盖。"
        case .helperChanged: "Hook helper 在预览后发生了变化。请重新预览。"
        case .invalidManifest: "灵宠岛的安装记录损坏，未修改来源配置。请检查 hook-installation.json。"
        case .io(let reason): "连接配置操作失败：\(reason)"
        }
    }
}
