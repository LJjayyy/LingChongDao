import Foundation
import Darwin
import IslandCore

private var failures = 0
private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if condition() { print("PASS \(message)") }
    else { failures += 1; print("FAIL \(message)") }
}

@main struct WorkBuddyVerification {
    static func main() throws {
        let base = Date().addingTimeInterval(-600)
        let sessionID = "12345678-1234-4abc-9876-1234567890ab"
        func event(_ name: String, _ offset: Double, turn: String = "turn-1", provider: ProviderID = .workbuddy,
                   extra: [String: JSONValue] = [:]) throws -> NormalizedHookEvent {
            var raw: [String: JSONValue] = ["session_id": .string(sessionID), "hook_event_name": .string(name),
                "event_id": .string(UUID().uuidString), "timestamp": .number(base.addingTimeInterval(offset).timeIntervalSince1970),
                "turn_id": .string(turn)]
            raw.merge(extra) { _, value in value }
            return try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(raw), provider: provider,
                sourceApplication: provider == .workbuddy ? .workbuddyDesktop : .codebuddyCNIDE)
        }
        func question(_ id: String) -> [String: JSONValue] {
            ["tool_use_id": .string(id), "tool_name": .string("AskQuestion"),
             "tool_input": .object(["question": .string("选择哪个格式？")])]
        }

        let stop = try event("Stop", 1, extra: ["last_assistant_message": .string("  已整理三条要点。\n请检查。  ")])
        check(stop.kind == .turnStopped, "Stop stays an ended turn, never inferred success")
        check(stop.detail?.contains("已整理三条要点。") == true, "Stop preserves the actual reply summary")
        let noSummary = try event("Stop", 2)
        check(noSummary.detail == "本轮响应已停止，完成结果待原工具确认。", "Missing reply retains conservative fallback")
        let sensitive = try event("Stop", 3, extra: ["last_assistant_message": .string("api_key=private-value")])
        check(sensitive.detail?.contains("private-value") == false, "Sensitive reply is not exposed in summary")
        let longReply = try event("Stop", 4, extra: ["last_assistant_message": .string(String(repeating: "内容", count: 1000))])
        check((longReply.detail?.count ?? 0) <= 601, "Reply summary is bounded")
        let codeStop = try event("Stop", 5, provider: .codebuddy, extra: ["last_assistant_message": .string("different provider")])
        check(codeStop.detail == "本轮响应已停止，完成结果待原工具确认。", "Other provider summary behavior is unchanged")

        var reducer = SessionReducer()
        let start = try event("UserPromptSubmit", 10, extra: ["prompt": .string("整理三条要点")])
        reducer.apply(start)
        check(reducer.sessions.first?.phase == .running, "Prompt starts ordinary WorkBuddy conversation")
        reducer.apply(try event("PreToolUse", 11, extra: ["tool_name": .string("Read"), "tool_input": .object(["description": .string("读取材料")])]))
        reducer.apply(try event("Stop", 12, extra: ["last_assistant_message": .string("已整理三条要点。")]))
        let ended = reducer.sessionsByID[start.sessionKey]!
        reducer.apply(try event("SessionEnd", 13))
        let afterEnd = reducer.sessionsByID[start.sessionKey]!
        check(afterEnd.unread && afterEnd.isVisibleOnIsland, "SessionEnd keeps existing unread turn result visible")
        check(afterEnd.detail == ended.detail && afterEnd.phase == .idle, "SessionEnd preserves ended-turn summary without success")
        reducer.markRead(sessionKey: start.sessionKey)
        reducer.apply(try event("SessionEnd", 14))
        check(reducer.sessionsByID[start.sessionKey]?.unread == false, "Repeated SessionEnd never revives an acknowledged result")
        reducer.apply(try event("UserPromptSubmit", 20, turn: "turn-2", extra: ["prompt": .string("继续补充")]))
        check(reducer.sessions.first?.phase == .running && reducer.sessions.first?.unread == false, "Follow-up starts running and clears old unread result")
        let staleStop = try event("Stop", 21, turn: "turn-1", extra: ["last_assistant_message": .string("旧结果")])
        check(!reducer.apply(staleStop), "Known prior-turn Stop cannot overwrite a follow-up")
        check(reducer.sessions.first?.phase == .running && reducer.sessions.first?.detail != "旧结果", "Follow-up state survives late prior-turn result")
        reducer.apply(try event("SessionEnd", 22, turn: "turn-2"))
        check(reducer.sessionsByID[start.sessionKey]?.unread == false, "SessionEnd without a turn result creates no unread completion")

