import Darwin
import Foundation
import IslandCore

private enum Failure: Error { case check(String) }

/// Drives the real HookNormalizer, SessionReducer and AttentionRevealTracker
/// through one Codex-style session and checks which states pull the island down.
@main
private struct AttentionRevealVerification {
    static var checks = 0
    static var reducer = SessionReducer()
    static var tracker = AttentionRevealTracker()
    static var clock = Date().timeIntervalSince1970

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try value() else { throw Failure.check(message) }
        print("PASS \(message)")
    }

    static func event(_ name: String, turn: String, request: String? = nil, extra: [String: String] = [:]) throws -> NormalizedHookEvent {
        clock += 1
        var raw: [String: Any] = ["hook_event_name": name, "session_id": "reveal-check", "turn_id": turn,
                                  "timestamp": clock, "title": "自动下拉验证"]
        if let request {
            raw["tool_use_id"] = request
            raw["tool_name"] = "Bash"
            raw["tool_input"] = ["command": "pwd"]
        }
        for (key, value) in extra { raw[key] = value }
        return try HookNormalizer.normalize(rawJSON: JSONSerialization.data(withJSONObject: raw), provider: .codex)
    }

    /// Sends one event through the reducer, then reports what the snapshot after
    /// it announces.
    @discardableResult
    static func step(_ name: String, turn: String, request: String? = nil, extra: [String: String] = [:]) throws -> AttentionRevealTracker.Announcement {
        _ = reducer.apply(try event(name, turn: turn, request: request, extra: extra))
        return tracker.ingest(reducer.sessions)
    }

    static func expectAttention(_ announcement: AttentionRevealTracker.Announcement, count: Int, _ message: String) throws {
        try expect(announcement.hasNewAnnouncement && announcement.attentionSessionIDs.count == count, "\(message) (attention set: \(announcement.attentionSessionIDs.count))")
    }
    static func expectQuiet(_ announcement: AttentionRevealTracker.Announcement, _ message: String) throws {
        try expect(!announcement.hasNewAnnouncement, message)
    }

    static func main() {
        do {
            try expectQuiet(step("SessionStart", turn: "t1"), "a running task does not pull the island down")
            try expectAttention(step("Stop", turn: "t1"), count: 1, "an ended turn awaiting review pulls the island down")
            try expectQuiet(tracker.ingest(reducer.sessions), "an unchanged ended turn does not pull again")
            let focusedID = unwrap(tracker.ingest(reducer.sessions).attentionSessionIDs.first)
            try expectQuiet(step("UserPromptSubmit", turn: "t2"), "a follow-up running turn does not pull the island down")
            try expect(tracker.ingest(reducer.sessions).attentionSessionIDs.isEmpty, "a running session leaves the attention set")
            try expectAttention(step("Stop", turn: "t2"), count: 1, "each later ended turn pulls the island down again")
            try expect(tracker.ingest(reducer.sessions).attentionSessionIDs == [focusedID], "the same session keeps its focus identity")
            try expectQuiet(step("UserPromptSubmit", turn: "t3"), "starting a turn does not pull the island down")
            try expectAttention(step("PermissionRequest", turn: "t3", request: "req-a"), count: 1, "a pending approval pulls the island down")
            try expectAttention(step("PermissionRequest", turn: "t3", request: "req-b"), count: 1, "a second approval re-announces although the phase is unchanged")
            try expectQuiet(step("PermissionResolved", turn: "t3", request: "req-b"), "resolving an approval back to running does not pull the island down")
            try expect(tracker.ingest(reducer.sessions).attentionSessionIDs.isEmpty, "a resolved approval leaves the attention set")
            try expectQuiet(step("UserPromptSubmit", turn: "t4"), "starting a turn after an approval does not pull the island down")
            try expectAttention(step("UserQuestion", turn: "t4", extra: ["question": "继续吗？"]), count: 1, "a pending question pulls the island down")
            try expectQuiet(step("SessionEnd", turn: "t4"), "a session end without unread does not pull the island down")
            try expectQuiet(step("SessionStart", turn: "t5"), "restarting the session does not pull the island down")
            try expectAttention(step("Interrupt", turn: "t5"), count: 1, "an interrupted task pulls the island down")
            reducer.markRead(sessionKey: reducer.sessions.first!.id)
            let read = tracker.ingest(reducer.sessions)
            try expect(!read.hasNewAnnouncement && read.attentionSessionIDs.isEmpty, "marking attention read does not pull the island down")
            try expectQuiet(step("UserPromptSubmit", turn: "t6"), "resuming work does not pull the island down")
            try expectAttention(step("TurnCompleted", turn: "t6", extra: ["status": "completed"]), count: 1, "a completed task pulls the island down")
            try expectQuiet(step("UserPromptSubmit", turn: "t7"), "starting a turn after completion does not pull the island down")
            try expectAttention(step("TurnCompleted", turn: "t7", extra: ["status": "failed"]), count: 1, "a failed task pulls the island down")
            print("attention-reveal verification passed (\(checks) checks)")
        } catch {
            FileHandle.standardError.write(Data("FAIL attention-reveal: \(error)\n".utf8))
            exit(1)
        }
    }
}

/// A fatal unwrap keeps the failure loud while staying a plain executable.
private func unwrap<T>(_ value: T?) -> T {
    guard let value else { fatalError("unexpected nil in verification") }
    return value
}
