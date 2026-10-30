import Foundation
import IslandCore

struct VerificationFailure: Error { let message: String }
@main struct ClaudeApprovalVerification {
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
            let root = URL(fileURLWithPath: "/private/tmp/lcd-claude-approval-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "local.lingchongdao.claude-approval." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
            model.startBridge(socketPath: root.appendingPathComponent("bridge.sock").path)
            defer { model.stopBridge() }
            try require(model.bridgeRunning, "bridge started")
            func spawn(_ session: String, socket: String? = nil, timeout: Int = 3) throws -> Helper {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: helperPath)
                process.arguments = ["--provider", "claude", "--socket", socket ?? root.appendingPathComponent("bridge.sock").path, "--timeout", String(timeout)]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                let raw: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session,
                    "cwd": root.path, "tool_name": "WebSearch", "tool_input": ["query": "Claude Code documentation"], "agent_id": "child"]
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: raw))
                try input.fileHandleForWriting.close()
                return Helper(process: process, output: output)
            }
            func current(_ id: String) -> IslandSession? { model.sessions.first { $0.sessionID == id } }
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

            let noticeStart = BridgeEnvelope(provider: .claude, raw: .object(["hook_event_name": .string("UserPromptSubmit"), "session_id": .string("notice")]), sourceApplication: .claudeUnknown)
            _ = await model.handle(noticeStart)
            _ = await model.handle(BridgeEnvelope(provider: .claude, raw: .object(["hook_event_name": .string("Notification"), "notification_type": .string("permission_prompt"), "session_id": .string("notice")]), deadline: Date().addingTimeInterval(1), sourceApplication: .claudeUnknown))
            try require(current("notice")?.hasPendingApproval == true && current("notice")?.approval?.expiresAt?.timeIntervalSinceNow ?? 0 > 90, "source notice survives short observation transport")
            try require(model.dismiss(current("notice")!), "read-only notices can be closed without permission decisions")
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
            print("PASS \(checks) Claude approval checks: real helper sockets, parallel requests, allow, deny, fallback, timeout, source cancellation, stale UI")
        } catch {
            fputs("FAIL Claude approval verification: \(error)\n", stderr)
            exit(1)
        }
    }
}
