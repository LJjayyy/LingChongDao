import AppKit
import Combine
import Foundation
import IslandCore

extension ProviderID {
    var displayName: String { switch self { case .qoder: return "Qoder CN"; case .claude: return "Claude Code"; case .codex: return "Codex"; case .zcode: return "ZCode"; case .dsh: return "DeepSeek Harness"; case .codebuddy: return "CodeBuddy CN"; case .workbuddy: return "WorkBuddy"; case .generic: return "其他工具" } }
}

extension IslandSession {
    var sourceDisplayName: String {
        switch sourceApplication {
        case .claudeDesktop: return "Claude App · Code"
        case .claudeVSCode: return "Claude Code · VS Code"
        case .claudeCursor: return "Claude Code · Cursor"
        case .claudeIntelliJ: return "Claude Code · IntelliJ"
        case .claudePyCharm: return "Claude Code · PyCharm"
        case .claudeWebStorm: return "Claude Code · WebStorm"
        case .claudeGoLand: return "Claude Code · GoLand"
        case .claudeTerminal: return "Claude Code · Terminal"
        case .claudeITerm: return "Claude Code · iTerm"
        case .claudeWarp: return "Claude Code · Warp"
        case .claudeUnknown: return "Claude Code（来源待识别）"
        case .qoderDesktop: return "Qoder CN"
        case .qoderIDE: return "Qoder CN IDE"
        case .qoderUnknown: return "Qoder CN（来源待识别）"
        case .codebuddyCNIDE: return "CodeBuddy CN"
        case .codebuddyUnknown: return "CodeBuddy（来源待识别）"
        case .workbuddyDesktop: return "WorkBuddy"
        case .workbuddyAI: return "WorkBuddy AI"
        case .workbuddyUnknown: return "WorkBuddy（来源待识别）"
        case .codexDesktop, .codexChatGPT: return "Codex"
        case .zcodeDesktop: return "ZCode"
        case .dshDesktop: return "DeepSeek Harness"
        case .none:
            switch source {
            case .qoder: return "Qoder CN（来源待识别）"
            case .codebuddy: return "CodeBuddy（来源待识别）"
            case .workbuddy: return "WorkBuddy（来源待识别）"
            case .claude: return "Claude Code（来源待识别）"
            case .dsh, .zcode, .codex, .generic: return source.displayName
            }
        }
    }
    var petSourceApplication: SourceApplicationID? {
        switch source {
        case .claude: return sourceApplication ?? .claudeUnknown
        case .qoder: return sourceApplication ?? .qoderUnknown
        case .codebuddy: return sourceApplication ?? .codebuddyUnknown
        case .workbuddy: return sourceApplication ?? .workbuddyUnknown
        case .zcode, .dsh, .codex, .generic: return nil
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    @Published private(set) var sessions: [IslandSession] = []
    @Published private(set) var bridgeRunning = false
    @Published var bridgeError: String?
    @Published var actionError: String?
    @Published var selectedSessionID: String?
    @Published var demoMode = false
    var resolveApplicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var openApplication: (URL) -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
    var openDestination: (URL, URL, @escaping @MainActor (Bool) -> Void) -> Void = { destination, application, completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([destination], withApplicationAt: application, configuration: configuration) { app, error in
            let delivered = app != nil && error == nil
            Task { @MainActor in completion(delivered) }
        }
    }
    var isProjectDirectory: (URL) -> Bool = { url in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    var openWorkbench: (() -> Void)?
    var onProviderEvent: ((ProviderID, Date) -> Void)?
    private var reducer = SessionReducer()
    private var qoderPermissionCorrelator = QoderPermissionCorrelator()
    private var previewReducer = SessionReducer()
    private var eventRevisions: [String: UInt64] = [:]
    private var navigationToken = UUID()
    private var server: IslandSocketServer?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private struct Waiter {
        let transportID: String
        let sessionKey: String
        let requestID: String
        let continuation: CheckedContinuation<BridgeReply, Never>
        let deadline: Date
    }
    private var waiters: [String: Waiter] = [:]
    private let defaults: UserDefaults

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings; self.defaults = defaults
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &cancellables)
    }

    /// The workbench is an inbox: keep active work and unread results, while
    /// retaining acknowledged metadata internally for future source events.
    var workbenchSessions: [IslandSession] { sessions.filter(\.isVisibleOnIsland) }

    var visibleSessions: [IslandSession] {
        sessions.filter { session in
            let shown: Bool
            switch session.source { case .qoder: shown = settings.showQoder; case .claude: shown = settings.showClaude; case .codex: shown = settings.showCodex; case .zcode: shown = settings.showZCode; case .dsh: shown = settings.showDSH; case .codebuddy: shown = settings.showCodeBuddy; case .workbuddy: shown = settings.showWorkBuddy; case .generic: shown = settings.showGeneric }
            return shown && session.isVisibleOnIsland
        }.sorted { left, right in
            let leftNeedsAction = !isPreview(left) && left.isAwaitingInteraction
            let rightNeedsAction = !isPreview(right) && right.isAwaitingInteraction
            if leftNeedsAction != rightNeedsAction { return leftNeedsAction }
            return left.priority == right.priority ? left.updatedAt > right.updatedAt : left.priority < right.priority
        }
    }

    func startBridge(socketPath: String = BridgePaths.defaultSocketPath) {
        guard server == nil else { return }
        do {
            let server = IslandSocketServer(socketPath: socketPath)
            try server.start(handler: { [weak self] envelope in
                guard let self else { return .fallback("灵宠岛已退出") }
                return await self.handle(envelope)
            }, onConnectionClosed: { [weak self] envelope, reason in
                Task { @MainActor in self?.connectionClosed(envelope, reason: reason) }
            })
            self.server = server; bridgeRunning = true; bridgeError = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { bridgeRunning = false; bridgeError = "本地接入未启动：\(error.localizedDescription)" }
    }

    func stopBridge() {
        timer?.invalidate(); timer = nil
        for waiter in waiters.values { waiter.continuation.resume(returning: .fallback("灵宠岛正在退出")) }
        waiters.removeAll(); server?.stop(); server = nil; bridgeRunning = false
    }

    func handle(_ envelope: BridgeEnvelope) async -> BridgeReply {
        guard envelope.version == 1 else { return .fallback("不支持的桥接版本") }
        if envelope.operation == .ping { return .acknowledged }
        if envelope.operation == .status {
            return BridgeReply(disposition: .status, message: "灵宠岛正在运行；\(visibleSessions.count) 个活动或未读会话", requestID: envelope.requestID)
        }
        do {
            if envelope.provider == .codex, let permissionID = envelope.raw[CodexPermissionBridge.identityKey]?.stringValue,
               permissionID != envelope.requestID { return .fallback("Codex 审批通道身份不匹配") }
            if envelope.provider == .qoder, let permissionID = envelope.raw[QoderPermissionBridge.identityKey]?.stringValue,
               permissionID != envelope.requestID { return .fallback("Qoder 审批通道身份不匹配") }
            if envelope.provider == .claude, let permissionID = envelope.raw["lingchongdao_permission_id"]?.stringValue,
               permissionID != envelope.requestID { return .fallback("Claude 审批通道身份不匹配") }
            var event = try HookNormalizer.normalize(rawJSON: try envelope.rawJSON, provider: envelope.provider, sourceApplication: envelope.sourceApplication)
            if event.source == .codex, event.kind == .approvalRequested,
               CodexApprovalContext.reviewer(for: envelope.raw) != .user {
                // Returning no decision lets Codex reach auto-review without
                // waiting on our UI. Unknown metadata must not invent a user wait.
                return .fallback("审批由 Codex 处理，灵宠岛不代替来源作决定。")
            }
            var correlation = qoderPermissionCorrelator
            if event.source == .qoder,
               let resolvedID = correlation.observe(envelope.raw, sessionKey: event.sessionKey, at: event.timestamp) {
                event.interactionID = resolvedID
            }
            if var approval = event.approval {
                if (event.source == .claude || event.source == .qoder) && !approval.canApprove && !approval.canDeny {
                    // A source-side prompt outlives its short observation socket.
                    approval.expiresAt = min(approval.expiresAt ?? .distantFuture, Date().addingTimeInterval(110))
                } else {
                    approval.expiresAt = min(approval.expiresAt ?? .distantFuture, envelope.deadline ?? Date().addingTimeInterval(45), Date().addingTimeInterval(110))
                }
                event.approval = approval
            }
            // Only accepted events may replace a pending interaction. Delayed and
            // duplicate events must not interrupt the current hook continuation.
            guard reducer.apply(event) else { return .fallback("旧事件或重复事件已忽略") }
            if event.source == .qoder { qoderPermissionCorrelator = correlation }
            reducer.expireRequests(at: Date())
            eventRevisions[event.sessionKey, default: 0] &+= 1
            let pendingIDs = reducer.pendingApprovalIDs(sessionKey: event.sessionKey)
            let obsolete = waiters.values.filter {
                $0.sessionKey == event.sessionKey && !pendingIDs.contains($0.requestID)
            }
            for old in obsolete { finish(old.transportID, reply: .fallback("来源会话已更新"), expire: false) }
            onProviderEvent?(event.source, Date()); publish()
            if event.approval?.isExpired() == true { return .fallback("权限请求已过期") }
            guard let request = event.approval,
                  pendingIDs.contains(request.id),
                  request.canApprove || request.canDeny else { return .acknowledged }
            if waiters.values.contains(where: { $0.sessionKey == event.sessionKey && $0.requestID == request.id }) {
                return .fallback("这个权限请求已经在等待处理")
            }
            return await withCheckedContinuation { continuation in
                waiters[envelope.requestID] = Waiter(transportID: envelope.requestID, sessionKey: event.sessionKey,
                    requestID: request.id, continuation: continuation, deadline: request.expiresAt ?? Date().addingTimeInterval(45))
            }
        } catch {
            return .fallback("事件无法识别：\(error.localizedDescription)")
        }
    }

    private func connectionClosed(_ envelope: BridgeEnvelope, reason: String) {
        finish(envelope.requestID, reply: .fallback(reason), expire: true)
    }

    private func finish(_ transportID: String, reply: BridgeReply, expire: Bool) {
        guard let waiter = waiters.removeValue(forKey: transportID) else { return }
        if expire { reducer.expireApproval(sessionKey: waiter.sessionKey, requestID: waiter.requestID) }
        waiter.continuation.resume(returning: reply); publish()
    }

    private func tick() {
        let now = Date()
        for waiter in waiters.values.filter({ $0.deadline <= now }) {
            finish(waiter.transportID, reply: .fallback("等待处理超时，请在原工具继续"), expire: true)
        }
        reducer.expireRequests(at: now); previewReducer.expireRequests(at: now); publish()
    }

    func respond(to session: IslandSession, decision: ApprovalDecision) {
        actionError = nil
        guard let request = session.approval, !request.isExpired() else {
            actionError = "这个请求已结束，请打开会话查看最新状态。"; return
        }
        if isPreview(session) {
            guard decision != .allow || request.canApprove, decision != .deny || request.canDeny else { return }
            _ = previewReducer.resolveApproval(sessionKey: session.id, requestID: request.id, decision: decision); publish(); return
        }
        guard let waiter = waiters.values.first(where: { $0.sessionKey == session.id && $0.requestID == request.id }),
              waiter.deadline > Date(),
              reducer.resolveApproval(sessionKey: session.id, requestID: request.id, decision: decision) else {
            actionError = "当前请求无法回传，请回到原工具处理。"; return
        }
        let disposition: BridgeDisposition = decision == .allow ? .allow : decision == .deny ? .deny : .fallback
        finish(waiter.transportID, reply: BridgeReply(disposition: disposition, requestID: waiter.transportID), expire: false)
        haptic()
    }

    func answer(_ answer: String, session: IslandSession) {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.count <= 20_000 else { return }
        guard isPreview(session), let question = session.question, !question.isExpired() else {
            actionError = "这个来源没有可用的问题回传通道，请在原会话中回答。"; return
        }
        previewReducer.apply(NormalizedHookEvent(source: session.source, host: session.host, sessionID: session.sessionID, threadID: session.threadID,
            turnID: session.turnID, interactionID: question.id, kind: .questionResolved, detail: "回答已提交，任务继续执行。"))
        clearDraft(session: session); publish(); haptic()
    }

    @discardableResult func dismiss(_ session: IslandSession, force: Bool = false) -> Bool {
        if isPreview(session) { let applied = previewReducer.dismissSession(sessionKey: session.id, force: force); publish(); return applied }
        if let waiter = waiters.values.first(where: { $0.sessionKey == session.id }) {
            finish(waiter.transportID, reply: .fallback("请在原工具继续处理"), expire: true)
        }
        let applied = reducer.dismissSession(sessionKey: session.id, force: force); publish(); return applied
    }

    func navigationLabel(for session: IslandSession) -> String {
        if isPreview(session) { return "打开应用" }
        let bundle = session.sourceApplication?.bundleIdentifier ?? (session.source == .codex ? "com.openai.codex" : "")
        if SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: bundle) != nil { return "打开会话" }
        if projectURL(for: session) != nil { return "打开项目" }
        return session.source == .generic ? "打开工作台" : "打开应用"
    }

    func navigationHelp(for session: IslandSession) -> String {
        switch navigationLabel(for: session) {
        case "打开会话": return "定位到「\(session.displayTitle)」的来源会话"
        case "打开项目": return "打开来源 IDE 的项目目录；当前版本尚不能定位具体会话"
        default: return "打开来源应用；当前消息缺少可用的会话定位入口"
        }
    }

    private func projectURL(for session: IslandSession) -> URL? {
        guard session.host == "localhost", session.source == .qoder, session.sourceApplication == .qoderIDE,
              session.cwd.hasPrefix("/"), session.cwd.utf8.count <= 4096,
              session.cwd.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let url = URL(fileURLWithPath: session.cwd, isDirectory: true).standardizedFileURL
        guard SessionTitle.projectName(from: url.path) != nil else { return nil }
        return isProjectDirectory(url) ? url : nil
    }

    func navigate(to session: IslandSession) {
        selectedSessionID = session.id
        navigationToken = UUID()
        let token = navigationToken
        let bundleID: String
        switch session.source {
        case .claude, .qoder, .codebuddy, .workbuddy:
            guard let origin = session.sourceApplication?.bundleIdentifier else {
                actionError = "这条消息的来源应用尚未识别，请在来源中开启新任务后重试。"
                openWorkbench?(); return
            }
            bundleID = origin
        case .codex:
            if let origin = session.sourceApplication?.bundleIdentifier { bundleID = origin }
            else { bundleID = resolveApplicationURL("com.openai.codex") != nil ? "com.openai.codex" : "com.openai.chat" }
        case .zcode:
            bundleID = session.sourceApplication?.bundleIdentifier ?? "dev.zcode.app"
        case .dsh:
            bundleID = session.sourceApplication?.bundleIdentifier ?? "com.deepseek.dsh"
        case .generic: openWorkbench?(); return
        }
        guard let application = resolveApplicationURL(bundleID) else {
            actionError = "未找到 \(session.sourceDisplayName)，请检查来源应用是否仍安装。"
            openWorkbench?(); return
        }
        // Previews contain synthetic session IDs and must never navigate to a
        // fabricated conversation. Preserve their existing local read feedback.
        if isPreview(session) {
            actionError = nil
            previewReducer.markRead(sessionKey: session.id); publish()
            openApplication(application)
            return
        }
        let conversation = SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: bundleID)
        let project = conversation == nil ? projectURL(for: session) : nil
        guard let destination = conversation ?? project else {
            actionError = nil
            openApplication(application)
            return
        }
        actionError = nil
        let revision = eventRevisions[session.id, default: 0]
        openDestination(destination, application) { [weak self] delivered in
            guard let self, self.navigationToken == token else { return }
            guard delivered else {
                self.actionError = "未能打开「\(session.displayTitle)」的\(conversation == nil ? "项目" : "会话")，已为你打开 \(session.sourceDisplayName)。"
                self.openApplication(application)
                self.openWorkbench?()
                return
            }
            // Delivery confirms the URL reached the source app, not that a
            // particular message rendered. Never consume a newer result while opening.
            if conversation != nil, self.eventRevisions[session.id, default: 0] == revision {
                self.reducer.markRead(sessionKey: session.id); self.publish()
            }
        }
    }

