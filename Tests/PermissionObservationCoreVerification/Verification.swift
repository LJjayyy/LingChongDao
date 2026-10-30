import Foundation

private enum VerificationFailure: Error { case failed(String) }

@main
private struct PermissionObservationCoreVerification {
    static func main() throws {
        var count = 0
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw VerificationFailure.failed(message) }
            count += 1
        }
        func event(_ provider: ProviderID = .codex, fields: [String: JSONValue] = [:]) throws -> NormalizedHookEvent {
            var raw: [String: JSONValue] = ["hook_event_name": .string("PermissionRequest"), "session_id": .string("fixture"),
                "event_id": .string(UUID().uuidString), "tool_name": .string("Bash"), "cwd": .string("/tmp"),
                "permission_description": .string("Source review"), "tool_input": .object(["command": .string("pwd")])]
            raw.merge(fields) { _, new in new }
            return try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(JSONValue.object(raw)), provider: provider)
        }
        let observed = try event()
        try require(observed.kind == .permissionObserved && observed.approval == nil && observed.question == nil, "No-ID Codex permission is only an observation")
        try require(observed.detail?.hasPrefix("来源权限检查：") == true, "Observation is neutrally labelled")
        try require(HookOutput.response(for: .init(disposition: .allow), event: observed) == .object([:]), "An observed request cannot return allow")
        try require(HookOutput.response(for: .init(disposition: .deny), event: observed) == .object([:]), "An observed request cannot return deny")
        let keys = ["tool_use_id", "tool_call_id", "permission_request_id", "request_id", "call_id"]
        for key in keys {
            let blank = try event(fields: [key: .string(" \n\t")])
            try require(blank.kind == .permissionObserved && blank.approval == nil, "Blank correlation ID is not interactive: " + key)
            let live = try event(fields: [key: .string("real-request")])
            try require(live.kind == .approvalRequested && live.approval?.id == "real-request" && live.approval?.canApprove == true && live.approval?.canDeny == true,
                        "Existing valid ID preserves interactive request: " + key)
        }
        let fallbackKey = try event(fields: ["tool_use_id": .string(" "), "call_id": .string("fallback-real")])
        try require(fallbackKey.approval?.id == "fallback-real" && fallbackKey.approval?.canDeny == true, "Usable later ID is not masked by an earlier whitespace value")
        let complex = try event(fields: ["tool_use_id": .string("complex"), "tool_name": .string("exec_command"), "reason": .string("Needs review")])
        try require(complex.kind == .approvalRequested && complex.approval?.canApprove == false && complex.approval?.canDeny == true, "Verified complex request keeps its deny-only contract")
        let sensitive = try event(fields: ["permission_description": .string("API_TOKEN=fixture-only")])
        try require(sensitive.kind == .permissionObserved && sensitive.detail?.contains("fixture-only") == false, "Observation detail keeps sensitive-text redaction")
        for provider in [ProviderID.qoder, .codebuddy, .workbuddy, .generic] {
            let unchanged = try event(provider)
            try require(unchanged.kind == .approvalRequested && unchanged.approval != nil, "Other provider no-ID behavior is preserved: " + provider.rawValue)
        }
        let now = Date().addingTimeInterval(-100)
        var first = SessionReducer()
        var observation = observed
        observation.timestamp = now.addingTimeInterval(1)
        try require(first.apply(observation) && first.sessions.isEmpty, "Observation-first session stays hidden")
        try require(first.sessionsByID[observed.sessionKey]?.phase == .idle && first.sessionsByID[observed.sessionKey]?.unread == false, "Observation-first session is not running or unread")
        first.apply(.init(source: .codex, sessionID: "fixture", timestamp: now, kind: .started))
        try require(first.sessions.isEmpty, "A stale earlier start is still rejected")
        first.apply(.init(source: .codex, sessionID: "fixture", timestamp: now.addingTimeInterval(2), kind: .started))
        try require(first.sessions.first?.phase == .running, "A later real start becomes visible normally")
        let terminalKinds: [(HookEventKind, SessionPhase)] = [(.turnStopped, .idle), (.sessionEnded, .idle), (.completed, .completed), (.failed, .failed), (.interrupted, .interrupted)]
        for (kind, phase) in terminalKinds {
            var reducer = SessionReducer()
            reducer.apply(.init(source: .codex, sessionID: "fixture", timestamp: now, kind: kind))
            let unread = reducer.sessionsByID[observed.sessionKey]!.unread
            reducer.apply(observation)
            let session = reducer.sessionsByID[observed.sessionKey]!
            try require(session.phase == phase && session.unread == unread && session.approval == nil,
                        "Observation does not resurrect or mark terminal work unread: " + kind.rawValue)
        }
        var running = SessionReducer()
        running.apply(.init(source: .codex, sessionID: "fixture", timestamp: now, kind: .started))
        running.apply(observation)
        try require(running.sessions.first?.phase == .running && running.sessions.first?.isAwaitingInteraction == false, "Running work stays running without attention")
        try require(!SessionStatusSummary.counts(for: running.sessions).contains { $0.kind == .approval }, "Observation adds no orange approval count")
        var approval = SessionReducer()
        let pending = ApprovalRequest(id: "live", toolName: "Bash", canApprove: true, canDeny: true)
        approval.apply(.init(source: .codex, sessionID: "fixture", timestamp: now, kind: .approvalRequested, approval: pending))
        approval.apply(observation)
        try require(approval.sessions.first?.phase == .waitingApproval && approval.sessions.first?.approval == pending && approval.sessions.first?.unread == true, "Observation preserves a real pending approval")
        var question = SessionReducer()
        let pendingQuestion = QuestionRequest(id: "question", prompt: "Which option?")
        question.apply(.init(source: .codex, sessionID: "fixture", timestamp: now, kind: .questionRequested, question: pendingQuestion))
        question.apply(observation)
        try require(question.sessions.first?.phase == .waitingQuestion && question.sessions.first?.question == pendingQuestion && question.sessions.first?.unread == true, "Observation preserves a real pending question")
        print("PASS: \(count) permission observation core checks; no real approvals or source settings changed")
    }
}
