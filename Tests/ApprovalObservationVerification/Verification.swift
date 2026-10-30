import Foundation
import IslandCore

private enum Failure: Error { case check(String) }

@main
struct ApprovalObservationVerification {
    @MainActor static var count = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.check(message) }
        count += 1
        print("PASS \(message)")
    }
    @MainActor static func main() async {
        do {
            let suite = "local.lingchongdao.approval-observation." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
            func send(_ name: String, session: String = "observation", stableID: String? = nil, extra: [String: JSONValue] = [:]) -> BridgeEnvelope {
                var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session),
                    "event_id": .string(UUID().uuidString), "title": .string("Approval observation fixture"),
                    "tool_name": .string("exec_command"), "permission_description": .string("Source permission review fixture")]
                if let stableID { raw["tool_use_id"] = .string(stableID) }
                raw.merge(extra) { _, new in new }
                return .init(provider: .codex, raw: .object(raw), deadline: Date().addingTimeInterval(2), sourceApplication: .codexDesktop)
            }
            _ = await model.handle(send("SessionStart"))
            let reply = await model.handle(send("PermissionRequest"))
            let session = model.sessions.first { $0.sessionID == "observation" }!
            try check(reply.disposition == .acknowledged, "No-ID permission event acknowledges immediately without a decision")
            try check(!session.hasPendingApproval && !session.isAwaitingInteraction,
                      "No-ID Codex permission observation must not become a user approval alert")
            try check(session.phase == .running && !session.unread && session.approval == nil,
                      "Permission observation preserves running work without an approval countdown")
            try check(!SessionStatusSummary.counts(for: model.visibleSessions).contains { $0.kind == .approval },
                      "Observation never increments the orange approval count")
            try check(SessionStatusSummary.counts(for: model.visibleSessions).first(where: { $0.kind == .running })?.count == 1,
                      "Existing running task remains in its green count")
            _ = await model.handle(send("PermissionRequest"))
            try check(model.sessions.filter { $0.sessionID == "observation" }.count == 1 && model.sessions.first?.isAwaitingInteraction == false,
                      "Repeated observations do not duplicate tasks or create attention")

            _ = await model.handle(send("Stop"))
            let stopped = model.sessions.first { $0.sessionID == "observation" }!
            _ = await model.handle(send("PermissionRequest"))
            let afterStop = model.sessions.first { $0.sessionID == "observation" }!
            try check(afterStop.phase == stopped.phase && afterStop.unread == stopped.unread && afterStop.approval == nil,
                      "Late observation cannot revive stopped work or invent another unread result")
            _ = await model.handle(send("SessionEnd"))
            _ = await model.handle(send("PermissionRequest"))
            try check(!model.visibleSessions.contains { $0.sessionID == "observation" },
                      "Late observation cannot resurrect a closed session")
            _ = await model.handle(send("PermissionRequest", session: "first-observed"))
            try check(!model.visibleSessions.contains { $0.sessionID == "first-observed" },
                      "An observation with no started task does not create phantom work")

            for terminal in ["TurnCompleted", "TurnFailed", "Interrupt"] {
                _ = await model.handle(send("SessionStart", session: terminal))
                _ = await model.handle(send(terminal, session: terminal, extra: ["status": .string("completed")]))
                let prior = model.sessions.first { $0.sessionID == terminal }!
                _ = await model.handle(send("PermissionRequest", session: terminal))
                let after = model.sessions.first { $0.sessionID == terminal }!
                try check(prior.phase == after.phase && prior.unread == after.unread && after.approval == nil,
                          "Permission observation preserves terminal state: " + terminal)
            }
            _ = await model.handle(send("SessionStart", session: "blank-id"))
            _ = await model.handle(send("PermissionRequest", session: "blank-id", stableID: "  \n  "))
            try check(model.sessions.first { $0.sessionID == "blank-id" }?.isAwaitingInteraction == false,
                      "Whitespace request IDs do not establish an approval channel")

            let contextFile = FileManager.default.temporaryDirectory.appendingPathComponent("lcd-user-review-" + UUID().uuidString + ".jsonl")
            defer { try? FileManager.default.removeItem(at: contextFile) }
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"live\"}}\n{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"live-turn\",\"approvals_reviewer\":\"user\",\"approval_policy\":\"on-request\"}}\n".utf8).write(to: contextFile)
            let liveEnvelope = send("PermissionRequest", session: "live", stableID: "verified-request", extra: ["transcript_path": .string(contextFile.path), "turn_id": .string("live-turn")])
            let pending = Task { await model.handle(liveEnvelope) }
            for _ in 0..<100 {
                if model.sessions.contains(where: { $0.sessionID == "live" && $0.hasPendingApproval }) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let live = model.sessions.first { $0.sessionID == "live" }!
            try check(live.hasPendingApproval && live.approval?.canDeny == true,
                      "A verified request still waits for an actual decision")
            try check(SessionStatusSummary.counts(for: model.visibleSessions).first(where: { $0.kind == .approval })?.count == 1,
                      "Only the verified live request contributes an orange count")
            _ = await model.handle(send("PermissionRequest", session: "live"))
            try check(model.sessions.first { $0.sessionID == "live" }?.approval?.id == "verified-request",
                      "An unverified observation cannot replace a live approval")
            _ = await model.handle(send("PreToolUse", session: "live", stableID: "verified-request"))
            try check(model.sessions.first { $0.sessionID == "live" }?.hasPendingApproval == true,
                      "Pre-tool activity does not guess that the real approval has resolved")
            _ = await model.handle(send("PostToolUse", session: "live", stableID: "verified-request"))
            let resolved = await pending.value
            try check(resolved.disposition == .fallback && model.sessions.first { $0.sessionID == "live" }?.approval == nil,
                      "Confirmed tool progress resolves only its matching approval without allow or deny")

            _ = await model.handle(send("UserQuestion", session: "question", extra: ["question": .string("Question fixture")]))
            let originalQuestion = model.sessions.first { $0.sessionID == "question" }!.question!.id
            _ = await model.handle(send("PermissionRequest", session: "question"))
            try check(model.sessions.first { $0.sessionID == "question" }?.question?.id == originalQuestion && model.sessions.first { $0.sessionID == "question" }?.hasPendingQuestion == true,
                      "Permission observation does not discard a real source question")
            print("PASS: \(count) approval observation checks; synthetic AppModel only")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1)
        }
    }
}
