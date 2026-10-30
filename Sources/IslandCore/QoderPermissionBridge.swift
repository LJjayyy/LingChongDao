import Foundation

/// Qoder omits tool_use_id on PermissionRequest. Correlate each hook with its
/// own live connection rather than guessing from a command or a previous tool.
public enum QoderPermissionBridge {
    public static let identityKey = "lingchongdao_qoder_permission_id"
    public static func correlatedInput(_ raw: JSONValue, transportID: String) -> JSONValue {
        guard raw["hook_event_name"]?.stringValue == "PermissionRequest", var object = raw.objectValue else { return raw }
        object[identityKey] = .string(transportID)
        return .object(object)
    }
}
