import Foundation

public enum HookOutput {
    /// Never synthesize permission output unless both the provider contract and current request permit it.
    public static func response(for reply: BridgeReply, event: NormalizedHookEvent) -> JSONValue {
        guard event.kind == .approvalRequested, [ProviderID.codex, .zcode, .claude].contains(event.source), let request = event.approval, !request.isExpired() else { return .object([:]) }
        let behavior: String
        switch reply.disposition {
        case .allow: guard request.canApprove else { return .object([:]) }; behavior = "allow"
        case .deny: guard request.canDeny else { return .object([:]) }; behavior = "deny"
        default: return .object([:])
        }
        var decision: [String: JSONValue] = ["behavior": .string(behavior)]
        if behavior == "deny" { decision["message"] = .string("用户在灵宠岛中拒绝了此操作。") }
        return .object(["hookSpecificOutput": .object(["hookEventName": .string("PermissionRequest"), "decision": .object(decision)])])
    }
}