        var waiting = SessionReducer()
        let pre = try event("PreToolUse", 30, extra: question("question-1"))
        waiting.apply(pre)
        waiting.expireRequests(at: base.addingTimeInterval(141))
        let expired = waiting.sessionsByID[pre.sessionKey]!
        check(expired.isVisibleOnIsland && expired.unread && expired.question?.id == "question-1", "Expired observation stays visible instead of disappearing")
        check(expired.detail.contains("状态待核实"), "Expired observation honestly requests source verification")
        check(expired.needsStatusVerification && SessionStatusKind(session: expired) == .unverified, "Expired observation is classified as unverified, not a new result")
        check(!expired.hasPendingQuestion && expired.question?.canAnswer == false, "Expired observation never pretends to be an actionable question")
        check(SessionNavigation.conversationURL(for: expired, applicationBundleIdentifier: "com.tencent.workbuddy.mac") != nil, "Expired observation keeps exact source-conversation navigation")
        waiting.markRead(sessionKey: pre.sessionKey)
        check(waiting.sessionsByID[pre.sessionKey]?.isVisibleOnIsland == true, "Reading does not silently resolve uncertain source state")
        waiting.expireRequests(at: base.addingTimeInterval(141.5))
        check(waiting.sessionsByID[pre.sessionKey]?.unread == false, "Repeated expiry tick does not manufacture another unread alert")
        waiting.apply(try event("PostToolUse", 142, extra: ["tool_name": .string("Read"), "tool_use_id": .string("other")]))
        check(waiting.sessionsByID[pre.sessionKey]?.question?.id == "question-1", "Unrelated tool result cannot resolve expired observation")
        waiting.apply(try event("PostToolUse", 143, extra: question("wrong-question")))
        check(waiting.sessionsByID[pre.sessionKey]?.question?.id == "question-1", "Different question result cannot resolve expired observation")
        waiting.apply(try event("PostToolUse", 144, extra: question("question-1")))
        check(waiting.sessionsByID[pre.sessionKey]?.question == nil && waiting.sessionsByID[pre.sessionKey]?.phase == .running, "Matching late answer resolves observation and resumes work")

        waiting.apply(try event("PreToolUse", 150, extra: question("question-2")))
        waiting.expireRequests(at: base.addingTimeInterval(261))
        check(waiting.dismissSession(sessionKey: pre.sessionKey), "Expired observation can be manually dismissed")
        waiting.expireRequests(at: base.addingTimeInterval(262))
        check(waiting.sessionsByID[pre.sessionKey]?.question == nil && waiting.sessions.isEmpty, "Timer does not resurrect manually dismissed observation")
        waiting.apply(try event("PreToolUse", 270, extra: question("question-3")))
        waiting.expireRequests(at: base.addingTimeInterval(381))
        waiting.apply(try event("UserPromptSubmit", 382, turn: "turn-2", extra: ["prompt": .string("改用简短格式")]))
        waiting.apply(try event("PostToolUse", 383, turn: "turn-1", extra: question("question-3")))
        check(waiting.sessions.first?.phase == .running && waiting.sessions.first?.question == nil, "New prompt retires uncertain question and rejects old answer")
        waiting.apply(try event("PreToolUse", 390, turn: "turn-2", extra: question("question-4")))
        waiting.expireRequests(at: base.addingTimeInterval(501))
        waiting.apply(try event("Stop", 502, turn: "turn-2"))
        check(waiting.sessions.first?.question == nil && waiting.sessions.first?.phase == .idle, "Explicit turn end retires uncertain question")

        var parallel = SessionReducer()
        let first = try event("UserPromptSubmit", 510, extra: ["prompt": .string("第一条对话")])
        let second = try event("UserPromptSubmit", 511, extra: ["session_id": .string("22345678-1234-4abc-9876-1234567890ab"), "prompt": .string("第二条对话")])
        parallel.apply(first); parallel.apply(second)
        parallel.apply(try event("Stop", 512, extra: ["last_assistant_message": .string("第一条回复")]))
        check(parallel.sessionsByID[first.sessionKey]?.phase == .idle && parallel.sessionsByID[second.sessionKey]?.phase == .running, "Concurrent conversations retain independent phases")
        check(parallel.sessionsByID[first.sessionKey]?.title == "第一条对话" && parallel.sessionsByID[second.sessionKey]?.title == "第二条对话", "Concurrent conversations retain independent titles")
        parallel.apply(try event("SessionEnd", 513))
        check(parallel.sessionsByID[first.sessionKey]?.unread == true && parallel.sessionsByID[second.sessionKey]?.unread == false, "Session closure never consumes another conversation's unread state")

