import Foundation

public struct SessionReducer: Sendable {
    public private(set) var sessionsByID: [String: IslandSession] = [:]
    private var hookApprovals: [String: [ApprovalRequest]] = [:]
    private var codexQuestions: [String: [QuestionRequest]] = [:]
    private var seenEvents: Set<String> = []
    private var eventOrder: [String] = []
    public init() {}
    public var sessions: [IslandSession] {
        sessionsByID.values.filter { $0.isVisibleOnIsland }
            .sorted { $0.priority == $1.priority ? ($0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt) : $0.priority < $1.priority }
    }

    private mutating func applyCodexQuestions(_ event: NormalizedHookEvent, session: inout IslandSession) -> Bool? {
        guard event.source == .codex else { return nil }
        switch event.kind {
        case .questionRequested:
            guard let request = event.question else { return false }
            var queue = codexQuestions[session.id] ?? []
            queue.removeAll { $0.id == request.id || $0.isExpired(at: event.timestamp) }
            queue.append(request)
            codexQuestions[session.id] = queue
        case .questionResolved:
            var queue = codexQuestions[session.id] ?? []
            if let answers = event.answeredQuestionItemIDs {
                let answered = Set(answers)
                guard queue.contains(where: { !answered.isDisjoint(with: $0.responseItemIDs ?? []) }) else { return false }
                for index in queue.indices {
                    if let ids = queue[index].responseItemIDs { queue[index].responseItemIDs = ids.filter { !answered.contains($0) } }
                }
                queue.removeAll { $0.responseItemIDs?.isEmpty == true }
            } else if let id = event.interactionID {
                guard queue.contains(where: { $0.id == id }) else { return false }
                queue.removeAll { $0.id == id }
            } else { return false }
            codexQuestions[session.id] = queue
            session.question = nil
            if session.phase == .waitingQuestion { session.phase = .running; session.unread = false }
        case .turnStopped, .completed:
            // Async questions survive a finished assistant turn; their answers
            // arrive later as UserPromptSubmit, not as a tool result.
            codexQuestions[session.id]?.removeAll { $0.responseItemIDs == nil }
            guard !(codexQuestions[session.id] ?? []).isEmpty else { return nil }
            session.approval = nil
        case .started, .sessionEnded, .failed, .interrupted:
            codexQuestions.removeValue(forKey: session.id)
            return nil
        default: return nil
        }
        if let request = codexQuestions[session.id]?.first, !session.hasPendingApproval {
            session.question = request; session.phase = .waitingQuestion; session.unread = true; session.detail = request.prompt
        }
        return true
    }

    private func restoreCodexQuestion(_ session: inout IslandSession) {
        guard session.source == .codex, !session.hasPendingApproval,
              let request = codexQuestions[session.id]?.first, !request.isExpired() else { return }
        session.question = request; session.phase = .waitingQuestion; session.unread = true; session.detail = request.prompt
    }
    /// Sources can issue parallel permission hooks inside one session. Each live
    /// socket remains independent, while the UI shows one request at a time.
    public func pendingApprovalIDs(sessionKey: String) -> Set<String> {
        if let queue = hookApprovals[sessionKey] {
            return Set(queue.filter { !$0.isExpired() }.map(\.id))
        }
        guard let session = sessionsByID[sessionKey], session.hasPendingApproval, let request = session.approval else { return [] }
        return [request.id]
    }

    private mutating func syncHookApprovals(_ session: inout IslandSession, emptyPhase: SessionPhase = .running) {
        let queue = hookApprovals[session.id] ?? []
        session.approval = queue.first
        if let first = queue.first {
            session.phase = .waitingApproval; session.unread = true; session.detail = first.summary
        } else {
            hookApprovals.removeValue(forKey: session.id)
            session.phase = session.hasPendingQuestion ? .waitingQuestion : emptyPhase
            session.unread = false
        }
    }

