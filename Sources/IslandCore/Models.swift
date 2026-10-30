import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable { case qoder, codex, claude, zcode, dsh, codebuddy, workbuddy, generic }
public enum SourceApplicationID: String, Codable, Sendable {
    case qoderDesktop = "qoder-cn-desktop"
    case qoderIDE = "qoder-cn-ide"
    case qoderUnknown = "qoder-unknown"
    case codexDesktop = "codex-desktop"
    case codexChatGPT = "codex-chatgpt"
    case zcodeDesktop = "zcode-desktop"
    case dshDesktop = "dsh-desktop"
    case codebuddyCNIDE = "codebuddy-cn-ide"
    case codebuddyUnknown = "codebuddy-unknown"
    case workbuddyDesktop = "workbuddy-desktop"
    case workbuddyAI = "workbuddy-ai"
    case workbuddyUnknown = "workbuddy-unknown"
    case claudeDesktop = "claude-desktop"
    case claudeVSCode = "claude-vscode"
    case claudeCursor = "claude-cursor"
    case claudeIntelliJ = "claude-intellij"
    case claudePyCharm = "claude-pycharm"
    case claudeWebStorm = "claude-webstorm"
    case claudeGoLand = "claude-goland"
    case claudeTerminal = "claude-terminal"
    case claudeITerm = "claude-iterm"
    case claudeWarp = "claude-warp"
    case claudeUnknown = "claude-unknown"
    public var provider: ProviderID {
        switch self {
        case .qoderDesktop, .qoderIDE, .qoderUnknown: return .qoder
        case .codexDesktop, .codexChatGPT: return .codex
        case .claudeDesktop, .claudeVSCode, .claudeCursor, .claudeIntelliJ, .claudePyCharm, .claudeWebStorm, .claudeGoLand, .claudeTerminal, .claudeITerm, .claudeWarp, .claudeUnknown: return .claude
        case .zcodeDesktop: return .zcode
        case .dshDesktop: return .dsh
        case .codebuddyCNIDE, .codebuddyUnknown: return .codebuddy
        case .workbuddyDesktop, .workbuddyAI, .workbuddyUnknown: return .workbuddy
        }
    }
    public var bundleIdentifier: String? {
        switch self { case .claudeDesktop: return "com.anthropic.claudefordesktop"; case .claudeVSCode: return "com.microsoft.VSCode"; case .claudeCursor: return "com.todesktop.230313mzl4w4u92"; case .claudeIntelliJ: return "com.jetbrains.intellij"; case .claudePyCharm: return "com.jetbrains.pycharm"; case .claudeWebStorm: return "com.jetbrains.WebStorm"; case .claudeGoLand: return "com.jetbrains.goland"; case .claudeTerminal: return "com.apple.Terminal"; case .claudeITerm: return "com.googlecode.iterm2"; case .claudeWarp: return "dev.warp.Warp-Stable"; case .claudeUnknown: return nil; case .qoderDesktop: return "com.qodercn.app"; case .qoderIDE: return "com.aliyun.lingma.ide"; case .qoderUnknown: return nil; case .codexDesktop: return "com.openai.codex"; case .codexChatGPT: return "com.openai.chat"; case .zcodeDesktop: return "dev.zcode.app"; case .dshDesktop: return "com.deepseek.dsh"; case .codebuddyCNIDE: return "com.tencent.codebuddycn"; case .codebuddyUnknown, .workbuddyUnknown: return nil; case .workbuddyDesktop: return "com.tencent.workbuddy.mac"; case .workbuddyAI: return "com.workbuddy.workbuddy-ai" }
    }
}
public enum SessionPhase: String, Codable, CaseIterable, Sendable { case idle, running, waitingApproval, waitingQuestion, completed, failed, interrupted }
public enum ApprovalDecision: String, Codable, Sendable { case allow, deny, fallback }

