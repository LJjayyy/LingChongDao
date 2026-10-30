import Foundation
import IslandCore

struct VerificationFailure: Error { let message: String }
@main struct CodexApprovalVerification {
    @MainActor static var checks = 0
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw VerificationFailure(message: message) }
        checks += 1
    }
    @MainActor static func until(_ predicate: () -> Bool, message: String) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VerificationFailure(message: message)
    }
    struct Helper {
        let process: Process
        let output: Pipe
        func response() throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile())
        }
    }
    @MainActor static func main() async {
        do {
            let helperPath = CommandLine.arguments[1]
            let root = URL(fileURLWithPath: "/private/tmp/lcd-codex-approval-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "local.lingchongdao.codex-approval." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
            model.startBridge(socketPath: root.appendingPathComponent("bridge.sock").path)
            defer { model.stopBridge() }
            try require(model.bridgeRunning, "bridge started")
            func spawn(_ session: String, socket: String? = nil, timeout: Int = 3, complex: Bool = false, reviewer: String? = "user") throws -> Helper {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: helperPath)
                process.arguments = ["--provider", "codex", "--socket", socket ?? root.appendingPathComponent("bridge.sock").path, "--timeout", String(timeout)]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                var raw: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session,
                    "cwd": root.path, "tool_name": complex ? "apply_patch" : "Bash", "tool_input": ["command": "printf lcd-approval-test", "description": "本机审批验收"], "agent_id": "child"]
                if let reviewer {
                    let transcript = root.appendingPathComponent(session + ".jsonl")
                    let records: [[String: Any]] = [
                        ["type": "session_meta", "payload": ["id": session]],
                        ["type": "turn_context", "payload": ["turn_id": "turn-" + session,
                            "approvals_reviewer": reviewer, "approval_policy": "on-request"]]
                    ]
                    var data = Data()
                    for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
                    try data.write(to: transcript)
                    raw["transcript_path"] = transcript.path
                    raw["turn_id"] = "turn-" + session
                }
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: raw))
                try input.fileHandleForWriting.close()
                return Helper(process: process, output: output)
            }
            func current(_ id: String) -> IslandSession? { model.sessions.first { $0.sessionID == id } }
            for (session, reviewer) in [("automatic", "auto_review" as String?), ("unknown", nil), ("future", "future_reviewer")] {
                _ = await model.handle(.init(provider: .codex, raw: .object(["hook_event_name": .string("UserPromptSubmit"), "session_id": .string(session)])))
                let passthrough = try spawn(session, reviewer: reviewer)
                try await until({ !passthrough.process.isRunning || current(session)?.hasPendingApproval == true }, message: "reviewer request observed")
                try require(current(session)?.hasPendingApproval != true, "Auto-review must not create a human approval card")
                try await until({ !passthrough.process.isRunning }, message: "review returns immediately to Codex")
                try require(try passthrough.response() == .object([:]), "Non-user review returns no allow or deny decision")
                try require(current(session)?.phase == .running && current(session)?.unread == false, "Review passthrough preserves running state without attention")
            }
            let contextPath = root.appendingPathComponent("context-check.jsonl")
            let contextInput: JSONValue = .object(["session_id": .string("context"), "turn_id": .string("current"), "transcript_path": .string(contextPath.path)])
            func checkContext(_ records: [JSONValue], expected: CodexApprovalContext.Reviewer, _ label: String, partial: Bool = false) throws {
                var data = Data()
                for record in records { data.append(try JSONEncoder().encode(record)); data.append(10) }
                if partial { data.append(Data("{\"type\":\"turn_context\"".utf8)) }
                try data.write(to: contextPath)
                try require(CodexApprovalContext.reviewer(for: contextInput) == expected, label)
            }
            let metadata: JSONValue = .object(["type": .string("session_meta"), "payload": .object(["id": .string("context")])])
            func context(_ turn: String, _ reviewer: String?, policy: String = "on-request") -> JSONValue {
                var payload: [String: JSONValue] = ["turn_id": .string(turn), "approval_policy": .string(policy)]
                if let reviewer { payload["approvals_reviewer"] = .string(reviewer) }
                return .object(["type": .string("turn_context"), "payload": .object(payload)])
            }
            try checkContext([metadata, context("current", "user")], expected: .user, "Exact session and turn prove user review")
            try checkContext([metadata, context("current", "auto_review")], expected: .automatic, "Automatic reviewer identified")
            try checkContext([metadata, context("older", "user")], expected: .unverified, "Old turn cannot prove user review")
            try checkContext([metadata, context("current", "user"), context("newer", "auto_review")], expected: .unverified, "Newer context invalidates an older matching turn")
            try checkContext([metadata, context("current", "user"), context("current", "auto_review")], expected: .automatic, "Latest same-turn reviewer wins")
            try checkContext([metadata, context("current", nil)], expected: .unverified, "Legacy context without reviewer stays with Codex")
            try checkContext([metadata, context("current", "user", policy: "never")], expected: .unverified, "Noninteractive policy cannot create user approval")
            try checkContext([metadata, context("current", "user")], expected: .unverified, "Incomplete transcript does not reuse stale reviewer", partial: true)
            try checkContext([.object(["type": .string("session_meta"), "payload": .object(["id": .string("other")])]), context("current", "user")], expected: .unverified, "Another session cannot prove user review")
            let a = try spawn("parallel"), b = try spawn("parallel")
            try await until({ current("parallel")?.hasPendingApproval == true }, message: "first request arrived")
            try await Task.sleep(for: .milliseconds(120))
            let first = current("parallel")!
            try require(first.phase == .waitingApproval && first.approval?.canApprove == true, "real helper creates actionable waiting state")
            model.respond(to: first, decision: .allow)
            try await until({ current("parallel")?.approval?.id != first.approval?.id }, message: "promote second request")
            let second = current("parallel")!
            try require(second.hasPendingApproval && second.approval?.canDeny == true, "second live helper survived first reply")
            model.respond(to: second, decision: .deny)
            try await until({ !a.process.isRunning && !b.process.isRunning }, message: "both helper processes returned")
            let outputs = try [a.response(), b.response()]
            let decisions = Set(outputs.compactMap { $0["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue })
            try require(decisions == ["allow", "deny"], "independent allow and deny JSON returned")
            try require(outputs.allSatisfy { $0["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == nil }, "no persistent permission changes")
            model.respond(to: first, decision: .allow)
            try require(model.actionError != nil, "old UI snapshot cannot approve again")

            let source = try spawn("source")
            try await until({ current("source")?.hasPendingApproval == true }, message: "handoff request")
            model.respond(to: current("source")!, decision: .fallback)
            try await until({ !source.process.isRunning }, message: "handoff helper completed")
            try require(try source.response() == .object([:]), "handoff returns normal source flow")
            try require(current("source")?.phase == .waitingApproval && current("source")?.approval?.canApprove == false, "handoff does not falsely show running")

            let complex = try spawn("complex", complex: true)
            try await until({ current("complex")?.hasPendingApproval == true }, message: "complex request arrived")
            try require(current("complex")?.approval?.canApprove == false && current("complex")?.approval?.canDeny == true, "Unpreviewed file changes remain deny-only")
            model.respond(to: current("complex")!, decision: .deny)
            try await until({ !complex.process.isRunning }, message: "complex denial returned")
            try require(try complex.response()["hookSpecificOutput"]?["decision"]?["behavior"] == .string("deny"), "Complex request denial uses native protocol")
            let mismatched = await model.handle(.init(provider: .codex, raw: .object(["hook_event_name": .string("PermissionRequest"), "session_id": .string("mismatch"), CodexPermissionBridge.identityKey: .string(UUID().uuidString)])))
            try require(mismatched.disposition == .fallback && current("mismatch") == nil, "Transport mismatch cannot create an actionable request")

            let timeout = try spawn("timeout", timeout: 1)
            try await until({ !timeout.process.isRunning }, message: "helper timeout")
            try require(try timeout.response() == .object([:]), "timeout never allows or denies")
            try await until({ current("timeout")?.hasPendingApproval != true }, message: "expired approval cleared")

            let canceled = try spawn("cancel")
            try await until({ current("cancel")?.hasPendingApproval == true }, message: "cancellation request")
            canceled.process.terminate()
            try await until({ current("cancel")?.hasPendingApproval != true }, message: "source cancellation removes live controls")
            try require(current("source")?.hasPendingApproval == true, "canceling another session leaves source notice intact")

            let missing = try spawn("missing", socket: root.appendingPathComponent("not-running.sock").path)
            try await until({ !missing.process.isRunning }, message: "missing bridge fallback")
            try require(try missing.response() == .object([:]), "absent bridge returns empty success")
            print("PASS \(checks) Codex approval checks: real helper sockets, parallel requests, allow, deny, fallback, timeout, source cancellation, stale UI")
        } catch {
            fputs("FAIL Codex approval verification: \(error)\n", stderr)
            exit(1)
        }
    }
}