        var terminal = SessionReducer()
        terminal.apply(try event("UserPromptSubmit", 520))
        terminal.apply(try event("Interrupt", 521))
        terminal.apply(try event("SessionEnd", 522))
        check(terminal.sessions.first?.phase == .interrupted && terminal.sessions.first?.unread == true, "Session closure preserves an observed interruption")
        let duplicate = try event("Stop", 530, turn: "turn-2", extra: ["last_assistant_message": .string("第二轮结果")])
        terminal.apply(try event("UserPromptSubmit", 529, turn: "turn-2"))
        terminal.apply(duplicate)
        terminal.markRead(sessionKey: duplicate.sessionKey)
        check(!terminal.apply(duplicate) && terminal.sessionsByID[duplicate.sessionKey]?.unread == false, "Duplicate Stop cannot re-announce an acknowledged result")
        let older = try event("PreToolUse", 528, turn: "turn-2", extra: ["tool_name": .string("Read")])
        check(!terminal.apply(older), "Older tool event cannot resurrect an ended turn")

        var other = SessionReducer()
        let otherPre = try event("PreToolUse", 30, provider: .codebuddy, extra: question("question-1"))
        other.apply(otherPre)
        other.expireRequests(at: base.addingTimeInterval(141))
        check(other.sessions.isEmpty, "Other providers keep their previous question expiry policy")

