import Foundation
import IslandCore

public struct ManagedHookDefinition: Equatable, Sendable {
    public let event: String
    public let matcher: String?
    public let command: String
    public let timeout: Int
    public let statusMessage: String?

    public init(event: String, matcher: String? = nil, command: String, timeout: Int, statusMessage: String? = nil) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeout = timeout
        self.statusMessage = statusMessage
    }
}

/// Stable, user-facing labels shown by Codex while each managed hook is running.
/// Keep this mapping public so plugin packagers can reuse the same naming.
public enum HookStatusMessages {
    public static let all: [String: String] = [
        "SessionStart": "灵宠岛 · 同步会话开始",
        "UserPromptSubmit": "灵宠岛 · 同步新任务",
        "PreToolUse": "灵宠岛 · 同步工具开始",
        "PostToolUse": "灵宠岛 · 同步工具结果",
        "PermissionRequest": "灵宠岛 · 处理权限请求",
        "Stop": "灵宠岛 · 同步本轮结束",
        "SessionEnd": "灵宠岛 · 同步会话结束",
        "SubagentStart": "灵宠岛 · 同步子任务开始",
        "SubagentStop": "灵宠岛 · 同步子任务结束",
        "Interrupt": "灵宠岛 · 同步任务中断",
        "PostToolUseFailure": "灵宠岛 · 同步工具失败",
        "Notification": "灵宠岛 · 同步通知",
        "StopFailure": "灵宠岛 · 同步本轮异常"
    ]

    /// Compact labels for chip-style summaries in the workbench UI.
    public static let shortLabels: [String: String] = [
        "SessionStart": "会话开始",
        "UserPromptSubmit": "新任务",
        "PreToolUse": "工具开始",
        "PostToolUse": "工具结果",
        "PermissionRequest": "权限请求",
        "Stop": "本轮结束",
        "SessionEnd": "会话结束",
        "SubagentStart": "子任务开始",
        "SubagentStop": "子任务结束",
        "Interrupt": "中断",
        "PostToolUseFailure": "工具失败",
        "Notification": "通知",
        "StopFailure": "本轮异常"
    ]

    public static func message(for event: String) -> String? { all[event] }
    public static func shortLabel(for event: String) -> String { shortLabels[event] ?? event }
}

public struct HookInspection: Equatable, Sendable {
    public let installedEvents: Set<String>
    public let ownedHookCount: Int
    public let expectedHookCount: Int
    public var isComplete: Bool { installedEvents.count == expectedHookCount && ownedHookCount == expectedHookCount }
}

/// ZCode stores whether configuration hooks run in the same file we edit. Disconnect
/// has to restore that switch, so the value before installation is remembered.
public enum HooksEnabledState: String, Codable, Sendable { case enabled, disabled, absent }

/// JSON transforms are pure: only exact 灵宠岛-owned commands are removed or replaced.
/// Other top-level settings, matchers, event groups, hook types and entry fields survive.
public enum HookConfigurationEditor {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func definitions(provider: ProviderID, helperURL: URL, socketPath: String) throws -> [ManagedHookDefinition] {
        let observationOnly = provider == .codebuddy || provider == .workbuddy
        let events: [String]
        switch provider {
        case .codebuddy, .workbuddy:
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        case .zcode:
            // ZCode accepts exactly these seven events. SessionEnd, subagent and
            // notification hooks are not part of its contract.
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"]
        case .qoder:
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd", "SubagentStart", "SubagentStop", "PostToolUseFailure", "Notification", "StopFailure"]
        case .codex:
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd", "SubagentStart", "SubagentStop", "Interrupt"]
        case .claude, .generic, .dsh:
            // DeepSeek Harness uses 灵宠岛's own dsh plugin instead of a hook file.
            throw ConnectionError.unsupportedProvider
        }
        return events.map { event in
            let isApproval = event == "PermissionRequest"
            let command = "\(shellQuote(helperURL.path)) --provider \(provider.rawValue) --socket \(shellQuote(socketPath)) --timeout \(isApproval ? 45 : 2) # lingchongdao-managed:v1:\(provider.rawValue)"
            return ManagedHookDefinition(event: event, matcher: nil,
                                         command: command, timeout: isApproval ? 60 : 3,
                                         statusMessage: observationOnly ? nil : HookStatusMessages.message(for: event))
        }
    }

    public static func preview(definitions: [ManagedHookDefinition], provider: ProviderID) throws -> String {
        let data = try install(provider: provider, existing: nil, definitions: definitions, recognizedCommands: [])
        return String(decoding: data, as: UTF8.self)
    }

