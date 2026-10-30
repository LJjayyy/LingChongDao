import Foundation

/// Shared status categories, ordered by the attention they require.
public enum SessionStatusKind: String, CaseIterable, Sendable, Identifiable {
    case question, approval, attention, running, result

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .question: return "待回答"
        case .approval: return "待批准"
        case .attention: return "失败或中断"
        case .running: return "运行中"
        case .result: return "新结果"
        }
    }

    /// Visibility is deliberately separate: callers can also classify history rows.
    public init(session: IslandSession) {
        if session.hasPendingQuestion { self = .question }
        else if session.hasPendingApproval { self = .approval }
        else {
            switch session.phase {
            case .failed, .interrupted: self = .attention
            case .running: self = .running
            case .completed, .idle, .waitingApproval, .waitingQuestion: self = .result
            }
        }
    }
}

public struct SessionStatusCount: Identifiable, Equatable, Sendable {
    public let kind: SessionStatusKind
    /// The actual count remains available for accessibility and totals.
    public let count: Int
    public var id: String { kind.id }
    public var displayCount: String { count > 99 ? "99+" : String(count) }

    public init(kind: SessionStatusKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

public enum SessionStatusSummary {
    /// One category per visible session; stable priority order and no zero badges.
    public static func counts(for sessions: [IslandSession]) -> [SessionStatusCount] {
        var totals: [SessionStatusKind: Int] = [:]
        for session in sessions where session.isVisibleOnIsland {
            totals[SessionStatusKind(session: session), default: 0] += 1
        }
        return SessionStatusKind.allCases.compactMap { kind in
            guard let count = totals[kind], count > 0 else { return nil }
            return SessionStatusCount(kind: kind, count: count)
        }
    }
}
