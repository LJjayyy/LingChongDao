import Darwin
import Foundation
import IslandCore

private enum Failure: Error { case check(String) }

@main
private struct StatusSummaryVerification {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard value() else { throw Failure.check(message) }
    }
    static func session(_ phase: SessionPhase, unread: Bool = true, approval: ApprovalRequest? = nil, question: QuestionRequest? = nil) -> IslandSession {
        IslandSession(source: .generic, sessionID: UUID().uuidString, title: "task", phase: phase, unread: unread, approval: approval, question: question)
    }
    static func main() {
        do {
            let running = session(.running)
            let stopped = session(.idle)
            let mixed = SessionStatusSummary.counts(for: [running, running, stopped])
            try expect(mixed == [.init(kind: .running, count: 2), .init(kind: .result, count: 1)], "two running and one stopped must produce separate green and blue categories")
            let future = Date().addingTimeInterval(3600)
            let pendingQuestion = session(.waitingQuestion, unread: false, question: .init(id: "question", prompt: "which?", expiresAt: future))
            let pendingApproval = session(.waitingApproval, unread: false, approval: .init(id: "approval", toolName: "Bash", expiresAt: future))
            let all = [stopped, running, session(.interrupted), pendingApproval, session(.completed), pendingQuestion, session(.failed)]
            let summary = SessionStatusSummary.counts(for: all)
            try expect(summary.map(\.kind) == SessionStatusKind.allCases, "all categories retain priority order independent of input order")
            try expect(summary.map(\.count) == [1, 1, 2, 1, 2], "failed and interrupted merge, completed and stopped merge")
            try expect(summary.reduce(0) { $0 + $1.count } == all.filter(\.isVisibleOnIsland).count, "summary total equals visible input count")
            try expect(SessionStatusKind(session: pendingQuestion) == .question && SessionStatusKind(session: pendingApproval) == .approval, "read pending interactions still classify as pending")
            let expired = Date().addingTimeInterval(-3600)
            let hidden = [session(.completed, unread: false), session(.failed, unread: false), session(.interrupted, unread: false), session(.idle, unread: false), session(.waitingQuestion, question: .init(id: "expired-question", prompt: "which?", expiresAt: expired)), session(.waitingApproval, approval: .init(id: "expired-approval", toolName: "Bash", expiresAt: expired))]
            try expect(SessionStatusSummary.counts(for: hidden).isEmpty, "read results and expired requests never count")
            let readRunning = session(.running, unread: false)
            try expect(SessionStatusSummary.counts(for: [readRunning]) == [.init(kind: .running, count: 1)], "read running task remains visible")
            try expect(SessionStatusSummary.counts(for: []).isEmpty, "empty input has no zero badges")
            let many = SessionStatusSummary.counts(for: Array(repeating: readRunning, count: 123))
            try expect(many.first?.count == 123 && many.first?.displayCount == "99+", "display caps without losing true count")
            try expect(SessionStatusCount(kind: .running, count: 99).displayCount == "99", "99 does not cap prematurely")
            try expect(SessionStatusCount(kind: .result, count: 100).displayCount == "99+", "100 starts capped display")
            try expect(SessionStatusKind.allCases.map(\.title) == ["待回答", "待批准", "失败或中断", "运行中", "新结果"], "accessibility category titles are meaningful")
            try expect(Set(summary.map(\.id)).count == summary.count, "category identity is stable and unique")
            try expect(SessionStatusSummary.counts(for: all + hidden + [readRunning]).reduce(0) { $0 + $1.count } == (all + hidden + [readRunning]).filter(\.isVisibleOnIsland).count, "mixed read and expired inputs preserve total invariant")
            print("PASS: \(checks) status summary checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
