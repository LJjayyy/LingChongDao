import Foundation

/// Hooks precede Codex's reviewer. Transcript metadata is only a compatibility
/// hint: if it cannot prove this exact turn uses user review, leave Codex in charge.
public enum CodexApprovalContext {
    public enum Reviewer: Equatable { case user, automatic, unverified }

    public static func reviewer(for raw: JSONValue) -> Reviewer {
        guard let sessionID = raw["session_id"]?.stringValue, !sessionID.isEmpty,
              let turnID = raw["turn_id"]?.stringValue, !turnID.isEmpty,
              let path = raw["transcript_path"]?.stringValue, path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return .unverified }
        defer { try? file.close() }
        do {
            // Never load a whole chat or infer the active chat from global config.
            let header = try file.read(upToCount: 65_536) ?? Data()
            guard let end = header.firstIndex(of: 10),
                  let metadata = try? JSONDecoder().decode(JSONValue.self, from: header[..<end]),
                  metadata["type"]?.stringValue == "session_meta",
                  metadata["payload"]?["id"]?.stringValue == sessionID else { return .unverified }
            let length = try file.seekToEnd()
            let offset = length > 1_048_576 ? length - 1_048_576 : 0
            try file.seek(toOffset: offset)
            var tail = try file.read(upToCount: 1_048_576) ?? Data()
            if offset > 0 {
                guard let newline = tail.firstIndex(of: 10) else { return .unverified }
                tail = Data(tail[tail.index(after: newline)...])
            }
            guard tail.last == 10 else { return .unverified }
            var latest: JSONValue?
            for line in tail.split(separator: 10) {
                guard let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { return .unverified }
                guard record["type"]?.stringValue == "turn_context" else { continue }
                latest = record["payload"]
            }
            guard let context = latest, context["turn_id"]?.stringValue == turnID,
                  context["approval_policy"]?.stringValue != "never" else { return .unverified }
            switch context["approvals_reviewer"]?.stringValue {
            case "user": return .user
            case "auto_review": return .automatic
            default: return .unverified
            }
        } catch { return .unverified }
    }
}
