import Foundation

/// PermissionRequest has no tool_use_id in Codex's native protocol. The helper
/// binds each invocation to its own live socket; identical commands stay distinct.
public enum CodexPermissionBridge {
    public static let identityKey = "lingchongdao_codex_permission_id"
    public static func correlatedInput(_ raw: JSONValue, transportID: String) -> JSONValue {
        guard raw["hook_event_name"]?.stringValue == "PermissionRequest", var object = raw.objectValue else { return raw }
        object[identityKey] = .string(transportID)
        return .object(object)
    }
}
