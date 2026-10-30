import Foundation
import Darwin
import IslandCore

private struct Failure: Error { let message: String }
private var count = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(message: message) }
    count += 1; print("PASS \(message)")
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(message: message) }
    return value
}

@MainActor
private func waitUntil(_ predicate: () -> Bool, _ message: String) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw Failure(message: "Timed out: " + message)
}

@main struct ExpiredRequestVerification {
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data("FAIL expired-request verification: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func verify() async throws {
        let suite = "local.lingchongdao.expiry-tests." + UUID().uuidString
        let defaults = try unwrap(UserDefaults(suiteName: suite), "Cannot create isolated preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let review = try CodexReviewFixture()
        defer { review.cleanup() }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        defer { model.stopBridge() }
        func envelope(_ name: String, session: String, request: String? = nil, expires: Date? = nil) throws -> BridgeEnvelope {
            var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session),
                "turn_id": .string("turn-" + session), "event_id": .string(UUID().uuidString), "title": .string("Expiry regression fixture")]
            if let request {
                raw["tool_use_id"] = .string(request); raw["tool_name"] = .string("Bash")
                raw["tool_input"] = .object(["command": .string("pwd")])
                if name == "PermissionRequest" {
                    raw.merge(try review.metadata(sessionID: session, turnID: "turn-" + session)) { _, value in value }
                }
            }
            if let expires { raw["expires_at"] = .number(expires.timeIntervalSince1970) }
            return BridgeEnvelope(provider: .codex, raw: .object(raw), sourceApplication: .codexDesktop)
        }
        // Directly exercise the path that produced the user's screenshot.
        _ = await model.handle(try envelope("PermissionRequest", session: "expired", request: "past", expires: Date().addingTimeInterval(-10)))
        try check(!model.visibleSessions.contains { $0.sessionID == "expired" }, "An already expired approval never enters island attention")
        let history = try unwrap(model.sessions.first { $0.sessionID == "expired" }, "Expected retained expired approval history")
        try check(history.approval?.isExpired() == true && history.approval?.canApprove == false && history.approval?.canDeny == false,
                  "Expired history keeps its request and disables both actions")
        try check(!history.unread && history.phase == .idle, "Expired request history is no longer waiting or unread")
        _ = await model.handle(try envelope("PermissionRequest", session: "status-only", expires: Date().addingTimeInterval(60)))
        let observed = try unwrap(model.sessions.first { $0.sessionID == "status-only" }, "Expected a status-only permission observation")
        try check(!observed.isAwaitingInteraction && observed.approval == nil && !model.visibleSessions.contains { $0.id == observed.id },
                  "An unverified Codex permission observation creates no phantom user todo")
        _ = await model.handle(try envelope("UserQuestion", session: "question", expires: Date().addingTimeInterval(-10)))
        try check(!model.visibleSessions.contains { $0.sessionID == "question" }, "Expired questions also leave the attention list")
        let question = try unwrap(model.sessions.first { $0.sessionID == "question" }, "Expected retained expired question history")
        model.saveDraft("Preserved draft", session: question)
        try check(model.draft(for: question) == "Preserved draft", "Removing expired attention preserves request drafts")
        let waitingEvent = try envelope("PermissionRequest", session: "waiting", request: "live", expires: Date().addingTimeInterval(20))
        let waiting = Task { await model.handle(waitingEvent) }
        try await waitUntil({ model.sessions.contains { $0.sessionID == "waiting" && $0.approval?.id == "live" } }, "Live approval arrived")
        try check(model.visibleSessions.contains { $0.sessionID == "waiting" && $0.approval?.canDeny == true }, "A valid live approval remains actionable")
        _ = await model.handle(try envelope("PostToolUse", session: "waiting", request: "unrelated"))
        try check(model.visibleSessions.contains { $0.sessionID == "waiting" && $0.approval?.id == "live" }, "An unrelated tool result cannot clear a live approval")
        _ = await model.handle(try envelope("PostToolUse", session: "waiting", request: "live"))
        let reply = await waiting.value
        try check(reply.disposition == .fallback, "A matching source result returns the pending transport to source handling")
        try check(model.sessions.first { $0.sessionID == "waiting" }?.approval == nil, "Matching source progress clears the resolved request")
        let now = Date()
        var reducer = SessionReducer()
        let event = NormalizedHookEvent(source: .qoder, sessionID: "timer", timestamp: now, kind: .approvalRequested,
            approval: ApprovalRequest(id: "one", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: now.addingTimeInterval(1)))
        reducer.apply(event)
        try check(reducer.sessions.count == 1, "An unexpired request is initially visible")
        reducer.expireRequests(at: now.addingTimeInterval(2))
        try check(reducer.sessions.isEmpty && reducer.sessionsByID[event.sessionKey]?.approval != nil, "Timer expiry removes attention while retaining history")
        try check(!reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "one", decision: .allow), "A timed-out approval cannot later allow")
        reducer.apply(NormalizedHookEvent(source: .qoder, sessionID: "timer", timestamp: now.addingTimeInterval(3), kind: .activity))
        reducer.expireRequests(at: now.addingTimeInterval(4))
        try check(reducer.sessionsByID[event.sessionKey]?.phase == .running && reducer.sessions.first?.phase == .running,
                  "New source progress is not rolled back by repeated expiry cleanup")
        reducer.apply(NormalizedHookEvent(source: .qoder, sessionID: "timer", timestamp: now.addingTimeInterval(5), kind: .approvalRequested,
            approval: ApprovalRequest(id: "two", toolName: "Bash", canApprove: false, canDeny: true, expiresAt: now.addingTimeInterval(60))))
        reducer.expireApproval(sessionKey: event.sessionKey, requestID: "one", at: now.addingTimeInterval(6))
        try check(reducer.sessionsByID[event.sessionKey]?.approval?.id == "two" && reducer.sessions.first?.approval?.canDeny == true,
                  "An old expiration cannot touch a newer deny-only request")
        let livePriority = try unwrap(reducer.sessions.first, "Expected the newer pending approval").priority
        try check(history.priority > livePriority, "Expired history never keeps approval priority")
        print("\(count) expired-request checks passed. No real approvals or source configuration were changed.")
    }
}
