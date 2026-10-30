import Foundation

public enum HookNormalizationError: LocalizedError, Equatable {
    case expectedObject, missingIdentity, missingEvent, unsupportedEvent(String)
    public var errorDescription: String? {
        switch self { case .expectedObject: return "Hook JSON must be an object."; case .missingIdentity: return "Hook has no stable session or thread identity."; case .missingEvent: return "Hook has no event name."; case .unsupportedEvent(let name): return "Unsupported hook event: \(name)." }
    }
}

public enum HookNormalizer {
    public static func normalize(rawJSON: Data, provider: ProviderID, sourceApplication: SourceApplicationID? = nil) throws -> NormalizedHookEvent {
        let raw = try JSONDecoder().decode(JSONValue.self, from: rawJSON)
        guard let object = raw.objectValue else { throw HookNormalizationError.expectedObject }
        func text(_ keys: String...) -> String? { keys.lazy.compactMap { object[$0]?.stringValue }.first { !$0.isEmpty } }
        let threadID = text("thread_id", "threadId", "threadID")
        guard let sessionID = text("session_id", "sessionId", "sessionID") ?? threadID else { throw HookNormalizationError.missingIdentity }
        guard let name = text("hook_event_name", "hookEventName", "event", "type") else { throw HookNormalizationError.missingEvent }
        let canonical = (try? canonicalJSON(raw)) ?? rawJSON
        let interactionKeys = ["tool_use_id", "tool_call_id", "permission_request_id", "request_id", "call_id"]
        // Codex needs a usable correlation ID before a permission event can be
        // treated as an interactive request. Preserve other providers' contract.
        let claudePermissionID = provider == .claude && name == "PermissionRequest"
            ? text("lingchongdao_permission_id").flatMap { UUID(uuidString: $0) == nil ? nil : $0 } : nil
        let codexPermissionID = provider == .codex && name == "PermissionRequest"
            ? text(CodexPermissionBridge.identityKey).flatMap { UUID(uuidString: $0) == nil ? nil : $0 } : nil
        let qoderPermissionID = provider == .qoder && name == "PermissionRequest"
            ? text(QoderPermissionBridge.identityKey).flatMap { UUID(uuidString: $0) == nil ? nil : $0 } : nil
        let stableInteraction = qoderPermissionID ?? codexPermissionID ?? claudePermissionID ?? (provider == .codex
            ? interactionKeys.lazy.compactMap { object[$0]?.stringValue }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            : text("tool_use_id", "tool_call_id", "permission_request_id", "request_id", "call_id"))
        let eventID = text("event_id", "eventId") ?? ((stableInteraction != nil || raw["timestamp"] != nil) ? "\(provider.rawValue)-\(stableHash(canonical))" : UUID().uuidString)
        let time = parseDate(object["timestamp"] ?? object["created_at"]) ?? Date()
        let normalizedCWD = text("cwd", "working_directory")
        let cwd = normalizedCWD ?? ""
        let input = raw["tool_input"]?.objectValue ?? raw["input"]?.objectValue ?? [:]
        let tool = text("tool_name", "toolName") ?? ""
        let isSubagent = name.lowercased().contains("subagent") || text("agent_id", "subagent_id", "subagentId") != nil || raw["is_subagent"]?.boolValue == true
        let command = input["command"]?.stringValue
        let toolResponse = raw["tool_response"]
        let responseText = toolResponse?.stringValue ?? toolResponse?["message"]?.stringValue ?? toolResponse?["output"]?.stringValue ?? toolResponse?["content"]?.stringValue
        var detail = text("message", "description", "notification", "last_assistant_message") ?? input["description"]?.stringValue ?? command ?? responseText ?? (tool.isEmpty ? name : tool)
        var kind: HookEventKind
        var approval: ApprovalRequest?
        var question: QuestionRequest?
        var answeredQuestionItemIDs: [String]?
        switch name {
        case "SessionStart":
            // Claude-family sources fire SessionStart on every transcript open.
            // source == "resume" is the user reopening a finished task — browsing,
            // not work starting — so it must not resurrect an ended session.
            kind = text("source") == "resume" ? .sessionResumed : .started
        case "UserPromptSubmit", "TurnStarted", "turn/started", "turn.started": kind = .started
        case "PermissionRequest":
            let summary = text("permission_description", "description") ?? input["description"]?.stringValue ?? "\(tool.isEmpty ? "操作" : tool) 需要权限"
            if provider == .codex, stableInteraction == nil {
                // An observation is not proof that the user must decide anything.
                // The helper immediately returns normal source handling for it.
                kind = .permissionObserved
                detail = containsSensitiveText(summary + " " + (command ?? ""))
                    ? "来源正在检查权限，请在会话中查看详情。"
                    : "来源权限检查：" + String(summary.prefix(600))
                break
            }
            kind = .approvalRequested
            let identity = stableInteraction ?? "permission-\(stableHash(canonical))"
            // Qoder App 0.4.11 does not retire its native interaction when a
            // Hook decides. Keep formal plugins observation-only across Qoder.
            let hasVerifiedReply = [ProviderID.codex, .zcode].contains(provider) && stableInteraction != nil
            let canApprove = hasVerifiedReply && canPreviewApproval(toolName: tool, input: input, cwd: cwd, summary: summary, reason: raw["reason"], specArtifact: raw["specArtifact"] ?? raw["spec_artifact"])
            approval = ApprovalRequest(id: identity, toolName: tool, command: canApprove ? command : nil, cwd: canApprove ? cwd : "", summary: containsSensitiveText(summary + " " + (command ?? "")) ? "请回原工具查看完整操作。" : String(summary.prefix(600)), canApprove: canApprove, canDeny: hasVerifiedReply, createdAt: time, expiresAt: parseDate(raw["expires_at"] ?? raw["deadline"]) ?? time.addingTimeInterval(45))
            detail = summary
            if provider == .qoder {
                approval?.summary = "Qoder 正在等待权限确认，请回来源处理。"
                approval?.expiresAt = time.addingTimeInterval(110)
                detail = approval!.summary
            }
        case "Elicitation", "UserQuestion", "AskUserQuestion", "AskQuestion", "item/tool/requestUserInput":
            kind = .questionRequested
            let identity = text("tool_use_id", "request_id", "call_id") ?? "question-\(stableHash(canonical))"
            let prompt = text("question", "prompt", "message") ?? "请在原工具中回答此问题。"
            // Lifecycle hooks do not establish a generic question response contract.
            question = QuestionRequest(id: identity, prompt: prompt, canAnswer: false, expiresAt: parseDate(raw["expires_at"]))
        case "Stop": kind = .turnStopped; detail = "本轮响应已停止，完成结果待原工具确认。"
        case "Interrupt", "TurnInterrupted", "turn/interrupted": kind = .interrupted
        case "SessionEnd": kind = .sessionEnded; detail = "会话连接已结束。"
        case "TurnCompleted", "turn/completed", "turn.completed", "agent-turn-complete":
            let status = text("status", "result") ?? raw["turn"]?["status"]?.stringValue
            if status == "failed" || status == "error" { kind = .failed }
            else if status == "interrupted" || status == "cancelled" { kind = .interrupted }
            else if status == "completed" || status == "success" || name == "agent-turn-complete" { kind = .completed }
            else { kind = .turnStopped; detail = "本轮已停止，终态尚未确认。" }
        case "TurnFailed", "turn/failed": kind = .failed
        case "PermissionResolved": kind = .approvalResolved
        case "ElicitationResult", "QuestionResolved": kind = .questionResolved
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "SubagentEnd", "TaskCompleted", "StopFailure", "PreCompact", "PostCompact", "CwdChanged", "ConfigChange", "TeammateIdle":
            kind = .activity
            if name == "PostToolUseFailure" { detail = "工具调用失败：\(tool)。任务状态仍由原工具确认。" }
        default: throw HookNormalizationError.unsupportedEvent(name)
        }
        if provider == .codex {
            if let questionTool = CodexQuestions.toolName(tool), let identity = stableInteraction {
                if name == "PreToolUse", let request = CodexQuestions.request(tool: questionTool, id: identity, input: input) {
                    kind = .questionRequested; question = request; detail = request.prompt
                } else if name == "PostToolUseFailure" || (name == "PostToolUse" && (questionTool == "request_user_input" || !CodexQuestions.accepted(toolResponse))) {
                    kind = .questionResolved
                }
            }
            if name == "UserPromptSubmit", let prompt = text("prompt"), let answers = CodexQuestions.answers(in: prompt) {
                kind = .questionResolved; answeredQuestionItemIDs = answers
                detail = "已在 Codex 回答问题。"
            }
        }
        if provider == .qoder, name == "Notification" {
            if text("notification_type") == "permission_prompt" {
                kind = .permissionPrompted
                approval = ApprovalRequest(id: "qoder-notice-" + sessionID, toolName: "",
                    summary: "Qoder 正在等待权限确认，请回来源处理。", createdAt: time,
                    expiresAt: time.addingTimeInterval(110))
                detail = approval?.summary ?? detail
            } else { kind = .permissionObserved }
        }
        if provider == .qoder, name == "StopFailure" {
            kind = .failed
            detail = "Qoder 本轮响应出错，请回来源查看。"
        }
        if provider == .claude {
            if name == "PermissionRequest" {
                if let identity = claudePermissionID {
                    let preview = ClaudePermissionBridge.preview(tool: tool, input: input, cwd: cwd, raw: raw)
                    kind = .approvalRequested
                    let summary = preview.map { "\($0.label)需要批准" } ?? "\(tool.isEmpty ? "操作" : tool) 需要权限，请核对后处理。"
                    approval = ApprovalRequest(id: identity, toolName: tool, command: preview?.text,
                        cwd: preview == nil ? "" : cwd, summary: summary, canApprove: preview != nil,
                        canDeny: true, previewLabel: preview?.label, createdAt: time,
                        expiresAt: min(parseDate(raw["expires_at"]) ?? .distantFuture, time.addingTimeInterval(90)))
                    detail = summary
                } else {
                    kind = .permissionObserved
                    approval = nil
                    detail = "Claude 权限请求缺少有效审批通道，请回来源处理。"
                }
            } else if name == "Notification" {
                if text("notification_type") == "permission_prompt" {
                    kind = .permissionPrompted
                    approval = ApprovalRequest(id: "claude-notice-" + sessionID, toolName: "",
                        summary: "Claude 正在等待权限确认，请回来源处理。", createdAt: time,
                        expiresAt: time.addingTimeInterval(110))
                    detail = approval?.summary ?? detail
                } else { kind = .permissionObserved }
            } else if name == "StopFailure" {
                kind = .failed
                detail = "Claude 本轮响应出错，请回来源查看。"
            }
        }
        // Buddy requests are observation-only. Only a stable tool identity lets
        // the matching source lifecycle resolve a waiting question safely.
        if provider == .codebuddy || provider == .workbuddy || provider == .claude {
            let questionTools = ["AskQuestion", "ask_question", "AskUserQuestion"]
            if name == "PreToolUse", questionTools.contains(tool), let identity = stableInteraction {
                kind = .questionRequested
                let prompt = input["question"]?.stringValue ?? input["prompt"]?.stringValue ?? "请在原工具中回答此问题。"
                question = QuestionRequest(id: identity, prompt: prompt, canAnswer: false,
                    expiresAt: min(parseDate(raw["expires_at"]) ?? .distantFuture, time.addingTimeInterval(110)))
                detail = prompt
            } else if ["PostToolUse", "PostToolUseFailure"].contains(name), questionTools.contains(tool), stableInteraction != nil {
                kind = .questionResolved
            } else if kind == .questionRequested {
                if let identity = stableInteraction, var pending = question {
                    pending.id = identity
                    pending.expiresAt = min(pending.expiresAt ?? .distantFuture, time.addingTimeInterval(110))
                    question = pending
                } else {
                    // No identity means no reliable completion correlation.
                    kind = .activity
                    question = nil
                }
            }
        }
        let sessionTitle = SessionTitle.normalize(text("session_title"))
            ?? SessionTitle.normalize(text("title"))
        let promptTitle = name == "UserPromptSubmit" ? text("prompt").flatMap({ PromptTitlePolicy.policy(for: provider).title(from: $0) }) : nil
        let eventTitle = sessionTitle ?? promptTitle
        var event = NormalizedHookEvent(eventID: eventID, source: provider, host: text("host", "host_id") ?? "localhost", sessionID: sessionID, threadID: threadID, turnID: text("turn_id", "turnId", "turnID") ?? raw["turn"]?["id"]?.stringValue, interactionID: kind == .activity && !["PostToolUse", "PostToolUseFailure"].contains(name) ? nil : stableInteraction, timestamp: time, kind: kind, title: eventTitle, agentName: text("agent_name", "agentName"), cwd: normalizedCWD, detail: String(detail.prefix(2000)), approval: approval, question: question, isSubagent: isSubagent, sourceApplication: sourceApplication)
        event.answeredQuestionItemIDs = answeredQuestionItemIDs
        return event
    }

