import Foundation

/// Decides when the island should pull itself down without pointer or keyboard
/// focus: whenever a session enters a state that needs the user — an approval or
/// question waiting for an answer, an ended turn whose result awaits review, or
/// a completion, failure or interruption. The reducer keeps `unread` false while
/// running, so unread alone marks every attention state.
public struct AttentionRevealTracker: Sendable {
    /// What one snapshot of visible sessions announces.
    public struct Announcement: Equatable, Sendable {
        /// At least one session newly needs the user since the previous snapshot.
        public var hasNewAnnouncement: Bool
        /// Every session that currently needs the user, so a focused reveal can
        /// show only these rows and hide ordinary running work.
        public var attentionSessionIDs: Set<String>
        public init(hasNewAnnouncement: Bool, attentionSessionIDs: Set<String>) {
            self.hasNewAnnouncement = hasNewAnnouncement
            self.attentionSessionIDs = attentionSessionIDs
        }
    }

    private var lastStates: [String: String] = [:]
    public init() {}
    /// Records a snapshot of visible sessions and reports what it announces.
    public mutating func ingest(_ sessions: [IslandSession]) -> Announcement {
        var states: [String: String] = [:]
        var attention: Set<String> = []
        var hasNew = false
        for session in sessions {
            let state = Self.stateToken(session)
            states[session.id] = state
            guard session.unread, session.phase != .running else { continue }
            attention.insert(session.id)
            if lastStates[session.id] != state { hasNew = true }
        }
        lastStates = states
        return Announcement(hasNewAnnouncement: hasNew, attentionSessionIDs: attention)
    }
    /// Phase plus unread plus pending request IDs, so a second request
    /// re-announces even when the phase itself never changed, and a re-read
    /// snapshot (markRead, source-app attention) never re-announces.
    private static func stateToken(_ session: IslandSession) -> String {
        "\(session.phase.rawValue):\(session.unread):\(session.approval?.id ?? ""):\(session.question?.id ?? "")"
    }
}
