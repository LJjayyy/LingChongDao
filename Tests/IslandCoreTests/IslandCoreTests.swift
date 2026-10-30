import XCTest
import Foundation
import Darwin
@testable import IslandCore

final class IslandCoreTests: XCTestCase {
    func raw(_ text: String) -> Data { Data(text.utf8) }
    func testIdentityPreservesProviderHostSessionAndForkThread() throws {
        let first = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"same","thread_id":"fork-a"}"#), provider: .codex)
        let second = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"same","thread_id":"fork-b"}"#), provider: .codex)
        XCTAssertNotEqual(first.sessionKey, second.sessionKey)
        XCTAssertNotEqual(SessionIdentity.key(source: .codex, host: "a", sessionID: "b:c", threadID: "d"), SessionIdentity.key(source: .codex, host: "a:b", sessionID: "c", threadID: "d"))
        XCTAssertThrowsError(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","title":"not an identity"}"#), provider: .qoder))
    }
    func testPriorityAndTimestampSort() {
        var reducer = SessionReducer(); let now = Date()
        reducer.apply(.init(source: .qoder, sessionID: "running", timestamp: now, kind: .started))
        reducer.apply(.init(source: .qoder, sessionID: "done", timestamp: now, kind: .completed))
        reducer.apply(.init(source: .qoder, sessionID: "failed", timestamp: now, kind: .failed))
        reducer.apply(.init(source: .qoder, sessionID: "approval", timestamp: now, kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash")))
        reducer.apply(.init(source: .qoder, sessionID: "question", timestamp: now, kind: .questionRequested, question: .init(id: "q", prompt: "Which?")))
        XCTAssertEqual(reducer.sessions.map(\.sessionID), ["question", "approval", "failed", "done", "running"])
    }
    func testStopIsNeutralAndSubagentDoesNotFinishMain() throws {
        var reducer = SessionReducer(); let now = Date().addingTimeInterval(-2)
        reducer.apply(.init(source: .codex, sessionID: "main", timestamp: now, kind: .started))
        reducer.apply(.init(source: .codex, sessionID: "main", timestamp: now.addingTimeInterval(1), kind: .completed, isSubagent: true))
        XCTAssertEqual(reducer.sessions.first?.phase, .running)
        let stop = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"Stop","session_id":"main"}"#), provider: .codex)
        reducer.apply(stop)
        XCTAssertEqual(reducer.sessions.first?.phase, .idle); XCTAssertEqual(reducer.sessions.first?.unread, true)
    }
    func testResumedSessionStartDoesNotResurrectEndedTask() throws {
        XCTAssertEqual(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"old","source":"resume","cwd":"/Projects/web"}"#), provider: .zcode).kind, .sessionResumed)
        XCTAssertEqual(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"fresh","source":"startup"}"#), provider: .zcode).kind, .started)
        XCTAssertEqual(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"legacy"}"#), provider: .qoder).kind, .started)
        var reducer = SessionReducer(); let now = Date()
        let resume = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"SessionStart","session_id":"old","source":"resume","cwd":"/Projects/web"}"#), provider: .zcode)
        reducer.apply(.init(source: .zcode, sessionID: "old", timestamp: now, kind: .completed, detail: "报告已生成"))
        reducer.markRead(sessionKey: resume.sessionKey)
        XCTAssertTrue(reducer.sessions.isEmpty)
        reducer.apply(resume)
        XCTAssertTrue(reducer.sessions.isEmpty, "Reopening a finished task must not pop it back onto the island")
        XCTAssertEqual(reducer.sessionsByID[resume.sessionKey]?.phase, .completed)
        XCTAssertEqual(reducer.sessionsByID[resume.sessionKey]?.detail, "报告已生成", "A bare resume must not overwrite the last real detail")
        XCTAssertEqual(reducer.sessionsByID[resume.sessionKey]?.cwd, "/Projects/web")
        reducer.apply(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"UserPromptSubmit","session_id":"old","prompt":"继续修复剩余用例"}"#), provider: .zcode))
        XCTAssertEqual(reducer.sessions.first?.phase, .running, "Real work still surfaces the session")
    }
    func testPerSourcePromptTitlePoliciesStayIsolated() throws {
        let ambientPrompt = #"<in-app-browser-context source=\"ambient-ui-state\">\nThis block is automatically supplied ambient UI state, not part of the user's request.\n# In app browser:\n- The user has the in-app browser open with 2 tabs\n</in-app-browser-context>\n这个3个抢票终端有要求吗？是不是都是pc操作"#
        let zcode = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-browser","prompt":"\#(ambientPrompt)"}"#), provider: .zcode)
        XCTAssertEqual(zcode.title, "这个3个抢票终端有要求吗？是不是都是pc操作")
        XCTAssertEqual(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-open","prompt":"<in-app-browser-context source=\"x\">\n没有闭合标签也要保住提问"}"#), provider: .zcode).title?.hasPrefix("<in-app-browser-context"), true)
        XCTAssertEqual(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"UserPromptSubmit","session_id":"zcode-plain","prompt":"  修复登录\n  刷新失败  "}"#), provider: .zcode).title, "修复登录 刷新失败")
        let qoder = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"UserPromptSubmit","session_id":"qoder-ambient","prompt":"\#(ambientPrompt)"}"#), provider: .qoder)
        XCTAssertEqual(qoder.title?.hasPrefix("<in-app-browser-context"), true, "Other sources never apply ZCode's ambient rule")
        let codex = try HookNormalizer.normalize(rawJSON: raw(##"{"hook_event_name":"UserPromptSubmit","session_id":"codex-wrap","prompt":"# Files mentioned by the user:\nimage.png\n## My request:\n这里的标题改成用户提问"}"##), provider: .codex)
        XCTAssertEqual(codex.title, "这里的标题改成用户提问")
        XCTAssertEqual(PromptTitlePolicy.policy(for: .dsh), .plain)
        XCTAssertEqual(PromptTitlePolicy.policy(for: .workbuddy), .plain)
    }
    func testToolFailureDoesNotBecomeWholeTaskFailure() throws {
        let event = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_use_id":"request-a","tool_name":"Bash"}"#), provider: .qoder)
        XCTAssertEqual(event.kind, .activity)
    }
    func testPreToolUseCannotClearPendingApprovalButMatchingPostToolUseCan() throws {
        var reducer = SessionReducer()
        let request = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#), provider: .qoder)
        XCTAssertTrue(reducer.apply(request))
        let pre = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_use_id":"a","tool_name":"Bash"}"#), provider: .qoder)
        XCTAssertNil(pre.interactionID)
        reducer.apply(pre)
        XCTAssertEqual(reducer.sessions.first?.approval?.id, "a")
        reducer.apply(try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_use_id":"a","tool_name":"Bash"}"#), provider: .qoder))
        XCTAssertNil(reducer.sessions.first?.approval)
        XCTAssertEqual(reducer.sessions.first?.phase, .running)
    }
    func testOldAndDuplicateRequestsCannotOverwriteCurrent() {
        var reducer = SessionReducer(); let now = Date()
        let newer = NormalizedHookEvent(eventID: "same", source: .qoder, sessionID: "s", turnID: "t2", timestamp: now, kind: .approvalRequested, approval: .init(id: "new", toolName: "Bash"))
        XCTAssertTrue(reducer.apply(newer)); XCTAssertFalse(reducer.apply(newer))
        XCTAssertFalse(reducer.apply(.init(source: .qoder, sessionID: "s", turnID: "t1", timestamp: now.addingTimeInterval(-1), kind: .approvalRequested, approval: .init(id: "old", toolName: "Bash"))))
        XCTAssertFalse(reducer.apply(.init(source: .qoder, sessionID: "s", turnID: "t1", interactionID: "new", timestamp: now.addingTimeInterval(1), kind: .approvalResolved)))
        XCTAssertEqual(reducer.sessions.count, 1); XCTAssertEqual(reducer.sessions.first?.approval?.id, "new")
    }
    func testApprovalFullPreviewBoundaryAndComplexDeny() throws {
        let simple = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"a","tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git status","description":"Read status"}}"#), provider: .codex)
        XCTAssertTrue(simple.approval?.canApprove == true); XCTAssertTrue(simple.approval?.canDeny == true)
        let complex = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"request-a","tool_name":"Bash","reason":"Review risk","tool_input":{"command":"git status"}}"#), provider: .codex)
        XCTAssertFalse(complex.approval?.canApprove == true); XCTAssertTrue(complex.approval?.canDeny == true); XCTAssertNil(complex.approval?.command)
        XCTAssertFalse(HookNormalizer.canPreviewApproval(toolName: "Bash", input: ["command": .string("echo $API_KEY")], cwd: "", summary: ""))
        XCTAssertFalse(HookNormalizer.canPreviewApproval(toolName: "Bash", input: ["command": .string("pwd\nls")], cwd: "", summary: ""))
    }
    func testUnknownProviderAndQuestionsReturnToOriginalTool() throws {
        let generic = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"request-a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#), provider: .generic)
        XCTAssertFalse(generic.approval?.canApprove == true); XCTAssertFalse(generic.approval?.canDeny == true)
        XCTAssertEqual(HookOutput.response(for: .init(disposition: .allow), event: generic), .object([:]))
        let question = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"Elicitation","session_id":"s","question":"Which?"}"#), provider: .qoder)
        XCTAssertFalse(question.question?.canAnswer == true)
    }
    func testExpiryDisablesBothActionsAndCanDismiss() {
        var reducer = SessionReducer(); let now = Date()
        let event = NormalizedHookEvent(source: .qoder, sessionID: "s", timestamp: now, kind: .approvalRequested, approval: .init(id: "a", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: now.addingTimeInterval(-1)))
        reducer.apply(event); reducer.expireRequests(at: now)
        XCTAssertFalse(reducer.resolveApproval(sessionKey: event.sessionKey, requestID: "a", decision: .allow))
        let expired = reducer.sessionsByID[event.sessionKey]
        XCTAssertEqual(expired?.approval?.id, "a")
        XCTAssertEqual(expired?.approval?.canApprove, false)
        XCTAssertEqual(expired?.approval?.canDeny, false)
        XCTAssertTrue(reducer.sessions.isEmpty)
        reducer.dismissSession(sessionKey: event.sessionKey); XCTAssertTrue(reducer.sessions.isEmpty)
    }
    func testSwipeForceDismissClearsStuckRunningSessionAndResurfacesOnActivity() {
        var reducer = SessionReducer(); let now = Date()
        let started = NormalizedHookEvent(source: .codex, sessionID: "stuck", timestamp: now, kind: .started)
        reducer.apply(started)
        XCTAssertEqual(reducer.sessions.first?.phase, .running)
        XCTAssertFalse(reducer.dismissSession(sessionKey: started.sessionKey), "Plain dismissal still refuses running work")
        XCTAssertEqual(reducer.sessions.count, 1)
        XCTAssertTrue(reducer.dismissSession(sessionKey: started.sessionKey, force: true), "A manual swipe must retire a stuck running row")
        XCTAssertTrue(reducer.sessions.isEmpty)
        reducer.apply(.init(source: .codex, sessionID: "stuck", timestamp: now.addingTimeInterval(1), kind: .activity, detail: "继续工作"))
        XCTAssertEqual(reducer.sessions.first?.phase, .running, "The same session resurfaces when real work arrives")
    }
    func testForceDismissNeverSwallowsLiveApprovalOrQuestion() {
        var reducer = SessionReducer(); let now = Date()
        let approval = NormalizedHookEvent(source: .qoder, sessionID: "s", timestamp: now, kind: .approvalRequested,
                                           approval: .init(id: "a", toolName: "Bash", canApprove: true, canDeny: true, expiresAt: now.addingTimeInterval(30)))
        reducer.apply(approval)
        XCTAssertFalse(reducer.dismissSession(sessionKey: approval.sessionKey, force: true))
        XCTAssertEqual(reducer.sessions.first?.approval?.id, "a")
        let question = NormalizedHookEvent(source: .qoder, sessionID: "q", timestamp: now, kind: .questionRequested,
                                           question: .init(id: "ask", prompt: "Which?"))
        reducer.apply(question)
        XCTAssertFalse(reducer.dismissSession(sessionKey: question.sessionKey, force: true))
        XCTAssertEqual(reducer.sessions.first?.question?.id, "ask")
    }
    func testHookOutputMatchesEveryApprovalProviderAndNoFailureAllow() throws {
        for source in [ProviderID.codex, .zcode] {
            let event = try HookNormalizer.normalize(rawJSON: raw(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"request-a","tool_name":"Bash","tool_input":{"command":"pwd"}}"#), provider: source)
            XCTAssertTrue(event.approval?.canApprove == true, "\(source.rawValue) must allow a visible Bash request")
            let output = HookOutput.response(for: .init(disposition: .allow), event: event)
            XCTAssertEqual(output["hookSpecificOutput"]?["decision"]?["behavior"], .string("allow"))
            XCTAssertEqual(HookOutput.response(for: .fallback("Disconnected"), event: event), .object([:]))
        }
    }
    func testPartialAndOversizeFrameHandling() throws {
        var decoder = NewlineFrameDecoder()
        XCTAssertTrue(try decoder.append(raw("{\"a\":" )).isEmpty)
        XCTAssertEqual(try decoder.append(raw("1}\n{}\n")), [raw("{\"a\":1}"), raw("{}")])
        var oversized = NewlineFrameDecoder()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: BridgeLimits.maximumFrameBytes + 1)))
    }
    func socketPath() -> String { "/private/tmp/ai-\(UUID().uuidString.prefix(8))/b.sock" }
    func testSocketPingPermissionsSingleInstanceAndCleanup() throws {
        let path = socketPath(); let server = IslandSocketServer(socketPath: path)
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        try server.start { _ in .acknowledged }
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertEqual(lstat(directory, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let reply = try IslandSocketClient(socketPath: path).send(.init(provider: .generic, operation: .ping))
        XCTAssertEqual(reply.disposition, .status)
        let competitor = IslandSocketServer(socketPath: path); XCTAssertThrowsError(try competitor.start { _ in .acknowledged })
        server.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testSocketTimeoutNotifiesAndNeverAllowsLateReply() throws {
        let path = socketPath(); let server = IslandSocketServer(socketPath: path); let closed = expectation(description: "request expired")
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        try server.start(handler: { _ in try? await Task.sleep(nanoseconds: 2_000_000_000); return .init(disposition: .allow) }, onConnectionClosed: { _, reason in if reason == "timeout" { closed.fulfill() } })
        let reply = try IslandSocketClient(socketPath: path).send(.init(provider: .qoder, deadline: Date().addingTimeInterval(0.1)), timeout: 1)
        XCTAssertEqual(reply.disposition, .fallback); wait(for: [closed], timeout: 1)
    }
    func testDisconnectNotifiesModel() throws {
        let path = socketPath(); let server = IslandSocketServer(socketPath: path); let closed = expectation(description: "client disconnected")
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        try server.start(handler: { _ in try? await Task.sleep(nanoseconds: 2_000_000_000); return .init(disposition: .allow) }, onConnectionClosed: { _, reason in if reason == "disconnected" { closed.fulfill() } })
        XCTAssertThrowsError(try IslandSocketClient(socketPath: path).send(.init(provider: .qoder, deadline: Date().addingTimeInterval(3)), timeout: 0.1))
        wait(for: [closed], timeout: 1)
    }
}