    public static func inspect(provider: ProviderID, existing: Data?, definitions: [ManagedHookDefinition], recognizedCommands: Set<String>, path: String = "JSON") throws -> HookInspection {
        let root = try parse(existing, path: path)
        let hooks = try events(in: root, provider: provider, path: path)
        var installed = Set<String>()
        var count = 0
        let expected = Dictionary(uniqueKeysWithValues: definitions.map { ($0.event, $0) })
        let ownedCommands = recognizedCommands.union(definitions.map(\.command))
        for (event, groupsValue) in hooks {
            for group in groupsValue as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    if let command = hook["command"] as? String, ownedCommands.contains(command) {
                        count += 1
                        if let definition = expected[event], definition.command == command,
                           hook["type"] as? String == "command",
                           hook["timeout"] as? Int == definition.timeout,
                           group["matcher"] as? String == definition.matcher,
                           hook["statusMessage"] as? String == definition.statusMessage {
                            installed.insert(event)
                        }
                    }
                }
            }
        }
        return HookInspection(installedEvents: installed, ownedHookCount: count, expectedHookCount: definitions.count)
    }

    public static func install(provider: ProviderID, existing: Data?, definitions: [ManagedHookDefinition], recognizedCommands: Set<String>, path: String = "JSON") throws -> Data {
        var root = try parse(existing, path: path)
        let managed = try events(in: root, provider: provider, path: path)
        var hooks = removingOwnedHooks(managed, commands: recognizedCommands.union(definitions.map(\.command)))
        for definition in definitions {
            var entry: [String: Any] = ["type": "command", "command": definition.command, "timeout": definition.timeout]
            if let statusMessage = definition.statusMessage { entry["statusMessage"] = statusMessage }
            var group: [String: Any] = ["hooks": [entry]]
            if let matcher = definition.matcher { group["matcher"] = matcher }
            var groups = hooks[definition.event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[definition.event] = groups
        }
        applying(hooks, to: &root, provider: provider)
        return try serialize(root)
    }

    /// nil means there is no owned entry to remove; callers must not rewrite the file.
    public static func remove(provider: ProviderID, existing: Data?, recognizedCommands: Set<String>,
                              restoreHooksEnabled: HooksEnabledState? = nil, path: String = "JSON") throws -> Data? {
        guard let existing else { return nil }
        var root = try parse(existing, path: path)
        let hooks = try events(in: root, provider: provider, path: path)
        guard containsOwnedHooks(hooks, commands: recognizedCommands) else { return nil }
        applying(removingOwnedHooks(hooks, commands: recognizedCommands), to: &root, provider: provider,
                 restoreHooksEnabled: restoreHooksEnabled)
        return try serialize(root)
    }

    /// ZCode skips configuration hooks unless `hooks.enabled` is true. Owned commands
    /// alone are therefore not proof that the connection is running.
    public static func configurationHooksDisabled(existing: Data?, provider: ProviderID) -> Bool {
        hooksEnabledState(existing: existing, provider: provider) == .disabled
    }

    /// Only ZCode reports a state; other providers keep event groups at `hooks` directly.
    public static func hooksEnabledState(existing: Data?, provider: ProviderID) -> HooksEnabledState? {
        guard provider == .zcode else { return nil }
        guard let existing, let root = try? parse(existing, path: "JSON") else { return .absent }
        guard let raw = root["hooks"] else { return .absent }
        guard let hooks = raw as? [String: Any] else { return nil }
        guard let enabled = hooks["enabled"] as? Bool else { return .absent }
        return enabled ? .enabled : .disabled
    }

    private static func parse(_ data: Data?, path: String) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.invalidConfiguration(path) }
            return root
        } catch let error as ConnectionError { throw error }
        catch { throw ConnectionError.invalidConfiguration(path) }
    }

    /// Providers differ only in where the event groups live. ZCode keeps them under
    /// `hooks.events` and runs configuration hooks only when `hooks.enabled` is true;
    /// the other providers use `hooks.<Event>`.
    private static func events(in root: [String: Any], provider: ProviderID, path: String) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let container = raw as? [String: Any] else { throw ConnectionError.invalidConfiguration(path) }
        let events: [String: Any]
        if provider == .zcode {
            if let enabled = container["enabled"], !(enabled is Bool) { throw ConnectionError.invalidConfiguration(path) }
            guard let rawEvents = container["events"] else { return [:] }
            guard let parsed = rawEvents as? [String: Any] else { throw ConnectionError.invalidConfiguration(path) }
            events = parsed
        } else {
            events = container
        }
        for value in events.values {
            guard let groups = value as? [[String: Any]] else { throw ConnectionError.invalidConfiguration(path) }
            for group in groups {
                guard group["hooks"] is [[String: Any]] else { throw ConnectionError.invalidConfiguration(path) }
            }
        }
        return events
    }

    private static func applying(_ events: [String: Any], to root: inout [String: Any], provider: ProviderID,
                                 restoreHooksEnabled: HooksEnabledState? = nil) {
        guard provider == .zcode else {
            if events.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = events }
            return
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if !events.isEmpty {
            hooks["enabled"] = true
            hooks["events"] = events
            root["hooks"] = hooks
            return
        }
        hooks.removeValue(forKey: "events")
        switch restoreHooksEnabled {
        case .absent: hooks.removeValue(forKey: "enabled")
        case .enabled: hooks["enabled"] = true
        case .disabled: hooks["enabled"] = false
        case nil: break
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    }

    private static func containsOwnedHooks(_ hooks: [String: Any], commands: Set<String>) -> Bool {
        hooks.values.contains { groupsValue in
            (groupsValue as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                    (hook["command"] as? String).map(commands.contains) ?? false
                }
            }
        }
    }

    private static func removingOwnedHooks(_ hooks: [String: Any], commands: Set<String>) -> [String: Any] {
        var retained = hooks
        for (event, value) in hooks {
            var retainedGroups: [[String: Any]] = []
            for var group in value as? [[String: Any]] ?? [] {
                let entries = group["hooks"] as? [[String: Any]] ?? []
                let filtered = entries.filter { hook in
                    guard let command = hook["command"] as? String else { return true }
                    return !commands.contains(command)
                }
                // Keep preexisting empty groups; delete a group only when our removal emptied it.
                if filtered.isEmpty && !entries.isEmpty { continue }
                group["hooks"] = filtered
                retainedGroups.append(group)
            }
            if retainedGroups.isEmpty && !(value as? [[String: Any]] ?? []).isEmpty { retained.removeValue(forKey: event) }
            else { retained[event] = retainedGroups }
        }
        return retained
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
