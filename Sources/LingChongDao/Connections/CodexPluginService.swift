import Darwin
import Foundation
import IslandCore

/// Runs only the desktop CLI's plugin API. Never edits Codex trust or TOML files.
public actor CodexPluginService {
    private let environment: ConnectionEnvironment
    private let hooks: HookConnectionService
    private let selector = "lingchongdao-codex@lingchongdao-local"
    private var busy = false
    private let commandTimeout: TimeInterval
    public init(environment: ConnectionEnvironment, hooks: HookConnectionService, commandTimeout: TimeInterval = 20) { self.environment = environment; self.hooks = hooks; self.commandTimeout = max(0.1, commandTimeout) }

    public func install() async throws {
        guard !busy else { throw ConnectionError.io("插件操作正在进行，请稍后重试。") }
        busy = true
        defer { busy = false }
        let detection = await ProviderDetector.detect(provider: .codex, environment: environment)
        guard let cli = detection.cliURL else { throw ConnectionError.io("未找到支持插件的 Codex CLI；可使用手动导出插件。") }
        try ConnectionFileStore.validateExistingFile(environment.codexHomeURL.appendingPathComponent(".path-check"))
        try FileManager.default.createDirectory(at: environment.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = try publishSource()
        try await verifyMarketplace(cli, source: source, register: true)
        let before = try await installed(cli)
        if let before, !before.enabled { throw ConnectionError.io("插件已禁用，请到 Codex 启用灵宠岛插件；旧 Hook 已保留。") }
        _ = try await run(cli, ["plugin", "add", selector, "--json"])
        guard let state = try await installed(cli), state.installed, state.version == expectedVersion(source), state.source == source.path + "/plugins/lingchongdao-codex", state.marketplaceSource == source.path else { throw ConnectionError.io("Codex 未确认插件安装成功；旧 Hook 已保留。") }
        guard state.enabled else { throw ConnectionError.io("插件已安装但被禁用，请到 Codex 启用灵宠岛插件；旧 Hook 已保留。") }
        do { try await hooks.remove(provider: .codex) }
        catch { throw ConnectionError.io("插件已安装，但旧 Hook 清理失败，可能重复派发；请修复后重试。\(error.localizedDescription)") }
    }

    public func remove() async throws {
        guard !busy else { throw ConnectionError.io("插件操作正在进行，请稍后重试。") }
        busy = true
        defer { busy = false }
        let detection = await ProviderDetector.detect(provider: .codex, environment: environment)
        guard let cli = detection.cliURL else { throw ConnectionError.io("未找到 Codex CLI，无法确认卸载。") }
        let source = try publishedSource()
        try await verifyMarketplace(cli, source: source, register: false)
        if try await installed(cli) != nil { _ = try await run(cli, ["plugin", "remove", selector, "--json"]) }
        guard try await installed(cli) == nil else { throw ConnectionError.io("Codex 未确认插件卸载成功。") }
    }

    public func check() async -> ProviderConnection {
        var result = await hooks.check(provider: .codex)
        let directCount = result.installedHookCount
        result.installedHookCount = 0
        result.expectedHookCount = 10
        result.hookPreview = ""
        guard !busy else { result.status = .needsRepair; result.message = "插件操作正在进行。"; return result }
        busy = true
        defer { busy = false }
        guard let cli = result.detection.cliURL else {
            // Source setup is distinct from a broken existing configuration.
            if result.status != .configurationError {
                result.status = directCount > 0 ? .needsReview
                    : (result.detection.isDetected ? .notInstalled : .notDetected)
                result.message = result.detection.isDetected
                    ? "已检测到 Codex，但未找到 CLI。请先启动或更新 Codex，再检查连接；也可手动导出插件。"
                    : "未找到 Codex 桌面应用或 CLI。请先安装并启动 Codex，再检查连接。"
            }
            return result
        }
        do {
            let source = try publishedSource()
            try await verifyMarketplace(cli, source: source, register: false)
            if let state = try await installed(cli), state.installed {
                result.installedHookCount = 10
                let bundledVersion = bundledPluginVersion()
                if !state.enabled { result.status = .needsReview; result.message = "插件已安装但被禁用，请到 Codex 启用灵宠岛插件。" }
                else if state.source != source.path + "/plugins/lingchongdao-codex" || state.marketplaceSource != source.path { result.status = .needsRepair; result.message = "插件来源需要更新，请重新安装。" }
                else if !bundledVersion.isEmpty, state.version != bundledVersion {
                    result.status = .installed
                    result.pluginUpdateAvailable = PluginPackage.isNewer(bundledVersion, than: state.version)
                    result.message = result.pluginUpdateAvailable
                        ? "插件有新版本（\(state.version) → \(bundledVersion)），点「更新插件」刷新。"
                        : "插件已安装并启用，请用 Codex 新任务验证活动。"
                }
                else if directCount > 0 || result.status == .configurationError { result.status = .needsRepair; result.message = "插件已安装，但旧直接 Hook 尚未清理；请重新安装以完成迁移，避免重复派发。" }
                else { result.status = .installed; result.message = "插件已安装并启用，请用 Codex 新任务验证活动。" }
            } else { result.status = .notInstalled; result.message = "尚未安装灵宠岛 Codex 插件。" }
        } catch {
            if error.localizedDescription.contains("尚未登记") {
                result.status = .notInstalled
                result.message = directCount > 0
                    ? "检测到旧版直接接入。点击一键安装，成功后自动迁移到插件。"
                    : "尚未安装灵宠岛插件。点击一键安装即可接入 Codex。"
            } else {
                result.status = .configurationError
                result.message = error.localizedDescription
            }
        }
        return result
    }

    private struct State { let installed: Bool; let enabled: Bool; let version: String; let source: String; let marketplaceSource: String }
    private func installed(_ cli: URL) async throws -> State? {
        let json = try await run(cli, ["plugin", "list", "--json", "--marketplace", "lingchongdao-local"])
        guard let entries = json["installed"] as? [[String: Any]] else { throw ConnectionError.io("无法识别 Codex 插件列表；请升级 Codex 或手动导出插件。") }
        let matching = entries.filter { ($0["name"] as? String) == "lingchongdao-codex" && ($0["marketplaceName"] as? String) == "lingchongdao-local" }
        guard matching.count <= 1 else { throw ConnectionError.io("Codex 插件列表含重复记录。") }
        guard let item = matching.first else { return nil }
        guard let installed = item["installed"] as? Bool, let enabled = item["enabled"] as? Bool else { throw ConnectionError.io("无法确认 Codex 插件启用状态。") }
        return installed ? State(installed: installed, enabled: enabled, version: item["version"] as? String ?? "", source: (item["source"] as? [String:Any])?["path"] as? String ?? "", marketplaceSource: (item["marketplaceSource"] as? [String:Any])?["source"] as? String ?? "") : nil
    }

    private func verifyMarketplace(_ cli: URL, source: URL, register: Bool) async throws {
        let json = try await run(cli, ["plugin", "marketplace", "list", "--json"])
        guard let entries = json["marketplaces"] as? [[String: Any]] else { throw ConnectionError.io("无法识别 Codex marketplace 列表。") }
        let matches = entries.filter { $0["name"] as? String == "lingchongdao-local" }
        guard matches.count <= 1 else { throw ConnectionError.io("同名 marketplace 记录不明确，未修改。") }
        if let entry = matches.first {
            let metadata = entry["marketplaceSource"] as? [String: Any]
            guard entry["root"] as? String == source.path, metadata?["sourceType"] as? String == "local", metadata?["source"] as? String == source.path else { throw ConnectionError.io("同名 lingchongdao-local marketplace 来自其他路径，未修改。") }
        } else if register {
            _ = try await run(cli, ["plugin", "marketplace", "add", source.path, "--json"])
            try await verifyMarketplace(cli, source: source, register: false)
        } else {
            throw ConnectionError.io("尚未登记灵宠岛本地 marketplace，请安装插件。")
        }
    }

    private func expectedVersion(_ root: URL) -> String {
        let data = try? Data(contentsOf: root.appendingPathComponent("package-info.json"))
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String:Any] }?["pluginVersion"] as? String ?? ""
    }

    /// The app bundle, not the previously published copy, decides whether an
    /// update exists; publishing happens only when the user installs.
    private func bundledPluginVersion() -> String {
        guard let source = environment.codexPluginSourceURL else { return "" }
        return expectedVersion(source)
    }

    private func publishedSource() throws -> URL {
        guard let source = environment.codexPluginSourceURL else { throw ConnectionError.io("应用未包含插件资源；请安装完整应用或使用手动导出。") }
        _ = try validateBundle(source, allowRootOwner: true)
        return environment.applicationSupportURL.appendingPathComponent("codex-plugin/marketplace", isDirectory: true)
    }

    private func publishSource() throws -> URL {
        guard let source = environment.codexPluginSourceURL else { throw ConnectionError.io("应用未包含插件资源。") }
        let target = try publishedSource()
        try ConnectionFileStore.validateExistingFile(target.appendingPathComponent(".path-check"))
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let marker = parent.appendingPathComponent("owned-tree.sha256")
        let pending = parent.appendingPathComponent("pending-tree.sha256")
        let pendingData = try ConnectionFileStore.readOptional(pending)
        if try ConnectionFileStore.readOptional(marker) == nil,
           let pendingData, let pendingDigest = String(data: pendingData, encoding: .utf8),
           (try? validateBundle(target)) == pendingDigest {
            try ConnectionFileStore.writeAtomically(pendingData, to: marker, expected: nil)
            try fm.removeItem(at: pending)
        }
        let previousMarker = try ConnectionFileStore.readOptional(marker)
        let digest = try validateBundle(source, allowRootOwner: true)
        // Recover a directory replacement interrupted before the marker commit.
        // A valid tree with only a stale marker (for example after an in-place
        // display-name refresh) is still replaceable below; only an invalid tree
        // without an unambiguous backup is unsafe to touch.
        if let previousMarker, let oldDigest = String(data: previousMarker, encoding: .utf8),
           (try? validateBundle(target)) != oldDigest {
            let candidates = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".previous-") }
            let backups = candidates.filter { (try? validateBundle($0)) == oldDigest }
            if backups.count == 1, let backup = backups.first {
                if fm.fileExists(atPath: target.path) {
                    let interrupted = parent.appendingPathComponent(".interrupted-\(UUID().uuidString)")
                    try ConnectionFileStore.validateExistingFile(target.appendingPathComponent(".path-check"))
                    try fm.moveItem(at: target, to: interrupted)
                }
                try fm.moveItem(at: backup, to: target)
            } else if (try? validateBundle(target)) == nil {
                throw ConnectionError.io("插件更新中断且恢复资源不明确，请检查持久插件目录。")
            }
        }
        let exists = fm.fileExists(atPath: target.path)
        let currentDigest = exists ? (try? validateBundle(target)) : nil
        if exists {
            // validateBundle already proves this tree is ours (format, names,
            // helper digest and hook contract); a stale marker may only mean an
            // earlier version was refreshed in place.
            guard let currentDigest else { throw ConnectionError.io("持久插件资源归属或完整性校验失败，未覆盖。") }
            if let previousMarker, String(data: previousMarker, encoding: .utf8) == currentDigest, currentDigest == digest { return target }
        } else if previousMarker != nil { throw ConnectionError.io("插件安装记录与资源不一致，请检查持久插件目录。") }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".previous-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        guard try validateBundle(staging) == digest else { throw ConnectionError.io("复制的插件资源校验失败。") }
        guard try ConnectionFileStore.readOptional(marker) == previousMarker else { throw ConnectionError.configurationChanged }
        if exists {
            guard let currentDigest, (try? validateBundle(target)) == currentDigest else { throw ConnectionError.configurationChanged }
            try fm.moveItem(at: target, to: backup)
        }
        try ConnectionFileStore.writeAtomically(Data(digest.utf8), to: pending, expected: try ConnectionFileStore.readOptional(pending))
        do {
            try fm.moveItem(at: staging, to: target)
            try ConnectionFileStore.writeAtomically(Data(digest.utf8), to: marker, expected: previousMarker)
        } catch {
            try? fm.removeItem(at: target)
            if exists { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
        try? fm.removeItem(at: pending)
        // The prior validated tree remains available until the next successful update.
        for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent.hasPrefix(".previous-") && item != backup {
            if (try? validateBundle(item)) != nil { try? fm.removeItem(at: item) }
        }
        return target
    }

    private func validateBundle(_ root: URL, allowRootOwner: Bool = false) throws -> String {
        try ConnectionFileStore.validateExistingFile(root.appendingPathComponent(".path-check"))
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { throw ConnectionError.io("插件资源目录不存在。") }
        var files: [(String, Data)] = []
        for case let url as URL in enumerator {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType, type == .typeDirectory || type == .typeRegular,
                  ((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() || (allowRootOwner && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0)) else { throw ConnectionError.unsafePath(url.path) }
            if type == .typeRegular { files.append((String(url.path.dropFirst(root.path.count)), try Data(contentsOf: url))) }
        }
        let required = ["package-info.json", ".agents/plugins/marketplace.json", "plugins/lingchongdao-codex/.codex-plugin/plugin.json", "plugins/lingchongdao-codex/hooks/hooks.json", "plugins/lingchongdao-codex/scripts/forward-hook.sh", "plugins/lingchongdao-codex/bin/lingchongdao-hook"]
        for path in required { guard files.contains(where: { $0.0 == "/" + path }) else { throw ConnectionError.io("插件资源缺失：\(path)") } }
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("package-info.json"))) as? [String: Any]
        func object(_ path: String) throws -> [String:Any] {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String:Any] else { throw ConnectionError.io("插件 JSON 格式无效。") }
            return value
        }
        let marketplace = try object(".agents/plugins/marketplace.json")
        let manifest = try object("plugins/lingchongdao-codex/.codex-plugin/plugin.json")
        let entries = marketplace["plugins"] as? [[String:Any]]
        let entry = entries?.first
        let hookObject = try object("plugins/lingchongdao-codex/hooks/hooks.json")
        guard marketplace["name"] as? String == "lingchongdao-local", entries?.count == 1,
              entry?["name"] as? String == "lingchongdao-codex",
              (entry?["source"] as? [String:Any])?["path"] as? String == "./plugins/lingchongdao-codex",
              (entry?["source"] as? [String:Any])?["source"] as? String == "local",
              manifest["name"] as? String == "lingchongdao-codex",
              manifest["hooks"] as? String == "./hooks/hooks.json",
              manifest["version"] as? String == metadata?["pluginVersion"] as? String,
              !(metadata?["pluginVersion"] as? String ?? "").isEmpty,
              hookObject["hooks"] is [String:Any] else { throw ConnectionError.io("插件资源契约校验失败。") }
        let helper = root.appendingPathComponent(required.last!)
        guard metadata?["format"] as? String == "lingchongdao-codex-local-marketplace-v1",
              metadata?["helperSHA256"] as? String == ConnectionFileStore.digest(try Data(contentsOf: helper)),
              fm.isExecutableFile(atPath: helper.path) else { throw ConnectionError.io("插件 helper 的完整性校验失败。") }
        var data = Data()
        for (path, contents) in files.sorted(by: { $0.0 < $1.0 }) { data.append(Data(path.utf8)); data.append(0); data.append(Data(ConnectionFileStore.digest(contents).utf8)) }
        return ConnectionFileStore.digest(data)
    }

    private func run(_ cli: URL, _ arguments: [String]) async throws -> [String: Any] {
        let home = environment.homeDirectoryURL.path
        let codexHome = environment.codexHomeURL.path
        let timeout = commandTimeout
        return try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("lingchongdao-cli-\(UUID().uuidString)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }
            let process = Process()
            process.executableURL = cli; process.arguments = arguments; process.currentDirectoryURL = directory
            process.environment = ["HOME": home, "CODEX_HOME": codexHome, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            let pipe = Pipe(); let errors = Pipe(); process.standardOutput = pipe; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let errorFD = errors.fileHandleForReading.fileDescriptor
            _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
            var output = Data(); var errorCount = 0; var buffer = [UInt8](repeating: 0, count: 8192)
            let deadline = Date().addingTimeInterval(timeout)
            var failure: String?
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
                let errorsRead = read(errorFD, &buffer, buffer.count)
                if errorsRead > 0 { errorCount += errorsRead }
                if output.count + errorCount > 1_048_576 { failure = "Codex CLI 输出超过限制。"; break }
                if Date() > deadline { failure = "Codex CLI 操作超时。"; break }
                if count <= 0 && !process.isRunning { break }
                if count <= 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            if let failure { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw ConnectionError.io(failure) }
            guard process.terminationStatus == 0 else { throw ConnectionError.io("Codex 插件命令失败，CLI 可能不支持插件；可升级 Codex 或手动导出。") }
            guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw ConnectionError.io("Codex CLI 未返回有效 JSON，无法确认操作。") }
            return object
        }.value
    }
}