    /// Limit inline approval to a completely visible, simple Bash request. Other valid requests can still be denied.
    public static func canPreviewApproval(toolName: String, input: [String: JSONValue], cwd: String, summary: String, reason: JSONValue? = nil, specArtifact: JSONValue? = nil) -> Bool {
        guard toolName == "Bash", let command = input["command"]?.stringValue, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.count <= 600, cwd.count <= 400, summary.count <= 600,
              reason == nil || reason == .null, specArtifact == nil || specArtifact == .null,
              Set(input.keys).isSubset(of: ["command", "description", "timeout", "run_in_background"]),
              !containsSensitiveText(command + " " + summary), !command.contains("\n"), !command.contains("\r"), !command.contains("\u{0}") else { return false }
        return true
    }
    public static func containsSensitiveText(_ text: String) -> Bool {
        text.range(of: "password|secret|token|api[_-]?key|authorization|cookie", options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func canonicalJSON(_ raw: JSONValue) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(raw) }
    private static func stableHash(_ data: Data) -> String { var value: UInt64 = 14695981039346656037; for byte in data { value = (value ^ UInt64(byte)) &* 1099511628211 }; return String(value, radix: 16) }
    private static func parseDate(_ value: JSONValue?) -> Date? {
        if let seconds = value?.numberValue { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        if let text = value?.stringValue { let formatter = ISO8601DateFormatter(); if let result = formatter.date(from: text) { return result }; formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: text) }
        return nil
    }
}