    private mutating func applyHookApprovals(_ event: NormalizedHookEvent, session: inout IslandSession) -> Bool {
        guard event.source == .claude || ([ProviderID.codex, .qoder].contains(event.source) &&
            (hookApprovals[session.id] != nil || (event.source == .qoder && event.kind == .permissionPrompted) ||
             (event.kind == .approvalRequested && event.approval.flatMap { UUID(uuidString: $0.id) } != nil))) else { return false }
        switch event.kind {
        case .approvalRequested:
            guard let request = event.approval else { return false }
            var queue = hookApprovals[session.id] ?? []
            // An actual hook supersedes coarse source notifications, never
            // another live hook. Identical commands still have independent IDs.
            queue.removeAll { (!$0.canApprove && !$0.canDeny) || $0.isExpired() }
            if !queue.contains(where: { $0.id == request.id }) { queue.append(request) }
            hookApprovals[session.id] = queue
            session.question = nil
            syncHookApprovals(&session)
            return true
        case .permissionPrompted:
            guard session.phase == .running || session.phase == .waitingApproval || session.phase == .waitingQuestion else { return true }
            if (hookApprovals[session.id] ?? []).isEmpty, let request = event.approval {
                hookApprovals[session.id] = [request]
            }
            syncHookApprovals(&session)
            return true
        case .activity:
            guard var queue = hookApprovals[session.id], !queue.isEmpty else { return false }
            if event.source == .qoder, let resolvedID = event.interactionID,
               queue.contains(where: { $0.id == resolvedID }) {
                queue.removeAll { $0.id == resolvedID }
                hookApprovals[session.id] = queue
                syncHookApprovals(&session)
                return !queue.isEmpty
            }
            // Parallel tool activity is not evidence that Qoder's pending
            // permission was answered. Wait for its paired result or main Stop.
            if event.source == .qoder { syncHookApprovals(&session); return true }
            // A fresh main-session tool event can dismiss a coarse notification.
            // It cannot dismiss a live hook, including a subagent's hook.
            if !event.isSubagent && queue.allSatisfy({ !$0.canApprove && !$0.canDeny }) {
                hookApprovals.removeValue(forKey: session.id)
                syncHookApprovals(&session)
                return false
            }
            syncHookApprovals(&session)
            return true
        case .started:
            if !event.isSubagent { hookApprovals.removeValue(forKey: session.id) }
        case .turnStopped:
            if !event.isSubagent {
                // Qoder's main Stop follows the source-native interaction and
                // closes this turn. Its stale hook must not outlive the turn.
                hookApprovals[session.id]?.removeAll { event.source == .qoder || (!$0.canApprove && !$0.canDeny) }
                if !(hookApprovals[session.id] ?? []).isEmpty { syncHookApprovals(&session); return true }
                hookApprovals.removeValue(forKey: session.id)
            }
        case .sessionEnded, .failed, .interrupted, .completed:
            if !event.isSubagent { hookApprovals.removeValue(forKey: session.id) }
        default: break
        }
        return false
    }