public enum SessionIdentity {
    /// Length-prefixed fields prevent delimiter collisions and distinguish forked threads.
    public static func key(source: ProviderID, host: String = "localhost", sessionID: String, threadID: String?, sourceApplication: SourceApplicationID? = nil) -> String {
        var fields = [source.rawValue, host, sessionID, threadID ?? ""]
        switch source {
        case .qoder: fields.append((sourceApplication?.provider == source ? sourceApplication : nil)?.rawValue ?? SourceApplicationID.qoderUnknown.rawValue)
        case .codebuddy: fields.append((sourceApplication?.provider == source ? sourceApplication : nil)?.rawValue ?? SourceApplicationID.codebuddyUnknown.rawValue)
        case .workbuddy: fields.append((sourceApplication?.provider == source ? sourceApplication : nil)?.rawValue ?? SourceApplicationID.workbuddyUnknown.rawValue)
        case .claude: fields.append((sourceApplication?.provider == source ? sourceApplication : nil)?.rawValue ?? SourceApplicationID.claudeUnknown.rawValue)
        case .dsh, .zcode, .codex, .generic: break
        }
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct ApprovalRequest: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var toolName: String
    public var command: String?
    public var cwd: String
    public var summary: String
    public var previewLabel: String?
    public var canApprove: Bool
    public var canDeny: Bool
    public var createdAt: Date
    public var expiresAt: Date?
    public init(id: String, toolName: String, command: String? = nil, cwd: String = "", summary: String = "", canApprove: Bool = false, canDeny: Bool = false, previewLabel: String? = nil, createdAt: Date = Date(), expiresAt: Date? = nil) {
        self.previewLabel = previewLabel
        self.id = id; self.toolName = toolName; self.command = command; self.cwd = cwd; self.summary = summary; self.canApprove = canApprove; self.canDeny = canDeny; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
    public func isExpired(at date: Date = Date()) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

public struct QuestionRequest: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var options: [String]
    public var canAnswer: Bool
    public var expiresAt: Date?
    /// Codex async questions are answered as later user messages, one item at a time.
    public var responseItemIDs: [String]?
    public init(id: String, prompt: String, options: [String] = [], canAnswer: Bool = false, expiresAt: Date? = nil, responseItemIDs: [String]? = nil) {
        self.id = id; self.prompt = prompt; self.options = options; self.canAnswer = canAnswer; self.expiresAt = expiresAt
        self.responseItemIDs = responseItemIDs
    }
    public func isExpired(at date: Date = Date()) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

public struct IslandSession: Identifiable, Codable, Equatable, Sendable {
    public var source: ProviderID
    public var sourceApplication: SourceApplicationID?
    public var host: String
    public var sessionID: String
    public var threadID: String?
    public var turnID: String?
    public var title: String
    public var agentName: String?
    public var cwd: String
    public var detail: String
    public var phase: SessionPhase
    public var updatedAt: Date
    public var unread: Bool
    public var approval: ApprovalRequest?
    public var question: QuestionRequest?
    public var id: String { SessionIdentity.key(source: source, host: host, sessionID: sessionID, threadID: threadID, sourceApplication: sourceApplication) }
    public var displayTitle: String { SessionTitle.displayTitle(title: title, cwd: cwd, question: question?.prompt) }
    public var hasPendingApproval: Bool { phase == .waitingApproval && approval.map { !$0.isExpired() } == true }
    public var hasPendingQuestion: Bool { phase == .waitingQuestion && question.map { !$0.isExpired() } == true }
    public var isAwaitingInteraction: Bool { hasPendingApproval || hasPendingQuestion }
    public var isVisibleOnIsland: Bool { phase == .running || isAwaitingInteraction || (unread && approval == nil && question == nil) }
    public var priority: Int {
        if hasPendingQuestion { return 0 }; if hasPendingApproval { return 1 }
        switch phase { case .failed, .interrupted: return 2; case .completed: return 3; case .running: return 4; default: return 5 }
    }
    public init(source: ProviderID, host: String = "localhost", sessionID: String, threadID: String? = nil, turnID: String? = nil, title: String, agentName: String? = nil, cwd: String = "", detail: String = "", phase: SessionPhase = .idle, updatedAt: Date = Date(), unread: Bool = false, approval: ApprovalRequest? = nil, question: QuestionRequest? = nil, sourceApplication: SourceApplicationID? = nil) {
        self.sourceApplication = sourceApplication?.provider == source ? sourceApplication : nil
        self.source = source; self.host = host; self.sessionID = sessionID; self.threadID = threadID; self.turnID = turnID; self.title = title; self.agentName = agentName; self.cwd = cwd; self.detail = detail; self.phase = phase; self.updatedAt = updatedAt; self.unread = unread; self.approval = approval; self.question = question
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .object(let item): try value.encode(item); case .array(let item): try value.encode(item); case .string(let item): try value.encode(item); case .number(let item): try value.encode(item); case .bool(let item): try value.encode(item); case .null: try value.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let values) = self { return values[key] }; return nil }
    public var stringValue: String? { if case .string(let item) = self { return item }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let item) = self { return item }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let item) = self { return item }; return nil }
    public var boolValue: Bool? { if case .bool(let item) = self { return item }; return nil }
    public var numberValue: Double? { if case .number(let item) = self { return item }; return nil }
}

