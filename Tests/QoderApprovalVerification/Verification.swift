import Foundation
import IslandCore

struct VerificationFailure: Error { let message: String }
@main struct QoderApprovalVerification {
    @MainActor static var checks = 0
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw VerificationFailure(message: message) }; checks += 1
    }
    @MainActor static func until(_ predicate: () -> Bool, message: String) async throws {
        for _ in 0..<400 {
            if predicate() { return }; try await Task.sleep(for: .milliseconds(10))
        }
        throw VerificationFailure(message: message)
    }
    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: "/private/tmp/lcd-qoder-state-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "local.lingchongdao.qoder-state." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
            let socket = root.appendingPathComponent("bridge.sock").path
            model.startBridge(socketPath: socket); defer { model.stopBridge() }
            try require(model.bridgeRunning, "bridge started")
            func raw(_ name: String, _ session: String, _ id: String? = nil) -> JSONValue {
                var object: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session),
                    "cwd": .string(root.path), "tool_name": .string("Bash"),
                    "tool_input": .object(["command": .string("printf lcd-state-test"), "description": .string("本机状态验收")])]
                if let id { object["tool_use_id"] = .string(id) }; return .object(object)
            }
            func send(_ name: String, _ session: String, _ id: String? = nil) async {
                _ = await model.handle(.init(provider: .qoder, raw: raw(name, session, id), sourceApplication: .qoderUnknown))
            }
            func current(_ id: String) -> IslandSession? { model.sessions.first { $0.sessionID == id } }
            func helper(_ session: String, path: String? = nil) throws -> (Process, Pipe) {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
                process.arguments = ["--provider", "qoder", "--socket", path ?? socket, "--timeout", "3"]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(raw("PermissionRequest", session)))
                try input.fileHandleForWriting.close(); return (process, output)
            }
            await send("PreToolUse", "native-first", "call-1")
            let (process, output) = try helper("native-first")
            try await until({ !process.isRunning }, message: "observation helper returns without user input")
            try require(try JSONDecoder().decode(JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile()) == .object([:]), "helper never returns a permission decision")
            let waiting = current("native-first")!
            try require(waiting.hasPendingApproval && waiting.phase == .waitingApproval, "native prompt displays waiting state")
            try require(waiting.approval?.canApprove == false && waiting.approval?.canDeny == false, "no island approval controls")
            model.respond(to: waiting, decision: .allow)
            try require(model.actionError != nil && current("native-first")?.hasPendingApproval == true, "old approval actions cannot decide observation")
            // A subagent result must not dismiss the main native prompt.
            var child = raw("PostToolUse", "native-first", "other").objectValue!; child["agent_id"] = .string("child")
            _ = await model.handle(.init(provider: .qoder, raw: .object(child), sourceApplication: .qoderUnknown))
            try require(current("native-first")?.hasPendingApproval == true, "unrelated subagent leaves native prompt intact")
            await send("PostToolUse", "native-first", "other-main")
            try require(current("native-first")?.hasPendingApproval == true, "unrelated main tool leaves native prompt intact")
            await send("PostToolUse", "native-first", "call-1")
            try require(current("native-first")?.hasPendingApproval != true && current("native-first")?.phase == .running, "source result resolves island waiting")

            for name in ["Stop", "StopFailure", "SessionEnd"] {
                let session = "terminal-" + name
                let (p, _) = try helper(session)
                try await until({ !p.isRunning }, message: "terminal observation arrived")
                try require(current(session)?.hasPendingApproval == true, "terminal test starts waiting")
                await send(name, session)
                try require(current(session)?.hasPendingApproval != true, "source terminal removes waiting: " + name)
            }
            let (missing, missingOutput) = try helper("missing", path: root.appendingPathComponent("absent.sock").path)
            try await until({ !missing.isRunning }, message: "no island returns native handling")
            try require(try JSONDecoder().decode(JSONValue.self, from: missingOutput.fileHandleForReading.readDataToEndOfFile()) == .object([:]), "absent island leaves source permissions unchanged")
            for origin in [SourceApplicationID.qoderDesktop, .qoderIDE, .qoderUnknown] {
                let event = try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(raw("PermissionRequest", "origin", "tool")), provider: .qoder, sourceApplication: origin)
                try require(event.approval?.canApprove == false && event.approval?.canDeny == false, "all Qoder hosts observation-only")
                var forged = event; forged.approval?.canApprove = true; forged.approval?.canDeny = true
                try require(HookOutput.response(for: .init(disposition: .allow), event: forged) == .object([:]) && HookOutput.response(for: .init(disposition: .deny), event: forged) == .object([:]), "Qoder output cannot synthesize decisions")
            }
            var correlator = QoderPermissionCorrelator()
            _ = correlator.observe(raw("PreToolUse", "ambiguous", "a"), sessionKey: "ambiguous")
            _ = correlator.observe(raw("PreToolUse", "ambiguous", "b"), sessionKey: "ambiguous")
            _ = correlator.observe(QoderPermissionBridge.correlatedInput(raw("PermissionRequest", "ambiguous"), transportID: UUID().uuidString), sessionKey: "ambiguous")
            try require(correlator.observe(raw("PostToolUse", "ambiguous", "a"), sessionKey: "ambiguous") == nil, "identical parallel commands are not guessed")
            print("PASS \(checks) Qoder status checks: observation-only, native lifecycle, stale controls, host coverage, safe output")
        } catch { fputs("FAIL Qoder status verification: \(error)\n", stderr); exit(1) }
    }
}
