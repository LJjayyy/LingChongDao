import Foundation
import IslandCore

/// Synthetic reviewer metadata for isolated AppModel checks; never reads real chats.
struct CodexReviewFixture {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/lcd-review-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func metadata(sessionID: String, turnID: String, reviewer: String = "user") throws -> [String: JSONValue] {
        let records: [JSONValue] = [
            .object(["type": .string("session_meta"), "payload": .object(["id": .string(sessionID)])]),
            .object(["type": .string("turn_context"), "payload": .object([
                "turn_id": .string(turnID), "approvals_reviewer": .string(reviewer),
                "approval_policy": .string("on-request")
            ])])
        ]
        let transcript = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
        var data = Data()
        for record in records { data.append(try JSONEncoder().encode(record)); data.append(10) }
        try data.write(to: transcript, options: .atomic)
        return ["turn_id": .string(turnID), "transcript_path": .string(transcript.path)]
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