public enum HookEventKind: String, Codable, Sendable { case started, sessionResumed, activity, permissionObserved, permissionPrompted, approvalRequested, questionRequested, turnStopped, sessionEnded, completed, failed, interrupted, approvalResolved, questionResolved }
public struct NormalizedHookEvent: Codable, Equatable, Sendable {
    public var eventID: String
    public var source: ProviderID
    public var sourceApplication: SourceApplicationID?
    public var host: String
    public var sessionID: String
    public var threadID: String?
    public var turnID: String?
    public var interactionID: String?
    public var timestamp: Date
    public var kind: HookEventKind
    public var title: String?
    public var agentName: String?
    public var cwd: String?
    public var detail: String?
    public var approval: ApprovalRequest?
    public var question: QuestionRequest?
    public var answeredQuestionItemIDs: [String]?
    public var isSubagent: Bool
    public var sessionKey: String { SessionIdentity.key(source: source, host: host, sessionID: sessionID, threadID: threadID, sourceApplication: sourceApplication) }
    public init(eventID: String = UUID().uuidString, source: ProviderID, host: String = "localhost", sessionID: String, threadID: String? = nil, turnID: String? = nil, interactionID: String? = nil, timestamp: Date = Date(), kind: HookEventKind, title: String? = nil, agentName: String? = nil, cwd: String? = nil, detail: String? = nil, approval: ApprovalRequest? = nil, question: QuestionRequest? = nil, isSubagent: Bool = false, sourceApplication: SourceApplicationID? = nil) {
        self.sourceApplication = sourceApplication?.provider == source ? sourceApplication : nil
        self.eventID = eventID; self.source = source; self.host = host; self.sessionID = sessionID; self.threadID = threadID; self.turnID = turnID; self.interactionID = interactionID; self.timestamp = timestamp; self.kind = kind; self.title = title; self.agentName = agentName; self.cwd = cwd; self.detail = detail; self.approval = approval; self.question = question; self.isSubagent = isSubagent
    }
}

public enum BridgeOperation: String, Codable, Sendable { case event, ping, status }
public struct BridgeEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var requestID: String
    public var provider: ProviderID
    public var sourceApplication: SourceApplicationID?
    public var raw: JSONValue
    public var operation: BridgeOperation
    public var deadline: Date?
    public init(version: Int = 1, provider: ProviderID, raw: JSONValue = .object([:]), requestID: String = UUID().uuidString, operation: BridgeOperation = .event, deadline: Date? = nil, sourceApplication: SourceApplicationID? = nil) {
        self.sourceApplication = sourceApplication?.provider == provider ? sourceApplication : nil
        self.version = version; self.provider = provider; self.raw = raw; self.requestID = requestID; self.operation = operation; self.deadline = deadline
    }
    public var rawJSON: Data { get throws { try JSONEncoder().encode(raw) } }
}
public enum BridgeDisposition: String, Codable, Sendable { case acknowledged, allow, deny, fallback, status }
public struct BridgeReply: Codable, Equatable, Sendable {
    public var disposition: BridgeDisposition
    public var message: String?
    public var requestID: String?
    public init(disposition: BridgeDisposition, message: String? = nil, requestID: String? = nil) { self.disposition = disposition; self.message = message; self.requestID = requestID }
    public static var acknowledged: BridgeReply { BridgeReply(disposition: .acknowledged) }
    public static func fallback(_ reason: String) -> BridgeReply { BridgeReply(disposition: .fallback, message: reason) }
}
