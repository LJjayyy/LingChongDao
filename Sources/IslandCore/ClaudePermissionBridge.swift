import Foundation

/// Claude omits tool_use_id on PermissionRequest. Bind a fresh request to this
/// helper's live socket, rather than guessing an identity from a command hash.
public enum ClaudePermissionBridge {
    public static func correlatedInput(_ raw: JSONValue, transportID: String) -> JSONValue {
        guard raw["hook_event_name"]?.stringValue == "PermissionRequest", var object = raw.objectValue else { return raw }
        object["lingchongdao_permission_id"] = .string(transportID)
        return .object(object)
    }

    public struct Preview: Sendable {
        public let label: String
        public let text: String
    }

    public static func preview(tool: String, input: [String: JSONValue], cwd: String, raw: JSONValue) -> Preview? {
        guard raw["reason"] == nil || raw["reason"] == .null,
              raw["specArtifact"] == nil || raw["specArtifact"] == .null,
              raw["spec_artifact"] == nil || raw["spec_artifact"] == .null else { return nil }
        let summary = input["description"]?.stringValue ?? tool
        if tool == "Bash", HookNormalizer.canPreviewApproval(toolName: tool, input: input, cwd: cwd, summary: summary) {
            return Preview(label: "命令", text: input["command"]!.stringValue!)
        }
        if tool == "WebSearch" {
            guard Set(input.keys).isSubset(of: ["query", "allowed_domains", "blocked_domains"]),
                  let query = input["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.count <= 400, query.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            var lines = ["搜索：" + query]
            for (key, label) in [("allowed_domains", "限定域名"), ("blocked_domains", "排除域名")] {
                if let value = input[key] {
                    guard case .array(let domains) = value, domains.count <= 8 else { return nil }
                    var names: [String] = []
                    for domain in domains {
                        guard let name = domain.stringValue, !name.isEmpty, name.count <= 100,
                              name.range(of: #"^[A-Za-z0-9.*-]+$"#, options: .regularExpression) != nil else { return nil }
                        names.append(name)
                    }
                    lines.append(label + "：" + (names.isEmpty ? "无" : names.joined(separator: ", ")))
                }
            }
            let text = lines.joined(separator: "\n")
            guard text.count <= 600, !HookNormalizer.containsSensitiveText(text) else { return nil }
            return Preview(label: "网页搜索", text: text)
        }
        return nil
    }
}
