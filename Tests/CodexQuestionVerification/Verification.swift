import Foundation
import IslandCore

@main struct Verification {
    static func main() throws {
        var clock = Date()
        func event(_ name: String, tool: String = "request_user_input", id: String = "ask-1", input: [String: JSONValue] = [:], extra: [String: JSONValue] = [:]) throws -> NormalizedHookEvent {
            clock.addTimeInterval(1)
            var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string("codex-question"), "tool_name": .string(tool), "tool_use_id": .string(id), "tool_input": .object(input), "timestamp": .number(clock.timeIntervalSince1970)]
            raw.merge(extra) { _, new in new }
            return try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(JSONValue.object(raw)), provider: .codex)
        }
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: message, code: 1) }
        }
        let input: [String: JSONValue] = ["questions": .array([.object(["id": .string("choice"), "question": .string("如何处理？"), "options": .array([.object(["label": .string("先记录"), "description": .string("保留待确认项")])])])])]
        var reducer = SessionReducer()
        let pre = try event("PreToolUse", input: input)
        reducer.apply(pre)
        try require(reducer.sessions.first?.phase == .waitingQuestion, "Codex asking a question must show waiting, not running")
        try require(pre.question?.prompt == "如何处理？" && pre.question?.options == ["先记录"] && pre.question?.canAnswer == false, "Show the actual question without a fabricated response channel")
        reducer.apply(try event("PostToolUse", tool: "exec_command", id: "unrelated"))
        try require(reducer.sessions.first?.phase == .waitingQuestion && reducer.sessions.first?.detail == "如何处理？", "Other activity must not replace a pending question")
        reducer.apply(try event("PostToolUse"))
        try require(reducer.sessions.first?.phase == .running && reducer.sessions.first?.question == nil, "A synchronous tool answer resolves its question")

        let asyncInput: [String: JSONValue] = ["questions": .array([.object(["title": .string("先修正等待状态？"), "options": .array([.string("先修正"), .string("同时接回复")])]), .object(["title": .string("需要保留日志吗？")])])]
        reducer.apply(try event("PreToolUse", tool: "functions.request_user_input_async", id: "async-1", input: asyncInput, extra: ["turn_id": .string("ask-turn")]))
        reducer.apply(try event("PostToolUse", tool: "functions.request_user_input_async", id: "async-1", extra: ["tool_response": .object(["accepted": .bool(true)])]))
        reducer.apply(try event("PostToolUse", tool: "request_user_input_async", id: "async-1", extra: ["tool_response": .string("{\"accepted\":true}")]))
        try require(reducer.sessions.first?.phase == .waitingQuestion, "Async accepted is not a user answer")
        clock.addTimeInterval(1)
        reducer.apply(.init(source: .codex, sessionID: "codex-question", timestamp: clock, kind: .approvalRequested, approval: .init(id: "approval", toolName: "Bash", canDeny: true)))
        try require(reducer.sessions.first?.phase == .waitingApproval, "An independent permission request remains actionable")
        try require(reducer.resolveApproval(sessionKey: pre.sessionKey, requestID: "approval", decision: .deny), "Permission request resolves")
        try require(reducer.sessions.first?.phase == .waitingQuestion, "An approval decision must restore the unanswered question")
        reducer.apply(try event("Stop"))
        try require(reducer.sessions.first?.phase == .waitingQuestion, "A stopped turn must retain unanswered asynchronous questions")
        func reply(_ call: String, _ index: Int) throws -> NormalizedHookEvent {
            let itemID = String(data: try JSONEncoder().encode([JSONValue.string("request_user_input_async"), .string(call), .number(Double(index))]), encoding: .utf8)!
            let payload = try JSONEncoder().encode([["questionItemId": itemID, "question": "问题", "answer": "先修正"]])
            return try event("UserPromptSubmit", extra: ["prompt": .string("<send_user_message_question_reply>\n" + String(data: payload, encoding: .utf8)! + "\n</send_user_message_question_reply>")])
        }
        reducer.apply(try reply("unrelated", 0))
        try require(reducer.sessions.first?.phase == .waitingQuestion, "An old answer cannot clear the current question")
        reducer.apply(try reply("async-1", 0))
        try require(reducer.sessions.first?.phase == .waitingQuestion, "A partially answered batch is still waiting")
        var answered = try reply("async-1", 1)
        // Replies after Stop can start a new turn while still resolving the old call.
        answered.turnID = "reply-turn"
        try require(answered.title == nil, "A reply envelope must never become the task title")
        reducer.apply(answered)
        try require(reducer.sessions.first?.phase == .running && reducer.sessions.first?.question == nil, "All answered items resolve the asynchronous request")
        reducer.apply(try event("PreToolUse", tool: "request_user_input_async", id: "async-2", input: asyncInput))
        reducer.apply(try event("UserPromptSubmit", extra: ["prompt": .string("继续处理新需求")]))
        try require(reducer.sessions.first?.phase == .running && reducer.sessions.first?.title == "继续处理新需求", "A new user request supersedes waiting questions")
        let unknown = try event("PreToolUse", id: " ", input: input)
        try require(unknown.kind == .activity && unknown.question == nil, "Uncorrelated tool observations cannot create a permanent wait")
        reducer.apply(try event("PreToolUse", tool: "request_user_input_async", id: "rejected", input: asyncInput))
        reducer.apply(try event("PostToolUse", tool: "request_user_input_async", id: "rejected", extra: ["tool_response": .string("request was rejected")]))
        try require(reducer.sessions.first?.phase == .running, "A rejected async tool must not leave an unanswered question")
        reducer.apply(try event("PreToolUse", tool: "request_user_input_async", id: "parallel-1", input: asyncInput))
        reducer.apply(try event("PreToolUse", tool: "request_user_input_async", id: "parallel-2", input: asyncInput))
        reducer.apply(try reply("parallel-1", 0))
        reducer.apply(try reply("parallel-1", 1))
        try require(reducer.sessions.first?.question?.id == "parallel-2", "Answering one call must preserve another unanswered call")
        reducer.apply(try event("Interrupt"))
        try require(reducer.sessions.first?.phase == .interrupted && reducer.sessions.first?.question == nil, "Interrupt clears pending questions")
        let otherSource = try HookNormalizer.normalize(rawJSON: Data(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_use_id":"ask","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Which?"}]}}"#.utf8), provider: .claude)
        try require(otherSource.kind == .activity, "Codex tool names must not alter other source protocols")
        print("PASS: Codex sync/async question lifecycle, exact replies, partial answers, titles and unrelated activity")
    }
}