    struct SourceAttentionSnapshot {
        let bundleIdentifier: String
        let revisions: [String: UInt64]
        var isEmpty: Bool { revisions.isEmpty }
    }

    /// This is an app-level acknowledgement of existing finished reminders, not
    /// a claim that the source has reported an individual conversation as read.
    func captureFinishedReminders(for bundleIdentifier: String) -> SourceAttentionSnapshot {
        let eligible = settings.autoClearFinishedOnAppFocus ? reducer.sessionsByID.values.filter {
            canAcknowledge($0, in: bundleIdentifier)
        } : []
        return SourceAttentionSnapshot(bundleIdentifier: bundleIdentifier,
            revisions: Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, eventRevisions[$0.id, default: 0]) }))
    }

    func acknowledgeFinishedReminders(_ snapshot: SourceAttentionSnapshot) {
        guard settings.autoClearFinishedOnAppFocus else { return }
        var changed = false
        for (key, revision) in snapshot.revisions {
            guard eventRevisions[key, default: 0] == revision,
                  let session = reducer.sessionsByID[key],
                  canAcknowledge(session, in: snapshot.bundleIdentifier) else { continue }
            reducer.markRead(sessionKey: key)
            changed = true
        }
        if changed { publish() }
    }

    private func canAcknowledge(_ session: IslandSession, in bundleIdentifier: String) -> Bool {
        guard session.host == "localhost", session.unread,
              session.approval == nil, session.question == nil,
              let application = session.sourceApplication,
              application.provider == session.source,
              application.bundleIdentifier == bundleIdentifier else { return false }
        switch session.phase {
        case .idle, .completed, .failed, .interrupted: return true
        case .running, .waitingApproval, .waitingQuestion: return false
        }
    }

    func draft(for session: IslandSession) -> String { defaults.string(forKey: draftKey(session)) ?? "" }
    func saveDraft(_ value: String, session: IslandSession) { defaults.set(String(value.prefix(20_000)), forKey: draftKey(session)) }
    func clearDraft(session: IslandSession) { defaults.removeObject(forKey: draftKey(session)) }
    private func draftKey(_ session: IslandSession) -> String { "draft.\(session.id).\(session.question?.id ?? session.approval?.id ?? session.turnID ?? "none")" }
    private func isPreview(_ session: IslandSession) -> Bool {
        demoMode && previewReducer.sessionsByID[session.id] != nil && reducer.sessionsByID[session.id] == nil
    }
    private func publish() {
        let previews = demoMode ? Array(previewReducer.sessionsByID.values) : []
        sessions = (Array(reducer.sessionsByID.values) + previews).sorted { $0.updatedAt > $1.updatedAt }
    }
    func haptic() { if settings.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } }

    func endPreview() {
        demoMode = false
        previewReducer = SessionReducer()
        publish()
    }

    func loadPreview(_ phase: String) {
        guard waiters.isEmpty else { actionError = "请先处理当前权限请求，再进入预览。"; return }
        demoMode = true
        previewReducer = SessionReducer()
        let source: ProviderID = phase == "qoder" ? .qoder : .codex
        let sessionID = "preview-main"
        let request = "preview-request"
        var event = NormalizedHookEvent(source: source, sessionID: sessionID, threadID: "preview-thread", turnID: "preview-turn", kind: .started,
            title: "修复登录态刷新失败", agentName: "编程助手", cwd: "/Projects/account-service", detail: "检查 refresh-token.test.ts 的边界条件")
        if source == .qoder { event.sourceApplication = .qoderDesktop }
        previewReducer.apply(event)
        event.eventID = UUID().uuidString; event.timestamp = Date()
        switch phase {
        case "question", "expired":
            event.kind = .questionRequested
            event.question = QuestionRequest(id: request, prompt: "刷新令牌已过期时，希望如何处理？", options: ["要求重新登录", "自动延长有效期"], canAnswer: true,
                expiresAt: phase == "expired" ? Date().addingTimeInterval(-1) : nil)
        case "approval", "complex":
            event.kind = .approvalRequested
            event.approval = ApprovalRequest(id: request, toolName: phase == "complex" ? "FileChange" : "Bash",
                command: phase == "complex" ? nil : "npm test -- refresh-token.test.ts", cwd: "/Projects/account-service",
                summary: phase == "complex" ? "允许修改工作区外的文件？" : "运行登录模块的测试", canApprove: phase != "complex", canDeny: true)
        case "completed": event.kind = .completed; event.detail = "已修复刷新令牌处理，并补充边界测试。"
        case "failed": event.kind = .failed; event.detail = "接口测试未通过，请查看失败详情。"
        case "interrupted": event.kind = .interrupted; event.detail = "任务已停止，可返回会话继续。"
        case "idle": previewReducer = SessionReducer(); publish(); return
        default: break
        }
        previewReducer.apply(event)
        previewReducer.apply(NormalizedHookEvent(source: .qoder, sessionID: "preview-notes", kind: .started, title: "整理十月产品迭代说明", cwd: "/Projects/notes", detail: "正在汇总本周已完成的迭代记录", sourceApplication: .qoderDesktop))
        previewReducer.apply(NormalizedHookEvent(source: .codex, sessionID: "preview-settings", kind: .started, title: "调整通知设置的帮助说明", cwd: "/Projects/desktop", detail: "核对设置文案与默认状态"))
        publish()
    }
}
