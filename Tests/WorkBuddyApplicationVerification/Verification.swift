import Foundation
import Darwin
import IslandCore

private struct Failure: Error { let message: String }

@main
struct WorkBuddyApplicationVerification {
    static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        checks += 1
    }

    @MainActor static func main() async {
        do {
            try await verify()
            print("PASS: \(checks) WorkBuddy application checks (isolated synthetic events; no source writes)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func verify() async throws {
        let suite = "local.lingchongdao.workbuddy-verification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.autoClearFinishedOnAppFocus = true
        let model = AppModel(settings: settings, defaults: defaults)
        defer { model.stopBridge() }
        let id = "A1234567-B89C-4DEF-8123-456789ABCDEF"
        let bundle = "com.tencent.workbuddy.mac"
        func envelope(_ name: String, turn: String = "one", extra: [String: JSONValue] = [:]) -> BridgeEnvelope {
            var raw: [String: JSONValue] = ["session_id": .string(id), "turn_id": .string(turn),
                "hook_event_name": .string(name), "event_id": .string(UUID().uuidString),
                "cwd": .string("/private/tmp/workbuddy-verification"), "session_title": .string("WorkBuddy P0 verification")]
            raw.merge(extra) { _, value in value }
            return BridgeEnvelope(provider: .workbuddy, raw: .object(raw), sourceApplication: .workbuddyDesktop)
        }
        _ = await model.handle(envelope("UserPromptSubmit", extra: ["prompt": .string("First request")]))
        try check(model.visibleSessions.count == 1 && model.visibleSessions[0].phase == .running, "prompt starts visible work")
        _ = await model.handle(envelope("PreToolUse", extra: ["tool_name": .string("AskQuestion"),
            "tool_use_id": .string("question-one"), "tool_input": .object(["question": .string("Choose A or B")]),
            "expires_at": .number(Date().addingTimeInterval(-1).timeIntervalSince1970)]))
        guard let uncertain = model.visibleSessions.first else { throw Failure(message: "expired observation disappeared") }
        try check(uncertain.needsStatusVerification && !uncertain.hasPendingQuestion, "expired observation stays visible without claiming a live request")
        try check(model.workbenchSessions.contains { $0.id == uncertain.id }, "unverified state remains in inbox")
        try check(model.captureFinishedReminders(for: bundle).isEmpty, "foreground visit cannot consume unresolved observation")
        var openedURL: URL?
        model.resolveApplicationURL = { _ in URL(fileURLWithPath: "/private/tmp/WorkBuddy.app") }
        model.openApplication = { _ in }
        model.openDestination = { url, _, done in openedURL = url; done(true) }
        model.navigate(to: uncertain)
        try check(openedURL?.absoluteString == "workbuddy://chat/" + id, "unverified observation can return to its exact conversation")
        try check(model.visibleSessions.first?.needsStatusVerification == true, "opening source does not claim the question was answered")
        _ = await model.handle(envelope("PostToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("unrelated")]))
        try check(model.visibleSessions.first?.needsStatusVerification == true, "unrelated activity cannot clear uncertainty")
        _ = await model.handle(envelope("PostToolUse", extra: ["tool_name": .string("AskQuestion"), "tool_use_id": .string("question-one")]))
        try check(model.visibleSessions.first?.phase == .running && model.visibleSessions.first?.question == nil, "matching result resumes normal activity")
        _ = await model.handle(envelope("Stop", extra: ["last_assistant_message": .string("P0 result: the document is ready.")]))
        try check(model.visibleSessions.first?.detail.contains("the document is ready") == true, "provided reply is visible as a summary")
        try check(model.visibleSessions.first?.phase == .idle && model.visibleSessions.first?.unread == true, "Stop is unread ended turn, not inferred success")
        _ = await model.handle(envelope("SessionEnd"))
        try check(model.visibleSessions.first?.unread == true && model.visibleSessions.first?.detail.contains("the document is ready") == true,
                  "SessionEnd preserves unread result and summary")
        let snapshot = model.captureFinishedReminders(for: bundle)
        _ = await model.handle(envelope("UserPromptSubmit", turn: "two", extra: ["prompt": .string("Follow-up")]))
        model.acknowledgeFinishedReminders(snapshot)
        try check(model.visibleSessions.first?.phase == .running && model.visibleSessions.first?.question == nil, "follow-up clears old interactions and survives old acknowledgement")
        _ = await model.handle(envelope("Stop", turn: "one", extra: ["last_assistant_message": .string("stale result")]))
        try check(model.visibleSessions.first?.phase == .running && model.visibleSessions.first?.detail != "stale result", "old turn cannot replace new work")
        _ = await model.handle(envelope("Stop", turn: "two", extra: ["last_assistant_message": .string("Second reply")]))
        model.openDestination = { _, _, done in done(false) }
        model.navigate(to: model.visibleSessions[0])
        try check(model.visibleSessions.first?.unread == true && model.actionError != nil, "failed navigation keeps unread result")
        try check(model.dismiss(model.visibleSessions[0]) && model.visibleSessions.isEmpty, "manual dismissal closes the result")
        let nativeID = "B1234567-B89C-4DEF-8123-456789ABCDEF"
        _ = await model.handle(envelope("UserPromptSubmit", extra: ["session_id": .string(nativeID)]))
        let native = envelope("Notification", extra: ["session_id": .string(nativeID),
            "notification_type": .string("permission_prompt"), "message": .string("CodeBuddy needs your permission to use AskUserQuestion")])
        let nativeReply = await model.handle(BridgeEnvelope(provider: native.provider, raw: native.raw,
            deadline: Date().addingTimeInterval(2), sourceApplication: .workbuddyDesktop))
        guard let nativeWaiting = model.visibleSessions.first(where: { $0.sessionID == nativeID }) else { throw Failure(message: "missing native wait") }
        try check(nativeReply.disposition == .acknowledged && nativeWaiting.hasPendingApproval,
                  "source notification creates observation only and returns immediately")
        try check(nativeWaiting.approval?.canApprove == false && nativeWaiting.approval?.canDeny == false,
                  "native notification never exposes an approval reply")
        try check((nativeWaiting.approval?.expiresAt?.timeIntervalSinceNow ?? 0) > 100,
                  "two-second observation transport cannot expire the source wait")
        try check(SessionStatusKind(session: nativeWaiting) == .sourceInput,
                  "native confirmation or question counts as source input, not an island approval")
        try check(model.captureFinishedReminders(for: bundle).isEmpty, "source focus cannot consume the native wait")
        _ = await model.handle(envelope("PreToolUse", extra: ["session_id": .string(nativeID),
            "tool_name": .string("Read"), "tool_use_id": .string("parallel-read")]))
        try check(model.visibleSessions.first { $0.sessionID == nativeID }?.hasPendingApproval == true,
                  "unrelated parallel tool activity cannot resolve native waiting")
        _ = await model.handle(envelope("Stop", extra: ["session_id": .string(nativeID), "last_assistant_message": .string("Native turn ended")]))
        try check(model.visibleSessions.first { $0.sessionID == nativeID }?.phase == .idle,
                  "explicit turn end retires the native wait")
    }
}
