import XCTest
import Foundation
@testable import IslandCore

final class BuddyCoreTests: XCTestCase {
    func event(_ name: String, provider: ProviderID, extra: [String: JSONValue] = [:]) throws -> NormalizedHookEvent {
        let raw = JSONValue.object(["session_id": .string("shared"), "hook_event_name": .string(name)].merging(extra) { _, value in value })
        return try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(raw), provider: provider)
    }
    func testBuddyLifecycleAndTitle() throws {
        for provider in [ProviderID.codebuddy, .workbuddy] {
            for (name, kind) in [("SessionStart", HookEventKind.started), ("UserPromptSubmit", .started), ("PreToolUse", .activity), ("PostToolUse", .activity), ("PreCompact", .activity), ("Stop", .turnStopped), ("SessionEnd", .sessionEnded)] {
                XCTAssertEqual(try event(name, provider: provider).kind, kind)
            }
            let prompt = try event("UserPromptSubmit", provider: provider, extra: ["prompt": .string("修复登录问题")])
            XCTAssertEqual(prompt.title, "修复登录问题")
            let command = try event("PreToolUse", provider: provider, extra: ["tool_name": .string("execute_command"), "tool_input": .object(["command": .string("pwd")])])
            XCTAssertEqual(command.detail, "pwd")
            let response = try event("PostToolUse", provider: provider, extra: ["tool_response": .object(["output": .string("tool done")])])
            XCTAssertEqual(response.kind, .activity)
            XCTAssertEqual(response.detail, "tool done")
        }
    }
    func testBuddyRequestsNeverEmitPermissionDecisions() throws {
        for provider in [ProviderID.codebuddy, .workbuddy] {
            var request = try event("PermissionRequest", provider: provider, extra: ["tool_use_id": .string("call"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("pwd")])])
            XCTAssertEqual(request.approval?.canApprove, false)
            XCTAssertEqual(request.approval?.canDeny, false)
            // Even a forged local capability must not produce source permission output.
            request.approval?.canApprove = true; request.approval?.canDeny = true
            for disposition in [BridgeDisposition.allow, .deny, .acknowledged, .fallback] {
                XCTAssertEqual(HookOutput.response(for: .init(disposition: disposition), event: request), .object([:]))
            }
            XCTAssertEqual(try event("AskQuestion", provider: provider).kind, .activity)
            let question = try event("PreToolUse", provider: provider, extra: ["tool_use_id": .string("question-call"), "tool_name": .string("AskQuestion"), "tool_input": .object(["question": .string("选择哪个？")])])
            XCTAssertEqual(question.kind, .questionRequested)
            XCTAssertEqual(question.question?.prompt, "选择哪个？")
            XCTAssertEqual(question.question?.canAnswer, false)
        }
    }
    func testBuddySessionIsolationAndNoUnprovenDeepLink() {
        let origins: [SourceApplicationID] = [.codebuddyCNIDE, .codebuddyUnknown, .workbuddyDesktop, .workbuddyAI, .workbuddyUnknown]
        let keys = origins.map { SessionIdentity.key(source: $0.provider, sessionID: "same", threadID: nil, sourceApplication: $0) }
        XCTAssertEqual(Set(keys).count, origins.count)
        for origin in origins {
            let provider = origin.provider
            let unknown: SourceApplicationID = provider == .codebuddy ? .codebuddyUnknown : .workbuddyUnknown
            XCTAssertEqual(SessionIdentity.key(source: provider, sessionID: "same", threadID: nil), SessionIdentity.key(source: provider, sessionID: "same", threadID: nil, sourceApplication: unknown))
            let session = IslandSession(source: provider, sessionID: "same", title: "任务", sourceApplication: origin)
            XCTAssertNil(SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: origin.bundleIdentifier ?? ""))
            XCTAssertNil(IslandSession(source: .codex, sessionID: "same", title: "", sourceApplication: origin).sourceApplication)
        }
    }
    func testVerifiedWorkBuddyDesktopConversationUsesSessionIDOnly() {
        let id = "12345678-1234-4abc-9876-1234567890ab"
        let desktop = IslandSession(source: .workbuddy, sessionID: id, threadID: "different", turnID: "turn", title: "task", sourceApplication: .workbuddyDesktop)
        XCTAssertEqual(SessionNavigation.conversationURL(for: desktop, applicationBundleIdentifier: "com.tencent.workbuddy.mac")?.absoluteString, "workbuddy://chat/" + id)
        let ai = IslandSession(source: .workbuddy, sessionID: id, title: "task", sourceApplication: .workbuddyAI)
        XCTAssertNil(SessionNavigation.conversationURL(for: ai, applicationBundleIdentifier: "com.workbuddy.workbuddy-ai"))
        let wrongSession = IslandSession(source: .workbuddy, sessionID: "invalid", threadID: id, title: "task", sourceApplication: .workbuddyDesktop)
        XCTAssertNil(SessionNavigation.conversationURL(for: wrongSession, applicationBundleIdentifier: "com.tencent.workbuddy.mac"))
    }

    func testBuddyQuestionLifecycleRequiresMatchingStableQuestionTool() throws {
        for provider in [ProviderID.codebuddy, .workbuddy] {
            var reducer = SessionReducer()
            let pre = try event("PreToolUse", provider: provider, extra: ["tool_use_id": .string("question-1"), "tool_name": .string("AskQuestion"), "tool_input": .object(["question": .string("哪个？")])])
            XCTAssertEqual(pre.kind, .questionRequested)
            XCTAssertNotNil(pre.question?.expiresAt)
            XCTAssertLessThanOrEqual(pre.question!.expiresAt!.timeIntervalSince(pre.timestamp), 110)
            reducer.apply(pre)
            XCTAssertEqual(reducer.sessions.first?.phase, .waitingQuestion)
            let unrelated = try event("PostToolUse", provider: provider, extra: ["tool_use_id": .string("question-1"), "tool_name": .string("execute_command")])
            reducer.apply(unrelated)
            XCTAssertEqual(reducer.sessions.first?.phase, .waitingQuestion)
            let wrongID = try event("PostToolUse", provider: provider, extra: ["tool_use_id": .string("other"), "tool_name": .string("AskQuestion")])
            reducer.apply(wrongID)
            XCTAssertEqual(reducer.sessions.first?.phase, .waitingQuestion)
            let post = try event("PostToolUse", provider: provider, extra: ["tool_use_id": .string("question-1"), "tool_name": .string("AskQuestion")])
            XCTAssertEqual(post.kind, .questionResolved)
            reducer.apply(post)
            XCTAssertEqual(reducer.sessions.first?.phase, .running)
            XCTAssertNil(reducer.sessions.first?.question)
            let uncorrelated = try event("PreToolUse", provider: provider, extra: ["tool_name": .string("AskQuestion")])
            XCTAssertEqual(uncorrelated.kind, .activity)
            XCTAssertNil(uncorrelated.question)
            let retryQuestion = try event("PreToolUse", provider: provider, extra: ["tool_use_id": .string("question-2"), "tool_name": .string("AskQuestion")])
            reducer.apply(retryQuestion)
            XCTAssertEqual(reducer.sessions.first?.phase, .waitingQuestion)
            let failedQuestion = try event("PostToolUseFailure", provider: provider, extra: ["tool_name": .string("AskQuestion"), "tool_use_id": .string("question-2")])
            XCTAssertEqual(failedQuestion.kind, .questionResolved)
            reducer.apply(failedQuestion)
            XCTAssertEqual(reducer.sessions.first?.phase, .running)
            XCTAssertNil(reducer.sessions.first?.question)
            let explicit = try event("AskQuestion", provider: provider, extra: ["tool_use_id": .string("explicit")])
            XCTAssertEqual(explicit.question?.canAnswer, false)
            XCTAssertNotNil(explicit.question?.expiresAt)
        }
    }

}