        // Shape-compatible minimal desktop inputs, not captured native payloads.
        // Do not assume that WorkBuddy supplies turn_id, timestamp or event_id.
        func desktopEvent(_ name: String, extra: [String: JSONValue] = [:]) throws -> NormalizedHookEvent {
            var raw: [String: JSONValue] = ["session_id": .string(sessionID),
                "hook_event_name": .string(name), "cwd": .string("/tmp/lingchongdao-workbuddy-verification")]
            raw.merge(extra) { _, value in value }
            return try HookNormalizer.normalize(rawJSON: JSONEncoder().encode(raw), provider: .workbuddy,
                sourceApplication: .workbuddyDesktop)
        }
        var desktop = SessionReducer()
        let desktopStart = try desktopEvent("SessionStart")
        check(desktopStart.turnID == nil && desktop.apply(desktopStart), "Minimal desktop SessionStart requires no synthetic turn or event IDs")
        let desktopPrompt = try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("请再检查一遍")])
        check(desktopPrompt.turnID == nil && desktop.apply(desktopPrompt), "Minimal desktop prompt enters the lifecycle without a turn ID")
        check(desktop.sessions.first?.phase == .running && desktop.sessions.first?.title == "请再检查一遍", "Minimal desktop prompt synchronizes running state and title")
        let readInput: JSONValue = .object(["file_path": .string("/tmp/lingchongdao-workbuddy-verification/input.txt")])
        let readOne = try desktopEvent("PreToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("desktop-read-1"), "tool_input": readInput])
        check(desktop.apply(readOne), "Minimal desktop first Read starts normally")
        let readOneResult = try desktopEvent("PostToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("desktop-read-1"), "tool_input": readInput, "tool_response": .object(["output": .string("材料内容")])])
        check(desktop.apply(readOneResult), "Minimal desktop first Read result is accepted")
        let readTwo = try desktopEvent("PreToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("desktop-read-2"), "tool_input": readInput])
        check(readOne.eventID != readTwo.eventID && desktop.apply(readTwo), "Repeated Read with a distinct call ID is not mistaken for a duplicate")
        let readTwoResult = try desktopEvent("PostToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("desktop-read-2"), "tool_input": readInput, "tool_response": .object(["output": .string("材料内容")])])
        check(desktop.apply(readTwoResult), "Repeated Read result with a distinct call ID is accepted")
        let desktopStop = try desktopEvent("Stop", extra: ["last_assistant_message": .string("已再次检查，内容一致。")])
        check(desktop.apply(desktopStop) && desktop.sessions.first?.phase == .idle && desktop.sessions.first?.unread == true, "Minimal desktop Stop produces an unread ended-turn result")
        check(desktop.sessions.first?.detail == "已再次检查，内容一致。", "Minimal desktop Stop synchronizes its real-shaped reply summary")
        let desktopEnd = try desktopEvent("SessionEnd")
        check(desktop.apply(desktopEnd), "Minimal desktop SessionEnd is accepted without a turn ID")
        check(desktop.sessions.first?.unread == true && desktop.sessions.first?.detail == "已再次检查，内容一致。", "Minimal desktop transport closure keeps the turn summary and unread result")
        desktop.markRead(sessionKey: desktopStart.sessionKey)
        let repeatedPrompt = try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("请再检查一遍")])
        check(repeatedPrompt.eventID != desktopPrompt.eventID && desktop.apply(repeatedPrompt), "Identical follow-up text without source event IDs is a new prompt")
        check(desktop.sessions.first?.phase == .running && desktop.sessions.first?.unread == false && desktop.sessions.first?.turnID == nil, "Identical follow-up resets result state without inventing a turn ID")
        let repeatedStop = try desktopEvent("Stop", extra: ["last_assistant_message": .string("已再次检查，内容一致。")])
        check(desktop.apply(repeatedStop) && desktop.sessions.first?.unread == true, "A later identical reply can produce a new result without source event IDs")
        desktop.apply(try desktopEvent("SessionEnd"))
        check(desktop.sessions.first?.detail == "已再次检查，内容一致。" && desktop.sessions.first?.phase == .idle, "Repeated minimal desktop round preserves its own final summary")

        var desktopQuestion = SessionReducer()
        let desktopQuestionStart = try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("先确认格式")])
        desktopQuestion.apply(desktopQuestionStart)
        desktopQuestion.apply(try desktopEvent("PreToolUse", extra: question("desktop-question-1")))
        check(desktopQuestion.sessions.first?.hasPendingQuestion == true, "Minimal desktop question is correlated by tool call ID without a turn ID")
        let desktopAnswer = try desktopEvent("PostToolUse", extra: question("desktop-question-1"))
        check(desktopQuestion.apply(desktopAnswer) && desktopQuestion.sessions.first?.question == nil, "Minimal desktop matching answer resumes ordinary work")
        desktopQuestion.apply(try desktopEvent("PreToolUse", extra: question("desktop-question-2")))
        desktopQuestion.apply(try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("改用简短格式")]))
        let retiredAnswer = try desktopEvent("PostToolUse", extra: question("desktop-question-2"))
        check(!desktopQuestion.apply(retiredAnswer) && desktopQuestion.sessions.first?.phase == .running && desktopQuestion.sessions.first?.question == nil, "A retired question result cannot restore waiting state after a minimal desktop follow-up")

        var lateChild = SessionReducer()
        lateChild.apply(try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("汇总资料")]))
        lateChild.apply(try desktopEvent("Stop", extra: ["last_assistant_message": .string("主任务已给出三条结论。")]))
        let beforeChild = lateChild.sessionsByID[desktopStart.sessionKey]!
        let childRead = try desktopEvent("PostToolUse", extra: ["is_subagent": .bool(true), "tool_name": .string("Read"),
            "tool_use_id": .string("late-child-read"), "agent_name": .string("research-child"), "cwd": .string("/tmp/child-workspace"),
            "tool_response": .object(["output": .string("迟到的子任务工具输出")])])
        lateChild.apply(childRead)
        check(lateChild.sessionsByID[desktopStart.sessionKey]?.detail == beforeChild.detail, "Late child activity cannot overwrite an observed main-turn reply summary")
        check(lateChild.sessionsByID[desktopStart.sessionKey]?.agentName == beforeChild.agentName && lateChild.sessionsByID[desktopStart.sessionKey]?.cwd == beforeChild.cwd, "Late child activity cannot replace ended main-task metadata")
        lateChild.apply(try desktopEvent("Stop", extra: ["is_subagent": .bool(true), "last_assistant_message": .string("子任务的结束回复")]))
        lateChild.apply(try desktopEvent("SessionEnd"))
        check(lateChild.sessions.first?.detail == "主任务已给出三条结论。" && lateChild.sessions.first?.unread == true, "Late child Stop and SessionEnd preserve the main result")
        lateChild.apply(try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("继续汇总")]))
        lateChild.apply(try desktopEvent("PreToolUse", extra: ["is_subagent": .bool(true), "tool_name": .string("Read"), "tool_use_id": .string("new-child-read")]))
        check(lateChild.sessions.first?.phase == .running && lateChild.sessions.first?.unread == false && lateChild.sessions.first?.detail == "Read", "A genuine new prompt re-enables child progress without retaining old result state")

        // Native tool schema observed in the installed engine; these are not
        // captured events and do not establish when a desktop Hook is delivered.
        let fruitQuestion: JSONValue = .object(["question": .string("  选择哪一种水果？  "), "header": .string("水果"),
            "options": .array([.object(["label": .string("apple"), "description": .string("苹果")]),
                               .object(["label": .string("banana"), "description": .string("香蕉")])]), "multiSelect": .bool(false)])
        let structuredInput: JSONValue = .object(["questions": .array([fruitQuestion])])
        let structured = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"),
            "tool_use_id": .string("structured-question"), "tool_input": structuredInput])
        check(structured.question?.prompt == "选择哪一种水果？" && structured.detail == "选择哪一种水果？", "WorkBuddy native questions array supplies the visible question text")
        check(structured.question?.options == ["apple", "banana"] && structured.question?.canAnswer == false, "Single native question exposes readonly labels without a reply capability")
        let multi = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "call_id": .string("multiple-questions"),
            "tool_input": .object(["questions": .array([fruitQuestion, .object(["question": .string("选择哪一种格式？"),
                "options": .array([.object(["label": .string("pdf")]), .object(["label": .string("txt")])])])])])])
        check(multi.question?.prompt == "选择哪一种水果？\n\n选择哪一种格式？", "Multiple native questions remain readable as separate prompts")
        check(multi.question?.options.isEmpty == true && multi.question?.canAnswer == false, "Multiple native questions never mix separate choices into one answer list")
        let legacy = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskQuestion"), "tool_use_id": .string("legacy-question"),
            "tool_input": .object(["question": .string("旧格式问题？")])])
        check(legacy.question?.prompt == "旧格式问题？", "Legacy top-level question remains compatible")
        let legacyPrompt = try desktopEvent("PreToolUse", extra: ["tool_name": .string("ask_question"), "tool_use_id": .string("legacy-prompt"),
            "tool_input": .object(["prompt": .string("旧格式提示？"), "questions": .string("malformed")])])
        check(legacyPrompt.question?.prompt == "旧格式提示？", "Malformed native array falls back to a legacy prompt")
        let malformed = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("invalid-question"),
            "tool_input": .object(["questions": .array([fruitQuestion, .object(["header": .string("缺少问题")])])])])
        check(malformed.question?.prompt == "请在原工具中回答此问题。" && malformed.question?.options.isEmpty == true, "Partially malformed native questions use a conservative fallback")
        let malformedOptions = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("invalid-options"),
            "tool_input": .object(["questions": .array([.object(["question": .string("仍可阅读的问题？"), "options": .array([.string("invalid"), .number(1)])])])])])
        check(malformedOptions.question?.prompt == "仍可阅读的问题？" && malformedOptions.question?.options.isEmpty == true, "Malformed native choices do not remove a valid readonly question")
        let hugeQuestion = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("long-question"),
            "tool_input": .object(["questions": .array([.object(["question": .string(String(repeating: "问题", count: 2000))])])])])
        check((hugeQuestion.question?.prompt.count ?? 0) <= 2000 && hugeQuestion.question?.prompt.hasSuffix("…") == true, "Native question prompt has a bounded readable preview")
        let uncorrelatedNative = try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_input": structuredInput])
        check(uncorrelatedNative.kind == .activity && uncorrelatedNative.question == nil, "Native structure without a stable call ID never invents a waiting question")
        let unrelatedNative = try desktopEvent("PreToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("unrelated-structure"), "tool_input": structuredInput])
        check(unrelatedNative.kind == .activity && unrelatedNative.question == nil, "Question-shaped data in unrelated tools never creates a question")
        let codeBuddyNative = try event("PreToolUse", 540, provider: .codebuddy, extra: ["tool_name": .string("AskUserQuestion"),
            "tool_use_id": .string("other-provider-structure"), "tool_input": structuredInput])
        check(codeBuddyNative.question?.prompt == "请在原工具中回答此问题。" && codeBuddyNative.question?.options.isEmpty == true, "Native question array adaptation stays WorkBuddy-specific")

        // The native desktop probe observed permission_prompt before the answer,
        // without PreToolUse or a request ID. Treat it as a coarse readonly wait.
        func nativeNotice(_ type: String = "permission_prompt", message: String = "source-specific notification text") throws -> NormalizedHookEvent {
            try desktopEvent("Notification", extra: ["notification_type": .string(type), "message": .string(message)])
        }
        let notice = try nativeNotice()
        check(notice.kind == .permissionPrompted && notice.question == nil, "Native permission notification is a coarse wait, not an invented precise question")
        check(notice.approval?.summary == "WorkBuddy 正在等待确认或回答，请回会话处理。" && notice.approval?.canApprove == false && notice.approval?.canDeny == false, "Native wait exposes no island approval or denial capability")
        check(notice.approval?.expiresAt?.timeIntervalSince(notice.timestamp) == 110, "Native wait has a bounded 110-second observation window")
        check(HookOutput.response(for: .init(disposition: .allow), event: notice) == .object([:]), "Native notification can never return an allow decision")
        var nativeWait = SessionReducer()
        nativeWait.apply(try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("等待确认测试")]))
        nativeWait.apply(try desktopEvent("Notification", extra: ["notification_type": .string("permission_prompt"), "title": .string("Permission required")]))
        check(nativeWait.sessions.first?.title == "等待确认测试", "Native notification title never overwrites the user's conversation title")
        nativeWait.apply(try nativeNotice())
        check(nativeWait.sessions.first?.phase == .waitingApproval && nativeWait.sessions.first?.unread == true, "Native permission notification synchronizes an active conversation to readonly waiting")
        nativeWait.apply(try nativeNotice("idle_prompt"))
        check(nativeWait.sessions.first?.phase == .waitingApproval && nativeWait.sessions.first?.approval?.id == notice.approval?.id, "Unrelated native notification cannot clear a pending coarse wait")
        nativeWait.apply(try desktopEvent("PreToolUse", extra: ["is_subagent": .bool(true), "tool_name": .string("Read"), "tool_use_id": .string("child-during-wait")]))
        check(nativeWait.sessions.first?.phase == .waitingApproval, "Child activity cannot claim the source-native wait was resolved")
        let resumeTool = try desktopEvent("PreToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("main-after-native-answer")])
        check(resumeTool.interactionID == "main-after-native-answer", "WorkBuddy main tool start retains its stable activity identity")
        nativeWait.apply(resumeTool)
        check(nativeWait.sessions.first?.phase == .waitingApproval && nativeWait.sessions.first?.approval != nil, "Unrelated main Read cannot resolve an unbound source-native wait")
        nativeWait.apply(try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("native-answer-tool"), "tool_input": structuredInput]))
        check(nativeWait.sessions.first?.phase == .waitingApproval && nativeWait.sessions.first?.question == nil, "Unbound coarse wait cannot be resolved by guessing that a question tool is related")
        let boundNotice = try nativeNotice(message: "CodeBuddy needs your permission to use AskUserQuestion")
        check(boundNotice.approval?.toolName == "AskUserQuestion", "Fixed source message suffix can bind a readonly notice to the exact native question tool")
        check(boundNotice.toolName == nil && resumeTool.toolName == "Read", "Normalized actual tool names stay separate from notification text bindings")
        nativeWait.apply(boundNotice)
        nativeWait.apply(try desktopEvent("PreToolUse", extra: ["tool_name": .string("Read"), "tool_use_id": .string("unrelated-read-during-bound-wait")]))
        check(nativeWait.sessions.first?.phase == .waitingApproval, "Unrelated Read cannot resolve even a tool-bound source notice")
        nativeWait.apply(try desktopEvent("PreToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("bound-native-answer-tool"), "tool_input": structuredInput]))
        check(nativeWait.sessions.first?.phase == .running && nativeWait.sessions.first?.approval == nil && nativeWait.sessions.first?.question == nil, "Native question tool starting after a coarse wait does not invent a second waiting phase")
        nativeWait.apply(try nativeNotice(message: "needs your permission to use AskUserQuestion"))
        nativeWait.apply(try desktopEvent("PostToolUse", extra: ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("native-question-result"), "tool_input": structuredInput]))
        check(nativeWait.sessions.first?.phase == .running && nativeWait.sessions.first?.approval == nil, "Matching question tool result also resolves a bound native notice")
        let unboundMention = try nativeNotice(message: "This text mentions AskUserQuestion but is not the native prompt")
        let trailingText = try nativeNotice(message: "CodeBuddy needs your permission to use AskUserQuestion and another tool")
        check(unboundMention.approval?.toolName == "" && trailingText.approval?.toolName == "", "Arbitrary tool mentions or trailing text never bind the coarse notice")
        nativeWait.apply(try desktopEvent("Stop", extra: ["last_assistant_message": .string("确认后已继续执行。")]))
        let resultBeforeLateNotice = nativeWait.sessions.first!
        let lateNotice = try nativeNotice()
        nativeWait.apply(lateNotice)
        check(nativeWait.sessions.first?.phase == .idle && nativeWait.sessions.first?.approval == nil && nativeWait.sessions.first?.detail == resultBeforeLateNotice.detail, "Late native notice cannot resurrect an ended turn or replace its summary")
        nativeWait.markRead(sessionKey: notice.sessionKey)
        nativeWait.apply(try nativeNotice())
        check(nativeWait.sessionsByID[notice.sessionKey]?.unread == false && nativeWait.sessions.isEmpty, "Late native notice cannot re-announce an acknowledged result")

        var uncertainNative = SessionReducer()
        uncertainNative.apply(try desktopEvent("UserPromptSubmit"))
        var expiredNativeNotice = try nativeNotice()
        expiredNativeNotice.approval?.expiresAt = Date().addingTimeInterval(-1)
        uncertainNative.apply(expiredNativeNotice)
        uncertainNative.expireRequests()
        let uncertainNoticeSession = uncertainNative.sessionsByID[notice.sessionKey]!
        check(uncertainNoticeSession.phase == .waitingApproval && uncertainNoticeSession.needsStatusVerification && uncertainNoticeSession.isVisibleOnIsland && uncertainNoticeSession.unread, "Expired native observation stays visible as status needing verification")
        check(uncertainNoticeSession.detail == "状态待核实，请回 WorkBuddy 查看。" && uncertainNoticeSession.approval?.canApprove == false && uncertainNoticeSession.approval?.canDeny == false, "Expired native observation stays readonly and uses honest status text")
        uncertainNative.markRead(sessionKey: notice.sessionKey)
        uncertainNative.expireRequests()
        check(uncertainNative.sessionsByID[notice.sessionKey]?.isVisibleOnIsland == true && uncertainNative.sessionsByID[notice.sessionKey]?.unread == false, "Repeated expiry and reading do not hide or re-announce uncertain native waiting")
        check(uncertainNative.dismissSession(sessionKey: notice.sessionKey), "Uncertain native wait can be manually closed")
        uncertainNative.expireRequests()
        check(uncertainNative.sessions.isEmpty && uncertainNative.sessionsByID[notice.sessionKey]?.approval == nil, "Expiry timer never resurrects a dismissed native notice")
        uncertainNative.apply(try desktopEvent("UserPromptSubmit"))
        uncertainNative.apply(try nativeNotice())
        check(uncertainNative.dismissSession(sessionKey: notice.sessionKey), "A live readonly native notice can be manually closed without deciding source permission")

        var orphanNotice = SessionReducer()
        orphanNotice.apply(try nativeNotice())
        check(orphanNotice.sessions.isEmpty, "Native notice without an observed active conversation does not manufacture running work")
        orphanNotice.apply(try desktopEvent("UserPromptSubmit"))
        orphanNotice.apply(try desktopEvent("SessionEnd"))
        orphanNotice.apply(try nativeNotice())
        check(orphanNotice.sessions.isEmpty, "Native notice after an empty session closure cannot manufacture a pending task")

        var oldEventObject = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(resumeTool)).objectValue!
        oldEventObject.removeValue(forKey: "toolName")
        let oldEvent = try JSONDecoder().decode(NormalizedHookEvent.self, from: JSONEncoder().encode(JSONValue.object(oldEventObject)))
        check(oldEvent.toolName == nil && oldEvent.kind == resumeTool.kind && oldEvent.sessionKey == resumeTool.sessionKey, "Older normalized event JSON without toolName remains decodable")
        let explicitSessionTitle = try desktopEvent("Notification", extra: ["notification_type": .string("permission_prompt"),
            "title": .string("Permission required"), "session_title": .string("来源明确的任务标题")])
        check(explicitSessionTitle.title == "来源明确的任务标题", "Explicit WorkBuddy session_title remains usable on notification events")
        var nextNativeTurn = SessionReducer()
        nextNativeTurn.apply(try desktopEvent("UserPromptSubmit"))
        nextNativeTurn.apply(try nativeNotice())
        nextNativeTurn.apply(try desktopEvent("UserPromptSubmit", extra: ["prompt": .string("下一条请求")]))
        check(nextNativeTurn.sessions.first?.phase == .running && nextNativeTurn.sessions.first?.approval == nil && nextNativeTurn.sessions.first?.unread == false, "A new prompt reliably retires an unbound coarse wait")

        // Native capture confirmed one generation across prompt/notice/tool/Stop,
        // with a different generation for the next prompt in the same session.
        let generationPrompt = try desktopEvent("UserPromptSubmit", extra: ["generation_id": .string("native-generation-1"), "prompt": .string("第一轮")])
        let generationNotice = try desktopEvent("Notification", extra: ["generation_id": .string("native-generation-1"), "notification_type": .string("permission_prompt")])
        let generationTool = try desktopEvent("PreToolUse", extra: ["generation_id": .string("native-generation-1"), "tool_name": .string("Read"), "tool_use_id": .string("generation-read-1")])
        let generationPost = try desktopEvent("PostToolUse", extra: ["generation_id": .string("native-generation-1"), "tool_name": .string("Read"), "tool_use_id": .string("generation-read-1")])
        let generationStop = try desktopEvent("Stop", extra: ["generation_id": .string("native-generation-1"), "last_assistant_message": .string("第一轮摘要")])
        check([generationPrompt, generationNotice, generationTool, generationPost, generationStop].allSatisfy { $0.turnID == "native-generation-1" }, "Native generation identifies the same WorkBuddy round across the complete event chain")
        var generations = SessionReducer()
        generations.apply(generationPrompt); generations.apply(generationStop)
        let nextGeneration = try desktopEvent("UserPromptSubmit", extra: ["generation_id": .string("native-generation-2"), "prompt": .string("第二轮")])
        generations.apply(nextGeneration)
        let lateGenerationStop = try desktopEvent("Stop", extra: ["generation_id": .string("native-generation-1"), "last_assistant_message": .string("迟到旧摘要")])
        let lateGenerationNotice = try desktopEvent("Notification", extra: ["generation_id": .string("native-generation-1"), "notification_type": .string("permission_prompt")])
        let lateGenerationTool = try desktopEvent("PostToolUse", extra: ["generation_id": .string("native-generation-1"), "tool_name": .string("Read"), "tool_use_id": .string("old-generation-tool")])
        var delayedStopState = generations, delayedNoticeState = generations, delayedToolState = generations
        check(!delayedStopState.apply(lateGenerationStop), "Previous native generation Stop cannot end the next round")
        check(!delayedNoticeState.apply(lateGenerationNotice), "Previous native generation notification cannot create a next-round wait")
        check(!delayedToolState.apply(lateGenerationTool), "Previous native generation tool output cannot overwrite the next round")
        check(generations.sessions.first?.turnID == "native-generation-2" && generations.sessions.first?.title == "第二轮" && generations.sessions.first?.phase == .running && generations.sessions.first?.unread == false, "Native follow-up state remains independent of all previous-generation events")
        let explicitTurn = try desktopEvent("Stop", extra: ["turn_id": .string("explicit-turn"), "generation_id": .string("generation-fallback")])
        let nestedTurn = try desktopEvent("Stop", extra: ["turn": .object(["id": .string("nested-turn")]), "generation_id": .string("generation-fallback")])
        check(explicitTurn.turnID == "explicit-turn" && nestedTurn.turnID == "nested-turn", "Explicit flat and nested turn IDs take precedence over native generation fallback")
        let noGeneration = try desktopEvent("Stop")
        check(noGeneration.turnID == nil, "WorkBuddy events without any turn or generation ID keep a nil turn")
        let foreignGenerationJSON = try JSONEncoder().encode(JSONValue.object(["session_id": .string(sessionID), "hook_event_name": .string("Stop"), "generation_id": .string("foreign-generation")]))
        let foreignGeneration = try [ProviderID.codebuddy, .claude, .codex, .qoder, .generic].map {
            try HookNormalizer.normalize(rawJSON: foreignGenerationJSON, provider: $0)
        }
        check(foreignGeneration.allSatisfy { $0.turnID == nil }, "Native generation fallback does not change other providers")

        print("WorkBuddy verification: \(checks - failures)/\(checks) passed")
        if failures > 0 { exit(1) }
    }
}
