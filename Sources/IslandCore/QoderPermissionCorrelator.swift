import Foundation

/// PermissionRequest omits tool_use_id in Qoder App 0.4.11. Pair it with a
/// unique, preceding PreToolUse in memory so a native reply's PostToolUse can
/// retire precisely that hook. Ambiguous identical calls remain unpaired.
public struct QoderPermissionCorrelator: Sendable {
    private struct Call: Sendable {
        let id: String
        let signature: Data
        let date: Date
        var permissionID: String?
    }
    private var calls: [String: [Call]] = [:]
    public init() {}

    /// Call only for accepted Qoder events. The return value is the permission
    /// transport ID resolved by a matching source tool result.
    public mutating func observe(_ raw: JSONValue, sessionKey: String, at date: Date = Date()) -> String? {
        calls = calls.mapValues { $0.filter { date.timeIntervalSince($0.date) < 120 } }.filter { !$0.value.isEmpty }
        let name = raw["hook_event_name"]?.stringValue ?? ""
        if ["UserPromptSubmit", "SessionEnd", "Stop", "StopFailure"].contains(name),
           raw["agent_id"] == nil, raw["subagent_id"] == nil, raw["is_subagent"]?.boolValue != true {
            calls.removeValue(forKey: sessionKey)
            return nil
        }
        var queue = calls[sessionKey] ?? []
        let toolID = raw["tool_use_id"]?.stringValue
        if name == "PreToolUse", let toolID, !toolID.isEmpty, let signature = signature(raw) {
            if !queue.contains(where: { $0.id == toolID }) {
                queue.append(Call(id: toolID, signature: signature, date: date))
            }
            // Bound memory even if a source never emits matching results.
            calls[sessionKey] = Array(queue.suffix(256))
        } else if name == "PermissionRequest", let permissionID = raw[QoderPermissionBridge.identityKey]?.stringValue,
                  let signature = signature(raw) {
            let matches = queue.indices.filter { queue[$0].signature == signature }
            if matches.count == 1, queue[matches[0]].permissionID == nil {
                queue[matches[0]].permissionID = permissionID
                calls[sessionKey] = queue
            }
        } else if ["PostToolUse", "PostToolUseFailure"].contains(name), let toolID {
            guard let index = queue.firstIndex(where: { $0.id == toolID }) else { return nil }
            let call = queue.remove(at: index)
            calls[sessionKey] = queue.isEmpty ? nil : queue
            return call.permissionID
        }
        return nil
    }

    private func signature(_ raw: JSONValue) -> Data? {
        guard let tool = raw["tool_name"], let input = raw["tool_input"] else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Include the agent scope when supplied. Never guess among concurrent
        // same-command calls, nor persist any command or tool output to disk.
        return try? encoder.encode(JSONValue.object(["tool": tool, "input": input,
            "cwd": raw["cwd"] ?? .null, "agent": raw["agent_id"] ?? raw["subagent_id"] ?? .null]))
    }
}
