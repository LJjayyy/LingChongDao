import Darwin
import Foundation
import IslandCore
import IslandConnections

// Public-API verification that also runs with Command Line Tools, without XCTest.
// All installation fixtures use their own /private/tmp home. No live hooks are touched.
private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "Expectation failed", file: StaticString = #fileID, line: UInt = #line) throws {
    guard try condition() else { throw VerificationFailure(description: "\(file):\(line): \(message)") }
}

private func unwrap<T>(_ value: T?, _ message: String = "Expected a value") throws -> T {
    guard let value else { throw VerificationFailure(description: message) }
    return value
}

private func requireThrows(_ body: () throws -> Void, _ message: String = "Expected an error") throws {
    do { try body() } catch { return }
    throw VerificationFailure(description: message)
}

private func requireThrowsAsync(_ body: () async throws -> Void, _ message: String = "Expected an error") async throws {
    do { try await body() } catch { return }
    throw VerificationFailure(description: message)
}

private func raw(_ text: String) -> Data { Data(text.utf8) }
private func normalize(_ text: String, _ source: ProviderID = .qoder) throws -> NormalizedHookEvent {
    try HookNormalizer.normalize(rawJSON: raw(text), provider: source)
}

private final class ClosureSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reasons: [String] = []
    func record(_ reason: String) { lock.lock(); reasons.append(reason); lock.unlock(); semaphore.signal() }
    func wait(for reason: String, timeout: TimeInterval = 1) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while Date() < limit {
            lock.lock(); let found = reasons.contains(reason); lock.unlock()
            if found { return true }
            _ = semaphore.wait(timeout: .now() + max(0, limit.timeIntervalSinceNow))
        }
        lock.lock(); defer { lock.unlock() }; return reasons.contains(reason)
    }
}