    @discardableResult public mutating func apply(_ event: NormalizedHookEvent) -> Bool {
        let uniqueID = event.sessionKey + ":" + event.eventID
        guard !seenEvents.contains(uniqueID) else { return false }
        seenEvents.insert(uniqueID); eventOrder.append(uniqueID)
        if eventOrder.count > 4096 { seenEvents.remove(eventOrder.removeFirst()) }
        var session = sessionsByID[event.sessionKey] ?? IslandSession(source: event.source, host: event.host, sessionID: event.sessionID, threadID: event.threadID, title: event.isSubagent ? "" : (SessionTitle.normalize(event.title) ?? ""), updatedAt: event.timestamp, sourceApplication: event.sourceApplication)
        guard event.timestamp >= session.updatedAt else { return false }
        // A delayed event from an earlier known turn cannot resolve a new turn/request.
        if let currentTurn = session.turnID, let turn = event.turnID, currentTurn != turn, event.kind != .started,
           !(event.source == .codex && event.answeredQuestionItemIDs != nil) { return false }
        if !event.isSubagent, let title = SessionTitle.normalize(event.title) {
            session.title = title
        }
        if let agent = event.agentName { session.agentName = agent }
        if let cwd = event.cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !event.isSubagent || session.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.cwd = cwd }
        }
        if let detail = event.detail, event.kind != .sessionResumed { session.detail = detail }
        // Codex keeps its existing session key when moving between desktop and CLI. Each
        // accepted main-session event must refresh its verified app ownership;
        // missing evidence clears ownership instead of inheriting a desktop app.
        if event.source == .codex && !event.isSubagent { session.sourceApplication = event.sourceApplication }
        session.updatedAt = event.timestamp
        if let turn = event.turnID { session.turnID = turn }
        if applyHookApprovals(event, session: &session) {
            sessionsByID[session.id] = session; return true
        }
        if event.isSubagent {
            // Child updates can enrich activity, but do not resolve or terminate the main session.
            sessionsByID[session.id] = session; return true
        }
        if let accepted = applyCodexQuestions(event, session: &session) {
            guard accepted else { return false }
            restoreCodexQuestion(&session)
            sessionsByID[session.id] = session; return true
        }
        switch event.kind {
        case .started: session.phase = .running; session.unread = false; session.approval = nil; session.question = nil
        case .activity:
            if let interaction = event.interactionID, interaction == session.approval?.id { session.approval = nil }
            // Retained expired requests are history, not a barrier to new activity.
            // A live request still requires its exact interaction ID to resolve.
            if !session.hasPendingApproval { session.approval = nil }
            if !session.hasPendingQuestion { session.question = nil }
            if !session.isAwaitingInteraction { session.phase = .running }
        case .permissionPrompted: break
        case .permissionObserved:
            // Permission telemetry cannot create attention, resolve a real
            // interaction, or resurrect work that already reached a terminal state.
            break
        case .sessionResumed:
            // Reopening a finished transcript (source == "resume") is browsing, not
            // work; real activity re-surfaces the session via UserPromptSubmit and
            // tool events, which still arrive as .started/.activity.
            break
        case .approvalRequested:
            guard let approval = event.approval else { return false }
            session.approval = approval; session.question = nil; session.phase = .waitingApproval; session.unread = true
        case .questionRequested:
            guard let question = event.question else { return false }
            session.question = question; session.approval = nil; session.phase = .waitingQuestion; session.unread = true
        case .approvalResolved:
            guard let interaction = event.interactionID, interaction == session.approval?.id else { return false }
            session.approval = nil; session.phase = .running
        case .questionResolved:
            guard let interaction = event.interactionID, interaction == session.question?.id else { return false }
            session.question = nil; session.phase = .running
        case .turnStopped: session.approval = nil; session.question = nil; session.phase = .idle; session.unread = true
        case .sessionEnded: session.approval = nil; session.question = nil; session.phase = .idle; session.unread = false
        case .completed: session.approval = nil; session.question = nil; session.phase = .completed; session.unread = true
        case .failed: session.approval = nil; session.question = nil; session.phase = .failed; session.unread = true
        case .interrupted: session.approval = nil; session.question = nil; session.phase = .interrupted; session.unread = true
        }
        if !(hookApprovals[session.id] ?? []).isEmpty, !session.hasPendingQuestion {
            syncHookApprovals(&session)
        }
        restoreCodexQuestion(&session)
        sessionsByID[session.id] = session
        return true
    }
    @discardableResult public mutating func resolveApproval(sessionKey: String, requestID: String, decision: ApprovalDecision) -> Bool {
        if var session = sessionsByID[sessionKey], session.source == .claude || hookApprovals[sessionKey] != nil {
            guard var queue = hookApprovals[sessionKey], let request = queue.first(where: { $0.id == requestID }),
                  !request.isExpired(), decision != .allow || request.canApprove, decision != .deny || request.canDeny else { return false }
            queue.removeAll { $0.id == requestID }
            if decision == .fallback, queue.isEmpty {
                var observation = request
                observation.id = session.source.rawValue + "-source-" + request.id
                observation.canApprove = false; observation.canDeny = false
                let name = session.source == .codex ? "Codex" : session.source == .qoder ? "Qoder" : "Claude"
                observation.summary = "\(name) 正在等待权限确认，请回来源处理。"
                observation.expiresAt = Date().addingTimeInterval(110)
                queue.append(observation)
            }
            hookApprovals[sessionKey] = queue
            syncHookApprovals(&session)
            restoreCodexQuestion(&session)
            sessionsByID[sessionKey] = session
            return true
        }
        guard var session = sessionsByID[sessionKey], let request = session.approval, request.id == requestID, !request.isExpired(), decision != .allow || request.canApprove, decision != .deny || request.canDeny else { return false }
        session.approval = nil; session.phase = decision == .fallback ? .idle : .running; session.unread = false
        restoreCodexQuestion(&session)
        sessionsByID[sessionKey] = session; return true
    }
    /// Manual dismissal hides the row on the island while keeping the session
    /// record, so a later event resurfaces it. Running work only yields to the
    /// explicit swipe path (`force`); a live approval or question never does.
    @discardableResult public mutating func dismissSession(sessionKey: String, force: Bool = false) -> Bool {
        guard var session = sessionsByID[sessionKey] else { return false }
        if !force, session.phase == .running { return false }
        if let approval = session.approval, !approval.isExpired() {
            guard [ProviderID.claude, .codex, .qoder].contains(session.source), !approval.canApprove && !approval.canDeny,
                  !(hookApprovals[sessionKey] ?? []).contains(where: { $0.canApprove || $0.canDeny }) else { return false }
            hookApprovals.removeValue(forKey: sessionKey)
        }
        if let question = session.question, !question.isExpired() { return false }
        session.approval = nil; session.question = nil; session.phase = .idle; session.unread = false; sessionsByID[sessionKey] = session
        return true
    }
    public mutating func markRead(sessionKey: String) { guard var session = sessionsByID[sessionKey] else { return }; session.unread = false; sessionsByID[sessionKey] = session }
    /// Preserve request history and drafts, while removing expired interactions from the island.
    public mutating func expireApproval(sessionKey: String, requestID: String, at date: Date = Date()) {
        if var session = sessionsByID[sessionKey], var queue = hookApprovals[sessionKey] {
            guard queue.contains(where: { $0.id == requestID }) else { return }
            queue.removeAll { $0.id == requestID }
            hookApprovals[sessionKey] = queue
            syncHookApprovals(&session, emptyPhase: .idle)
            restoreCodexQuestion(&session)
            sessionsByID[sessionKey] = session
            return
        }
        guard var session = sessionsByID[sessionKey], var approval = session.approval, approval.id == requestID else { return }
        approval.expiresAt = min(approval.expiresAt ?? date, date); approval.canApprove = false; approval.canDeny = false; session.approval = approval
        if session.phase == .waitingApproval { session.phase = .idle; session.unread = false; session.detail = "请求已失效，请回原工具处理。" }
        restoreCodexQuestion(&session)
        sessionsByID[sessionKey] = session
    }
    public mutating func expireRequests(at date: Date = Date()) {
        for key in Array(sessionsByID.keys) {
            guard var session = sessionsByID[key] else { continue }
            if hookApprovals[key] != nil {
                for request in hookApprovals[key] ?? [] where request.isExpired(at: date) {
                    expireApproval(sessionKey: key, requestID: request.id, at: date)
                }
                session = sessionsByID[key] ?? session
            }
            if let approval = session.approval, approval.isExpired(at: date) { expireApproval(sessionKey: key, requestID: approval.id, at: date); session = sessionsByID[key] ?? session }
            if var question = session.question, question.isExpired(at: date) {
                question.canAnswer = false; session.question = question
                if session.phase == .waitingQuestion { session.phase = .idle; session.unread = false }
                sessionsByID[key] = session
            }
        }
    }
}