private struct InstallFixture {
    let root: URL
    let helper: URL
    let environment: ConnectionEnvironment
    let service: HookConnectionService
    init() throws {
        let root = URL(fileURLWithPath: "/private/tmp/LingChongDaoVerify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let helper = root.appendingPathComponent("source-helper")
        try raw("#!/bin/sh\nexit 0\n").write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ConnectionEnvironment(homeDirectoryURL: root, helperSourceURL: helper, detectCLIVersions: false)
        self.root = root; self.helper = helper; self.environment = environment
        self.service = HookConnectionService(environment: environment)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func putConfiguration(_ data: Data, provider: ProviderID = .qoder, mode: Int = 0o600) throws {
        let url = environment.configurationURL(for: provider)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

private let existingConfiguration = raw(#"{"permissions":{"allow":["Read"]},"hooks":{"PreToolUse":[{"matcher":"Read","custom":"keep","hooks":[{"type":"command","command":"echo keep","timeout":9}]}]}}"#)
private func definitions(_ provider: ProviderID = .qoder) throws -> [ManagedHookDefinition] {
    try HookConfigurationEditor.definitions(provider: provider, helperURL: URL(fileURLWithPath: "/Users/Test User/AI's Tools/helper"), socketPath: "/Users/Test User/Library/Application Support/LingChongDao/run/bridge.sock")
}

@main
private enum Verification {
    static func main() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL \(name): \(error)") }
        }

        await check("Provider, host, session and fork identities remain isolated") {
            let first = try normalize(#"{"hook_event_name":"SessionStart","session_id":"same","thread_id":"fork-a"}"#, .codex)
            let second = try normalize(#"{"hook_event_name":"SessionStart","session_id":"same","thread_id":"fork-b"}"#, .codex)
            try require(first.sessionKey != second.sessionKey)
            let key = SessionIdentity.key(source: .codex, host: "a", sessionID: "b:c", threadID: "d")
            try require(key != SessionIdentity.key(source: .codex, host: "a:b", sessionID: "c", threadID: "d"))
            try require(key != SessionIdentity.key(source: .qoder, host: "a", sessionID: "b:c", threadID: "d"))
            try requireThrows { _ = try normalize(#"{"hook_event_name":"SessionStart","title":"not an identity"}"#) }
        }

        await check("Conversation content replaces source-name placeholders") {
            let question = try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"titles","title":"Qoder 会话","prompt":"  修复登录\n  刷新失败  ","cwd":"/Projects/account-service"}"#)
            var reducer = SessionReducer(); reducer.apply(question)
            try require(reducer.sessions.first?.displayTitle == "修复登录 刷新失败")
            let explicit = try normalize(#"{"hook_event_name":"SessionStart","session_id":"explicit","session_title":"登录页改版","title":"Codex 会话","prompt":"不会从SessionStart猜测提问"}"#, .codex)
            reducer.apply(explicit)
            try require(reducer.sessionsByID[explicit.sessionKey]?.displayTitle == "登录页改版")
            let marker = try normalize(##"{"hook_event_name":"UserPromptSubmit","session_id":"attachment","prompt":"# Files mentioned by the user:\nimage.png\n## My request:\n这里的标题改成用户提问"}"##, .codex)
            reducer.apply(marker)
            try require(reducer.sessionsByID[marker.sessionKey]?.displayTitle == "这里的标题改成用户提问")
            let attachedPrompt = "# Files mentioned by the user:\nimage.png\n## My request:\n这里不能点击吗\n<image name=[Image #1] path=/private/tmp/example.png>image</image>"
            try require(SessionTitle.promptText(attachedPrompt) == "这里不能点击吗")
            try require(SessionTitle.promptText("\n  " + attachedPrompt) == "这里不能点击吗")
            try require(SessionTitle.promptText("# Files mentioned by the user:\nimage.png\n## My request:\n<image name=[Image #1] path=/private/tmp/example.png>image</image>") == nil)
        }

        await check("Each source extracts prompt titles under its own rules") {
            let ambientPrompt = #"<in-app-browser-context source=\"ambient-ui-state\">\nThis block is automatically supplied ambient UI state, not part of the user's request.\n# In app browser:\n- The user has the in-app browser open with 2 tabs\n</in-app-browser-context>\n这个3个抢票终端有要求吗？是不是都是pc操作"#
            let zcode = try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-browser","cwd":"/Projects/grab-tickets","prompt":"\#(ambientPrompt)"}"#, .zcode)
            try require(zcode.title == "这个3个抢票终端有要求吗？是不是都是pc操作", "ZCode strips its ambient in-app browser block")
            var reducer = SessionReducer(); reducer.apply(zcode)
            try require(reducer.sessions.first?.displayTitle == "这个3个抢票终端有要求吗？是不是都是pc操作")
            let unterminated = try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-open","prompt":"<in-app-browser-context source=\"ambient-ui-state\">\n没有闭合标签也要保住提问"}"#, .zcode)
            try require(unterminated.title?.hasPrefix("<in-app-browser-context") == true, "An unterminated block is never stripped by eating the question")
            let plainZcode = try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-plain","prompt":"  修复登录\n  刷新失败  "}"#, .zcode)
            try require(plainZcode.title == "修复登录 刷新失败")
            let qoder = try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"qoder-ambient","prompt":"\#(ambientPrompt)"}"#, .qoder)
            try require(qoder.title?.hasPrefix("<in-app-browser-context") == true, "Other sources never apply ZCode's ambient rule")
            let codex = try normalize(##"{"hook_event_name":"UserPromptSubmit","session_id":"codex-ambient","prompt":"# Files mentioned by the user:\nimage.png\n## My request:\n这里的标题改成用户提问"}"##, .codex)
            try require(codex.title == "这里的标题改成用户提问", "Codex keeps its attachment wrapper rule")
        }

        await check("Project fallback survives partial hooks without promoting tool commands") {
            var reducer = SessionReducer()
            let first = try normalize(#"{"hook_event_name":"PreToolUse","session_id":"project","cwd":"/Projects/account-service","tool_name":"Bash","tool_input":{"command":"sleep 8","description":"Wait for video"}}"#)
            reducer.apply(first)
            try require(reducer.sessions.first?.displayTitle == "account-service")
            let next = try normalize(#"{"hook_event_name":"PostToolUse","session_id":"project","tool_use_id":"tool-a"}"#)
            try require(next.cwd == nil)
            reducer.apply(next)
            try require(reducer.sessions.first?.cwd == "/Projects/account-service" && reducer.sessions.first?.displayTitle == "account-service")
            try require(IslandSession(source: .codex, sessionID: "legacy", title: "Codex 会话", cwd: "/Projects/dia").displayTitle == "dia")
        }

        await check("Real titles survive placeholder, subagent and delayed events") {
            var reducer = SessionReducer(); let now = Date()
            let start = NormalizedHookEvent(source: .codex, sessionID: "main-title", timestamp: now, kind: .started, title: "排查登录失效", cwd: "/Projects/web")
            reducer.apply(start)
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(1), kind: .activity, title: "Codex会话", cwd: ""))
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(2), kind: .activity, title: "子任务跑测试", cwd: "/Projects/child", isSubagent: true))
            try require(reducer.sessions.first?.displayTitle == "排查登录失效" && reducer.sessions.first?.cwd == "/Projects/web")
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(3), kind: .started, title: "补齐错误提示"))
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(1), kind: .activity, title: "迟到标题"))
            try require(reducer.sessions.first?.displayTitle == "补齐错误提示")
            let resumed = try normalize(#"{"hook_event_name":"SessionStart","session_id":"main-title","cwd":"/Projects/web","timestamp":\#(now.addingTimeInterval(3.5).timeIntervalSince1970)}"#, .codex)
            reducer.apply(resumed)
            try require(reducer.sessions.first?.displayTitle == "补齐错误提示", "A title-free resume keeps the last user prompt")
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(4), kind: .turnStopped))
            try require(reducer.sessions.first?.displayTitle == "补齐错误提示")
            reducer.apply(.init(source: .codex, sessionID: "main-title", timestamp: now.addingTimeInterval(5), kind: .activity, title: "登录问题排查结果"))
            try require(reducer.sessions.first?.displayTitle == "登录问题排查结果", "Explicit source title updates are reflected")
            let childOnly = NormalizedHookEvent(source: .codex, sessionID: "child-only", timestamp: now, kind: .activity, title: "子任务不能命名主任务", cwd: "/Projects/api", isSubagent: true)
            reducer.apply(childOnly)
            try require(reducer.sessionsByID[childOnly.sessionKey]?.displayTitle == "api")
        }

        await check("Title presentation is bounded and never exposes anonymous session directories") {
            let long = String(repeating: "很长的标题", count: 100)
            let value = IslandSession(source: .codex, sessionID: "s", title: long).displayTitle
            try require(value.count <= 120)
            for path in ["/", "/Users/example", "/tmp/da2b4285", "/tmp/908d4f9b-b455-4010-a838-c13b80042f40"] {
                let session = IslandSession(source: .qoder, sessionID: "fallback", title: "Qoder 会话", cwd: path)
                try require(session.displayTitle == "未命名任务", path)
            }
            let legitimate = IslandSession(source: .codex, sessionID: "valid", title: "修复多会话切换")
            try require(legitimate.displayTitle == "修复多会话切换")
            try require(IslandSession(source: .generic, sessionID: "http", title: "HTTP 会话").displayTitle == "HTTP 会话")
        }

        await check("Question, approval, failure, completion and running priority") {
            var reducer = SessionReducer(); let now = Date()
            reducer.apply(.init(source: .qoder, sessionID: "running", timestamp: now, kind: .started))
            reducer.apply(.init(source: .qoder, sessionID: "done", timestamp: now, kind: .completed))
            reducer.apply(.init(source: .qoder, sessionID: "failed", timestamp: now, kind: .failed))
            reducer.apply(.init(source: .qoder, sessionID: "approval", timestamp: now, kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash")))
            reducer.apply(.init(source: .qoder, sessionID: "question", timestamp: now, kind: .questionRequested, question: .init(id: "q", prompt: "Which?")))
            try require(reducer.sessions.map(\.sessionID) == ["question", "approval", "failed", "done", "running"])
            reducer.apply(.init(source: .codex, sessionID: "newer-running", timestamp: now.addingTimeInterval(1), kind: .started))
            try require(reducer.sessions.filter { $0.phase == .running }.map(\.sessionID) == ["newer-running", "running"])
        }

        await check("Stop is neutral; subagent completion cannot finish the main task") {
            var reducer = SessionReducer(); let now = Date().addingTimeInterval(-2)
            reducer.apply(.init(source: .codex, sessionID: "main", timestamp: now, kind: .started))
            reducer.apply(.init(source: .codex, sessionID: "main", timestamp: now.addingTimeInterval(1), kind: .completed, isSubagent: true))
            try require(reducer.sessions.first?.phase == .running)
            reducer.apply(try normalize(#"{"hook_event_name":"Stop","session_id":"main"}"#, .codex))
            try require(reducer.sessions.first?.phase == .idle && reducer.sessions.first?.unread == true)
        }

        await check("A resumed session start browses history without resurrecting the task") {
            try require(try normalize(#"{"hook_event_name":"SessionStart","session_id":"fresh","source":"startup"}"#, .zcode).kind == .started)
            try require(try normalize(#"{"hook_event_name":"SessionStart","session_id":"legacy"}"#, .qoder).kind == .started, "Payloads without the resume field keep the old behavior")
            var reducer = SessionReducer(); let now = Date()
            let resumed = try normalize(#"{"hook_event_name":"SessionStart","session_id":"old","source":"resume","cwd":"/Projects/web"}"#, .zcode)
            try require(resumed.kind == .sessionResumed, "source=resume must not count as work starting")
            reducer.apply(.init(source: .zcode, sessionID: "old", timestamp: now, kind: .completed, detail: "报告已生成"))
            reducer.markRead(sessionKey: resumed.sessionKey)
            try require(reducer.sessions.isEmpty, "An ended and already-viewed task stays off the island")
            reducer.apply(resumed)
            try require(reducer.sessions.isEmpty, "Reopening the finished task in ZCode must not pop it back")
            try require(reducer.sessionsByID[resumed.sessionKey]?.phase == .completed)
            try require(reducer.sessionsByID[resumed.sessionKey]?.detail == "报告已生成", "A bare resume must not overwrite the last real detail")
            try require(reducer.sessionsByID[resumed.sessionKey]?.cwd == "/Projects/web", "Identity metadata still refreshes")
            reducer.apply(try normalize(#"{"hook_event_name":"UserPromptSubmit","session_id":"old","prompt":"继续修复剩余用例"}"#, .zcode))
            try require(reducer.sessions.first?.phase == .running, "Real work still surfaces the session")
        }

        await check("A failed tool call does not become whole-task failure") {
            let event = try normalize(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_use_id":"a","tool_name":"Bash"}"#)
            try require(event.kind == .activity)
        }

        await check("Duplicate and delayed requests cannot overwrite the current request") {
            var reducer = SessionReducer(); let now = Date()
            let event = NormalizedHookEvent(eventID: "same", source: .qoder, sessionID: "s", turnID: "t2", timestamp: now, kind: .approvalRequested, approval: .init(id: "new", toolName: "Bash", canApprove: true, canDeny: true))
            try require(reducer.apply(event)); try require(!reducer.apply(event))
            try require(!reducer.apply(.init(source: .qoder, sessionID: "s", turnID: "t1", timestamp: now.addingTimeInterval(-1), kind: .approvalRequested, approval: .init(id: "old", toolName: "Bash"))))
            try require(reducer.sessions.count == 1 && reducer.sessions.first?.approval?.id == "new")
            try require(!reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "old", decision: .allow))
            try require(!reducer.apply(.init(source: .qoder, sessionID: "s", turnID: "t1", interactionID: "new", timestamp: now.addingTimeInterval(1), kind: .approvalResolved)))
            try require(reducer.sessions.first?.approval?.id == "new", "Old turn must not resolve a newer request")
        }

        await check("PreToolUse preserves pending approval; matching PostToolUse resolves it") {
            let request = try normalize(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)
            var reducer = SessionReducer(); reducer.apply(request)
            let pre = try normalize(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_use_id":"a","tool_name":"Bash"}"#)
            try require(pre.interactionID == nil)
            reducer.apply(pre)
            try require(reducer.sessions.first?.approval?.id == "a")
            let post = try normalize(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_use_id":"a","tool_name":"Bash"}"#)
            reducer.apply(post)
            try require(reducer.sessions.first?.approval == nil && reducer.sessions.first?.phase == .running)
        }

        await check("Simple approvals require full preview; complex approvals remain deny-only") {
            let simple = try normalize(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git status","description":"Read status"}}"#, .codex)
            try require(simple.approval?.canApprove == true && simple.approval?.canDeny == true)
            let complex = try normalize(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","reason":"Review risk","tool_input":{"command":"git status"}}"#, .codex)
            try require(complex.approval?.canApprove == false && complex.approval?.canDeny == true && complex.approval?.command == nil)
            try require(!HookNormalizer.canPreviewApproval(toolName: "Bash", input: ["command": .string("echo $API_KEY")], cwd: "", summary: ""))
            try require(!HookNormalizer.canPreviewApproval(toolName: "Bash", input: ["command": .string("pwd\nls")], cwd: "", summary: ""))
        }

        await check("Unsupported providers and questions return to their original tool") {
            let generic = try normalize(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#, .generic)
            try require(generic.approval?.canApprove == false && generic.approval?.canDeny == false)
            try require(HookOutput.response(for: .init(disposition: .allow), event: generic) == .object([:]))
            let question = try normalize(#"{"hook_event_name":"Elicitation","session_id":"s","question":"Which?"}"#)
            try require(question.question?.canAnswer == false)
        }

        await check("Expiration disables actions and permits dismissing stale cards") {
            var reducer = SessionReducer(); let now = Date()
            let event = NormalizedHookEvent(source: .qoder, sessionID: "s", timestamp: now, kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: now.addingTimeInterval(-1)))
            reducer.apply(event); reducer.expireRequests(at: now)
            try require(!reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "a", decision: .allow))
            let expired = reducer.sessionsByID[event.sessionKey]
            try require(expired?.approval?.id == "a")
            try require(expired?.approval?.canApprove == false && expired?.approval?.canDeny == false)
            try require(reducer.sessions.isEmpty)
            reducer.dismissSession(sessionKey: event.sessionKey)
            try require(reducer.sessions.isEmpty)
        }

        await check("Live requests and running tasks cannot be dismissed") {
            var reducer = SessionReducer()
            let event = NormalizedHookEvent(source: .qoder, sessionID: "s", kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: Date().addingTimeInterval(30)))
            reducer.apply(event); reducer.dismissSession(sessionKey: event.sessionKey)
            try require(reducer.sessions.first?.approval?.id == "a")
            try require(reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "a", decision: .deny))
            try require(!reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "a", decision: .allow), "Only the first response may resolve a request")
            reducer.dismissSession(sessionKey: event.sessionKey)
            try require(reducer.sessions.first?.phase == .running)
        }

        await check("Swiping a row away force-dismisses stuck running work and resurfaces on activity") {
            var reducer = SessionReducer(); let now = Date()
            let started = NormalizedHookEvent(source: .codex, sessionID: "stuck", timestamp: now, kind: .started)
            reducer.apply(started)
            try require(reducer.sessions.first?.phase == .running)
            try require(!reducer.dismissSession(sessionKey: started.sessionKey), "Plain dismissal still refuses running work")
            try require(reducer.dismissSession(sessionKey: started.sessionKey, force: true), "A manual swipe must retire a stuck running row")
            try require(reducer.sessions.isEmpty)
            reducer.apply(.init(source: .codex, sessionID: "stuck", timestamp: now.addingTimeInterval(1), kind: .activity, detail: "继续工作"))
            try require(reducer.sessions.first?.phase == .running, "The same session resurfaces when real work arrives")
        }

        await check("Forced dismissal never swallows live approvals or questions") {
            var reducer = SessionReducer(); let now = Date()
            let approval = NormalizedHookEvent(source: .qoder, sessionID: "s", timestamp: now, kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: now.addingTimeInterval(30)))
            reducer.apply(approval)
            try require(!reducer.dismissSession(sessionKey: approval.sessionKey, force: true))
            try require(reducer.sessions.first?.approval?.id == "a")
            let question = NormalizedHookEvent(source: .qoder, sessionID: "q", timestamp: now, kind: .questionRequested, question: .init(id: "ask", prompt: "Which?"))
            reducer.apply(question)
            try require(!reducer.dismissSession(sessionKey: question.sessionKey, force: true))
            try require(reducer.sessions.first?.question?.id == "ask")
        }

        await check("Supported provider hook responses use allow/deny; fallback never allows") {
            for source in [ProviderID.codex, .zcode] {
                let event = try normalize(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#, source)
                let allow = HookOutput.response(for: .init(disposition: .allow), event: event)
                let deny = HookOutput.response(for: .init(disposition: .deny), event: event)
                try require(allow["hookSpecificOutput"]?["decision"]?["behavior"] == .string("allow"))
                try require(deny["hookSpecificOutput"]?["decision"]?["behavior"] == .string("deny"))
                try require(HookOutput.response(for: .fallback("Disconnected"), event: event) == .object([:]))
            }
        }

        await check("Split newline frames decode; oversized and empty frames are rejected") {
            var decoder = NewlineFrameDecoder()
            try require(try decoder.append(raw("{\"a\":" )).isEmpty)
            try require(try decoder.append(raw("1}\n{}\n")) == [raw("{\"a\":1}"), raw("{}")])
            var oversized = NewlineFrameDecoder()
            try requireThrows { _ = try oversized.append(Data(repeating: 65, count: BridgeLimits.maximumFrameBytes + 1)) }
            var empty = NewlineFrameDecoder()
            try requireThrows { _ = try empty.append(raw("\n")) }
        }

        await check("Socket permissions, ping correlation, single owner and cleanup") {
            let directory = URL(fileURLWithPath: "/private/tmp/ai-\(UUID().uuidString.prefix(8))")
            let path = directory.appendingPathComponent("b.sock").path
            let server = IslandSocketServer(socketPath: path)
            defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
            try server.start { _ in .acknowledged }
            var info = stat()
            try require(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
            try require(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
            let envelope = BridgeEnvelope(provider: .generic, operation: .ping)
            let reply = try IslandSocketClient(socketPath: path).send(envelope)
            try require(reply.disposition == .status && reply.requestID == envelope.requestID)
            let competitor = IslandSocketServer(socketPath: path)
            try requireThrows { try competitor.start { _ in .acknowledged } }
            server.stop()
            try require(!FileManager.default.fileExists(atPath: path))
        }

        await check("Socket timeout falls back and notifies the model before late allow") {
            let directory = URL(fileURLWithPath: "/private/tmp/ai-\(UUID().uuidString.prefix(8))")
            let path = directory.appendingPathComponent("b.sock").path
            let server = IslandSocketServer(socketPath: path); let signal = ClosureSignal()
            defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
            try server.start(handler: { _ in try? await Task.sleep(nanoseconds: 2_000_000_000); return .init(disposition: .allow) }, onConnectionClosed: { _, reason in signal.record(reason) })
            let reply = try IslandSocketClient(socketPath: path).send(.init(provider: .qoder, deadline: Date().addingTimeInterval(0.1)), timeout: 1)
            try require(reply.disposition == .fallback)
            try require(signal.wait(for: "timeout"))
        }

        await check("Socket disconnect notifies the model and cannot approve") {
            let directory = URL(fileURLWithPath: "/private/tmp/ai-\(UUID().uuidString.prefix(8))")
            let path = directory.appendingPathComponent("b.sock").path
            let server = IslandSocketServer(socketPath: path); let signal = ClosureSignal()
            defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
            try server.start(handler: { _ in try? await Task.sleep(nanoseconds: 2_000_000_000); return .init(disposition: .allow) }, onConnectionClosed: { _, reason in signal.record(reason) })
            try requireThrows { _ = try IslandSocketClient(socketPath: path).send(.init(provider: .qoder, deadline: Date().addingTimeInterval(3)), timeout: 0.1) }
            try require(signal.wait(for: "disconnected"))
        }

        await check("Qoder CN uses its own default configuration directory") {
            let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderHome", isDirectory: true)
            let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false)
            try require(environment.configurationURL(for: .qoder) == home.appendingPathComponent(".qoder-cn/settings.json"), "Qoder CN must not use the Qoder IDE .qoder directory")
        }

        await check("Qoder CN environment paths honor override precedence and relative paths") {
            let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderHome", isDirectory: true)
            let cwd = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderCwd", isDirectory: true)
            func resolve(_ values: [String: String]) throws -> URL {
                try ConnectionEnvironment.resolveQoderHomeURL(homeDirectoryURL: home, environment: values, currentDirectoryURL: cwd)
            }
            try require(try resolve([:]) == home.appendingPathComponent(".qoder-cn", isDirectory: true))
            try require(try resolve(["QODERCN_CLI_HOME": "/private/tmp/cli", "QODERCN_CONFIG_DIR_NAME": "custom-cn"]) == URL(fileURLWithPath: "/private/tmp/cli/custom-cn", isDirectory: true))
            try require(try resolve(["QODERCN_CONFIG_DIR": "/private/tmp/config", "QODERCN_CLI_HOME": "/private/tmp/ignored", "QODERCN_CONFIG_DIR_NAME": "../invalid"]) == URL(fileURLWithPath: "/private/tmp/config", isDirectory: true), "CONFIG_DIR wins before DIR_NAME validation")
            try require(try resolve(["QODERCN_CONFIG_DIR": "configs/../cn"]) == cwd.appendingPathComponent("cn", isDirectory: true))
            try require(try resolve(["QODERCN_CLI_HOME": "relative-home"]) == cwd.appendingPathComponent("relative-home/.qoder-cn", isDirectory: true))
            try require(try resolve(["QODERCN_CONFIG_DIR": "", "QODERCN_CLI_HOME": "", "QODERCN_CONFIG_DIR_NAME": ""]) == home.appendingPathComponent(".qoder-cn", isDirectory: true))
            let override = home.appendingPathComponent("specific-cn", isDirectory: true)
            let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false, qoderHomeURL: override)
            try require(environment.configurationURL(for: .qoder) == override.appendingPathComponent("settings.json"))
        }

        await check("Qoder CN rejects invalid directory names and normalizes Unicode") {
            let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderHome", isDirectory: true)
            for name in ["../other", "/absolute", ".", "..", "trailing.", " leading", "CON", "Lpt1.txt", ".GiT", "node_modules", String(repeating: "a", count: 65)] {
                try requireThrows {
                    _ = try ConnectionEnvironment.resolveQoderHomeURL(homeDirectoryURL: home, environment: ["QODERCN_CONFIG_DIR_NAME": name], currentDirectoryURL: home)
                }
            }
            let normalized = try ConnectionEnvironment.resolveQoderHomeURL(homeDirectoryURL: home, environment: ["QODERCN_CONFIG_DIR_NAME": "Cafe\u{301}"], currentDirectoryURL: home)
            // Foundation may expose a decomposed path component after URL standardization.
            // Compare canonical spelling rather than requiring a storage normalization form.
            try require(normalized.lastPathComponent.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value) == "Café".unicodeScalars.map(\.value))
        }

        await check("Legacy Qoder hooks migrate to CN while unrelated settings and backups survive") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let legacy = fixture.root.appendingPathComponent(".qoder/settings.json")
            let defs = try HookConfigurationEditor.definitions(provider: .qoder, helperURL: fixture.environment.installedHelperURL, socketPath: fixture.environment.socketPath)
            let old = try HookConfigurationEditor.install(provider: .qoder, existing: existingConfiguration, definitions: defs, recognizedCommands: [])
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try old.write(to: legacy)
            let before = await fixture.service.check(provider: .qoder)
            try require(before.status == .needsRepair)
            let plan = try await fixture.service.prepare(provider: .qoder)
            try require(plan.summary.contains(legacy.path))
            try await fixture.service.install(provider: .qoder)
            let installed = try Data(contentsOf: fixture.environment.configurationURL(for: .qoder))
            try require(try HookConfigurationEditor.inspect(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: []).isComplete)
            let cleaned = try Data(contentsOf: legacy)
            try require(try JSONSerialization.jsonObject(with: cleaned) as? NSDictionary == JSONSerialization.jsonObject(with: existingConfiguration) as? NSDictionary)
            let backups = try FileManager.default.contentsOfDirectory(at: legacy.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("settings.json.lingchongdao-backup-") }
            try require(backups.count == 1)
            try require(try Data(contentsOf: unwrap(backups.first)) == old)
        }

        await check("A changed legacy configuration cancels migration before creating CN hooks") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let legacy = fixture.root.appendingPathComponent(".qoder/settings.json")
            let defs = try HookConfigurationEditor.definitions(provider: .qoder, helperURL: fixture.environment.installedHelperURL, socketPath: fixture.environment.socketPath)
            let old = try HookConfigurationEditor.install(provider: .qoder, existing: existingConfiguration, definitions: defs, recognizedCommands: [])
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try old.write(to: legacy)
            _ = try await fixture.service.prepare(provider: .qoder)
            let edited = raw(#"{"external_edit":true}"#)
            try edited.write(to: legacy)
            try await requireThrowsAsync { try await fixture.service.install(provider: .qoder) }
            try require(try Data(contentsOf: legacy) == edited)
            try require(!FileManager.default.fileExists(atPath: fixture.environment.configurationURL(for: .qoder).path))
            try require(!FileManager.default.fileExists(atPath: fixture.environment.installedHelperURL.path))
        }

        await check("Interrupted legacy cleanup retains historical commands so migration can retry") {
            let fixture = try InstallFixture()
            let legacy = fixture.root.appendingPathComponent(".qoder/settings.json")
            let legacyDirectory = legacy.deletingLastPathComponent()
            defer {
                _ = chmod(legacyDirectory.path, 0o700)
                fixture.cleanup()
            }
            let defs = try HookConfigurationEditor.definitions(provider: .qoder, helperURL: fixture.environment.installedHelperURL, socketPath: fixture.environment.socketPath)
            let historical = defs.map {
                ManagedHookDefinition(event: $0.event, matcher: $0.matcher,
                    command: $0.command.replacingOccurrences(of: "--timeout 2 ", with: "--timeout 1 "), timeout: $0.timeout)
            }
            let old = try HookConfigurationEditor.install(provider: .qoder, existing: existingConfiguration, definitions: historical, recognizedCommands: [])
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            try old.write(to: legacy)
            let manifest = try JSONSerialization.data(withJSONObject: ["version": 1, "ownedCommands": ["qoder": historical.map(\.command)]])
            try FileManager.default.createDirectory(at: fixture.environment.applicationSupportURL, withIntermediateDirectories: true)
            try manifest.write(to: fixture.environment.manifestURL)
            _ = try await fixture.service.prepare(provider: .qoder)
            try require(chmod(legacyDirectory.path, 0o500) == 0)
            try await requireThrowsAsync { try await fixture.service.install(provider: .qoder) }
            try require(FileManager.default.fileExists(atPath: fixture.environment.configurationURL(for: .qoder).path), "Failure must occur after CN installation")
            try require(try Data(contentsOf: legacy) == old)
            let saved = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.environment.manifestURL)) as? [String: Any])
            let savedCommands = try unwrap((saved["ownedCommands"] as? [String: [String]])?["qoder"])
            try require(Set(historical.map(\.command)).isSubset(of: Set(savedCommands)), "Historical ownership must survive a partial migration")
            try require(chmod(legacyDirectory.path, 0o700) == 0)
            let retry = try await fixture.service.prepare(provider: .qoder)
            try require(retry.summary.contains(legacy.path), "Retry must still recognize the legacy hooks")
            try await fixture.service.install(provider: .qoder)
            let installed = try Data(contentsOf: fixture.environment.configurationURL(for: .qoder))
            try require(try HookConfigurationEditor.inspect(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: []).isComplete)
            try require(try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? NSDictionary == JSONSerialization.jsonObject(with: existingConfiguration) as? NSDictionary)
        }

        await check("Install/remove retain unrelated configuration and are idempotent") {
            let defs = try definitions()
            let installed = try HookConfigurationEditor.install(provider: .qoder, existing: existingConfiguration, definitions: defs, recognizedCommands: [])
            let commands = Set(defs.map(\.command))
            let again = try HookConfigurationEditor.install(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: commands)
            try require(installed == again)
            let root = try unwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
            try require((root["permissions"] as? [String: [String]])?["allow"] == ["Read"])
            let removed = try unwrap(HookConfigurationEditor.remove(provider: .qoder, existing: installed, recognizedCommands: commands))
            try require(try JSONSerialization.jsonObject(with: removed) as? NSDictionary == JSONSerialization.jsonObject(with: existingConfiguration) as? NSDictionary)
            try require(try HookConfigurationEditor.remove(provider: .qoder, existing: existingConfiguration, recognizedCommands: commands) == nil)
        }

        await check("Malformed configuration is rejected without silent replacement") {
            for text in ["broken", "[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":{"hooks":[]}}}"#] {
                try requireThrows { _ = try HookConfigurationEditor.install(provider: .qoder, existing: raw(text), definitions: definitions(), recognizedCommands: []) }
            }
        }

        await check("ZCode nests hooks under enabled events and never claims a session link") {
            let defs = try definitions(.zcode)
            try require(defs.map(\.event) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"])
            try require(HookConnectionService.capabilities(.zcode) == [.lifecycle, .activity, .limitedApproval])
            let user = raw(#"{"ui":{"locale":"zh-CN"},"hooks":{"enabled":false,"timeoutMs":5000}}"#)
            let enabledState = HookConfigurationEditor.hooksEnabledState(existing: user, provider: .zcode)
            try require(enabledState == .disabled)
            let installed = try HookConfigurationEditor.install(provider: .zcode, existing: user, definitions: defs, recognizedCommands: [])
            let root = try unwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
            try require((root["ui"] as? [String: String])?["locale"] == "zh-CN")
            let hooks = try unwrap(root["hooks"] as? [String: Any])
            try require(hooks["enabled"] as? Bool == true && hooks["timeoutMs"] as? Int == 5000)
            let events = try unwrap(hooks["events"] as? [String: Any])
            try require(Set(events.keys) == Set(defs.map(\.event)) && events["Stop"] != nil)
            try require(try HookConfigurationEditor.inspect(provider: .zcode, existing: installed, definitions: defs, recognizedCommands: []).isComplete)
            let disabled = try HookConfigurationEditor.remove(provider: .zcode, existing: installed, recognizedCommands: ["unrelated"])
            try require(disabled == nil, "Removal only targets exact owned commands")
            let removed = try unwrap(HookConfigurationEditor.remove(provider: .zcode, existing: installed, recognizedCommands: Set(defs.map(\.command)),
                                                                   restoreHooksEnabled: enabledState))
            try require(try JSONSerialization.jsonObject(with: removed) as? NSDictionary == JSONSerialization.jsonObject(with: user) as? NSDictionary)
        }

        await check("DeepSeek Harness ships its own dsh bundle and cleans legacy rows") {
            try require(HookConnectionService.capabilities(.dsh) == [.lifecycle, .activity])
            let legacy = DshBridge.beginMarker
                + "\n- insert:\n    - id: lingchongdao-hooks\n      name: 'lingchongdao-dsh-hooks'\n"
                + DshBridge.endMarker + "\n"
            let user = "# patch layer\n- id: agent-default-model\n  name: '@deepseek-ai/dsh-agent-default-model'\n"
            try require(DshBridge.hasManagedRow(legacy), "The 0.1.x loader row is recognisable")
            try require(DshBridge.removingManagedRow(existing: user + legacy) == user, "Legacy cleanup restores the user patch")
            try require(DshBridge.removingManagedRow(existing: user) == nil, "Foreign patches never match")
            try require(DshBridge.removingManagedRow(existing: nil) == nil, "A missing patch is not ownership")
        }

        await check("Hook paths are shell-escaped and permission waiting is bounded") {
            let defs = try definitions(.codex)
            let approval = try unwrap(defs.first { $0.event == "PermissionRequest" })
            try require(approval.command.contains("'\\''"))
            try require(approval.command.contains("--timeout 45") && approval.timeout == 60)
            try require(approval.statusMessage == "灵宠岛 · 处理权限请求")
            try require(defs.allSatisfy { $0.statusMessage?.hasPrefix("灵宠岛 · ") == true })
            try require(Set(defs.compactMap(\.statusMessage)).count == defs.count)
            try require(!defs.contains { $0.event == "Notification" || $0.event == "PostToolUseFailure" })
            try requireThrows { _ = try definitions(.generic) }
        }

        await check("Inspection does not mistake unrelated hooks for this installation") {
            let status = try HookConfigurationEditor.inspect(provider: .qoder, existing: existingConfiguration, definitions: definitions(), recognizedCommands: [])
            try require(!status.isComplete && status.ownedHookCount == 0)
        }

        await check("Inspection detects modified hook matcher, type or timeout") {
            let defs = try definitions()
            let installed = try HookConfigurationEditor.install(provider: .qoder, existing: nil, definitions: defs, recognizedCommands: [])
            let good = try HookConfigurationEditor.inspect(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: [])
            try require(good.isComplete)
            for field in ["matcher", "type", "timeout", "statusMessage"] {
                var root = try unwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
                var hooks = try unwrap(root["hooks"] as? [String: [[String: Any]]])
                var groups = try unwrap(hooks["PermissionRequest"])
                if field == "matcher" { groups[0]["matcher"] = "^NeverMatches$" }
                else {
                    var entries = try unwrap(groups[0]["hooks"] as? [[String: Any]])
                    if field == "type" { entries[0][field] = "prompt" }
                    else if field == "timeout" { entries[0][field] = 1 }
                    else { entries[0].removeValue(forKey: field) }
                    groups[0]["hooks"] = entries
                }
                hooks["PermissionRequest"] = groups; root["hooks"] = hooks
                let modified = try JSONSerialization.data(withJSONObject: root)
                let status = try HookConfigurationEditor.inspect(provider: .qoder, existing: modified, definitions: defs, recognizedCommands: [])
                try require(!status.isComplete, "Modified \(field) must require repair")
                try require(status.ownedHookCount == defs.count, "Ownership remains known when entry metadata changes")
            }
        }

        await check("Installation preserves a backup and original file mode") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            try fixture.putConfiguration(existingConfiguration, mode: 0o640)
            _ = try await fixture.service.prepare(provider: .qoder)
            try await fixture.service.install(provider: .qoder)
            let url = fixture.environment.configurationURL(for: .qoder)
            let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("settings.json.lingchongdao-backup-") }
            try require(backups.count == 1)
            try require(try Data(contentsOf: unwrap(backups.first)) == existingConfiguration)
            var info = stat(); try require(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o640)
            try await fixture.service.remove(provider: .qoder)
            try require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary == JSONSerialization.jsonObject(with: existingConfiguration) as? NSDictionary)
        }

        await check("A changed reviewed configuration is not overwritten") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            try fixture.putConfiguration(existingConfiguration)
            _ = try await fixture.service.prepare(provider: .qoder)
            let edited = raw(#"{"external_edit":true}"#)
            try fixture.putConfiguration(edited)
            try await requireThrowsAsync { try await fixture.service.install(provider: .qoder) }
            try require(try Data(contentsOf: fixture.environment.configurationURL(for: .qoder)) == edited)
            try require(!FileManager.default.fileExists(atPath: fixture.environment.installedHelperURL.path))
        }

        await check("Configuration symlinks are refused without touching their target") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let target = fixture.root.appendingPathComponent("target.json")
            try existingConfiguration.write(to: target)
            let config = fixture.environment.configurationURL(for: .qoder)
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
            try await requireThrowsAsync { _ = try await fixture.service.prepare(provider: .qoder) }
            try require(try Data(contentsOf: target) == existingConfiguration)
        }

        await check("Custom parent-directory symlinks remain refused") {
            for dangling in [false, true] {
                let fixture = try InstallFixture(); defer { fixture.cleanup() }
                let target = fixture.root.appendingPathComponent("actual-config")
                if !dangling {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    try existingConfiguration.write(to: target.appendingPathComponent("settings.json"))
                }
                let parent = fixture.environment.configurationURL(for: .qoder).deletingLastPathComponent()
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target)
                try await requireThrowsAsync { _ = try await fixture.service.prepare(provider: .qoder) }
                if !dangling { try require(try Data(contentsOf: target.appendingPathComponent("settings.json")) == existingConfiguration) }
                else { try require(!FileManager.default.fileExists(atPath: target.path)) }
            }
        }

        await check("A temporary-home Codex install never changes trust configuration") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let plan = try await fixture.service.prepare(provider: .codex)
            try require(plan.reviewInstructions.contains("不会自动信任"))
            try await fixture.service.install(provider: .codex)
            let connection = await fixture.service.check(provider: .codex)
            try require(connection.status == .needsReview && connection.hasInstalledHooks)
            try require(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".codex/config.toml").path))
            var info = stat(); try require(lstat(fixture.environment.installedHelperURL.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
            try await fixture.service.remove(provider: .codex)
            let removed = await fixture.service.check(provider: .codex)
            try require(!removed.hasInstalledHooks)
        }

        await check("Installation requires preparation and detects helper changes") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            try await requireThrowsAsync { try await fixture.service.install(provider: .codex) }
            _ = try await fixture.service.prepare(provider: .codex)
            try raw("#!/bin/sh\nexit 1\n").write(to: fixture.helper)
            try await requireThrowsAsync { try await fixture.service.install(provider: .codex) }
            try require(!FileManager.default.fileExists(atPath: fixture.environment.configurationURL(for: .codex).path))
        }

        await check("An unowned executable is not replaced") {
            let fixture = try InstallFixture(); defer { fixture.cleanup() }
            let installed = fixture.environment.installedHelperURL
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let unowned = raw("#!/bin/sh\nprintf existing\n")
            try unowned.write(to: installed)
            try await requireThrowsAsync { _ = try await fixture.service.prepare(provider: .qoder) }
            try require(try Data(contentsOf: installed) == unowned)
        }

        print("\n\(passed) passed; \(failures.count) failed. No live provider configuration was modified.")
        if !failures.isEmpty { exit(1) }
    }
}
