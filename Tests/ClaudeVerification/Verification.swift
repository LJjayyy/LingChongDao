import Foundation
import IslandCore
import IslandConnections

struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
func event(_ name: String, extra: [String: Any] = [:], origin: SourceApplicationID? = .claudeDesktop) throws -> NormalizedHookEvent {
    var raw: [String: Any] = ["session_id": "claude-test", "hook_event_name": name, "cwd": "/Projects/demo"]
    raw.merge(extra, uniquingKeysWith: { _, new in new })
    return try HookNormalizer.normalize(rawJSON: JSONSerialization.data(withJSONObject: raw), provider: .claude, sourceApplication: origin)
}

@main struct ClaudeVerification {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw Failure(message: "usage: verify plugin-directory helper-binary claude-cli") }
        let package = URL(fileURLWithPath: args[1])
        let helper = URL(fileURLWithPath: args[2])
        let cli = URL(fileURLWithPath: args[3])
        var reducer = SessionReducer()
        let start = try event("UserPromptSubmit", extra: ["prompt": "验证 Claude 状态同步"])
        reducer.apply(start)
        try require(reducer.sessions.first?.title == "验证 Claude 状态同步", "prompt title")
        reducer.apply(try event("Stop"))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .idle, "Stop must not mean success")
        reducer.apply(try event("Notification", extra: ["notification_type": "permission_prompt", "message": "permission"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .idle, "notification must not resurrect finished work")
        let permission = try event("PermissionRequest", extra: ["tool_name": "Bash", "tool_use_id": "fake", "tool_input": ["command": "echo safe"]])
        try require(permission.kind == .permissionObserved && permission.approval == nil, "unbound raw events cannot expose actionable approvals")
        try require(HookOutput.response(for: BridgeReply(disposition: .acknowledged), event: permission) == .object([:]), "no permission output")
        reducer.apply(try event("UserPromptSubmit", extra: ["prompt": "question"]))
        reducer.apply(try event("PreToolUse", extra: ["tool_name": "AskUserQuestion", "tool_use_id": "q1"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .waitingQuestion, "observe question")
        reducer.apply(try event("PostToolUse", extra: ["tool_name": "AskUserQuestion", "tool_use_id": "q1"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .running, "resolve source question")
        reducer.apply(try event("SubagentStop", extra: ["agent_id": "child"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .running, "subagent must not stop main session")
        reducer.apply(try event("StopFailure"))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .failed, "record Claude response error")
        reducer.apply(try event("SessionEnd"))
        try require(reducer.sessionsByID[start.sessionKey]?.unread == false, "session end clears attention")
        try require(try event("Stop", origin: .claudeVSCode).sessionKey != start.sessionKey, "separate host identities")
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        let web: [String: Any] = ["query": "Claude Code plugin hooks", "allowed_domains": ["code.claude.com"]]
        let first = try event("PermissionRequest", extra: ["lingchongdao_permission_id": firstID, "tool_name": "WebSearch", "tool_input": web, "agent_id": "child-a"])
        let second = try event("PermissionRequest", extra: ["lingchongdao_permission_id": secondID, "tool_name": "WebSearch", "tool_input": web, "agent_id": "child-b"])
        try require(first.approval?.canApprove == true && first.approval?.canDeny == true, "preview and answer WebSearch")
        try require(first.approval?.command?.contains("限定域名") == true, "show all WebSearch restrictions")
        let bash = try event("PermissionRequest", extra: ["lingchongdao_permission_id": UUID().uuidString, "tool_name": "Bash", "tool_input": ["command": "printf LCD_BASH_OK"]])
        try require(bash.approval?.canApprove == true && bash.approval?.previewLabel == "命令", "support fully previewed Bash")
        reducer.apply(first); reducer.apply(second)
        try require(!reducer.dismissSession(sessionKey: start.sessionKey), "live approvals cannot be dismissed")
        try require(reducer.pendingApprovalIDs(sessionKey: start.sessionKey) == [firstID, secondID], "parallel subagent approvals do not overwrite")
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .waitingApproval, "waiting replaces running")
        reducer.apply(try event("PostToolUse", extra: ["tool_name": "Read", "tool_use_id": "other"]))
        reducer.apply(try event("SubagentStop", extra: ["agent_id": "unrelated"]))
        reducer.apply(try event("Stop"))
        try require(reducer.pendingApprovalIDs(sessionKey: start.sessionKey).count == 2, "unrelated activity and main stop cannot erase pending subagent hooks")
        try require(reducer.resolveApproval(sessionKey: start.sessionKey, requestID: firstID, decision: .allow), "approve first request")
        try require(reducer.sessionsByID[start.sessionKey]?.approval?.id == secondID, "promote second request")
        try require(!reducer.resolveApproval(sessionKey: start.sessionKey, requestID: firstID, decision: .deny), "reject stale decisions")
        reducer.expireApproval(sessionKey: start.sessionKey, requestID: firstID)
        try require(reducer.sessionsByID[start.sessionKey]?.approval?.id == secondID, "old timeout cannot cancel next request")
        try require(reducer.resolveApproval(sessionKey: start.sessionKey, requestID: secondID, decision: .fallback), "handoff to source")
        try require(reducer.sessionsByID[start.sessionKey]?.hasPendingApproval == true && reducer.sessionsByID[start.sessionKey]?.approval?.canDeny == false, "handoff stays waiting with no stale controls")
        reducer.apply(try event("PostToolUse", extra: ["tool_name": "WebSearch", "tool_use_id": "native-result"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .running, "source activity clears read-only notice")
        reducer.apply(try event("Notification", extra: ["notification_type": "permission_prompt"]))
        try require(reducer.sessionsByID[start.sessionKey]?.phase == .waitingApproval, "native permission notification shows waiting")
        try require(reducer.sessionsByID[start.sessionKey]?.approval?.canApprove == false, "notifications do not authorize decisions")
        try require(reducer.dismissSession(sessionKey: start.sessionKey), "read-only source notices may be closed")
        reducer.apply(try event("Stop"))
        let output = HookOutput.response(for: BridgeReply(disposition: .allow), event: first)
        try require(output["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue == "allow", "allow response")
        try require(output["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == nil, "never change persistent rules")
        let unsupported = try event("PermissionRequest", extra: ["lingchongdao_permission_id": UUID().uuidString, "tool_name": "WebSearch", "tool_input": ["query": "test", "unknown": "hidden"]])
        try require(unsupported.approval?.canApprove == false && unsupported.approval?.canDeny == true, "unpreviewed inputs cannot be allowed")
        let bundleIDs = ["com.anthropic.claudefordesktop": SourceApplicationID.claudeDesktop,
                         "com.microsoft.VSCode": .claudeVSCode, "com.apple.Terminal": .claudeTerminal,
                         "com.jetbrains.pycharm": .claudePyCharm]
        for (bundle, expected) in bundleIDs {
            let records: [Int32: SourceProcessRecord] = [10: .init(pid: 10, parentPID: 11, executablePath: "/bin/sh"),
                11: .init(pid: 11, parentPID: 12, executablePath: "/Users/test/claude.app/Contents/MacOS/claude"),
                12: .init(pid: 12, parentPID: 1, executablePath: "/Applications/Host.app/Contents/MacOS/host")]
            let origin = SourceApplicationDetector.detect(provider: .claude, currentPID: 10, processLookup: { records[$0] },
                bundleIdentifierLookup: { $0.path == "/Applications/Host.app" ? bundle : "com.anthropic.claude_code" })
            try require(origin == expected, "ancestry identifies \(bundle), not embedded CLI bundle")
        }
        let pluginRoot = package.appendingPathComponent("plugins/lingchongdao")
        let pluginManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))) as! [String: Any]
        try require(pluginManifest["icon"] as? String == "./assets/icon.png", "declare the official plugin icon field")
        let iconData = try Data(contentsOf: pluginRoot.appendingPathComponent("assets/icon.png"))
        try require(iconData.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "ship the PNG referenced by the plugin manifest")
        let hooksData = try Data(contentsOf: package.appendingPathComponent("plugins/lingchongdao/hooks/hooks.json"))
        let hooks = (try JSONSerialization.jsonObject(with: hooksData) as! [String: Any])["hooks"] as! [String: Any]
        try require(hooks.count == 12 && hooks["PermissionRequest"] != nil, "package includes the permission hook")
        try require(HookConnectionService.capabilities(.claude).contains(.limitedApproval), "declare limited approval capability")

        // Real vendor CLI, isolated home/config, no model invocation and no live settings.
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: "/private/tmp/lcd-claude-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let bin = temporary.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: cli)
        let source = temporary.appendingPathComponent("package")
        try fm.copyItem(at: package, to: source)
        let environment = ConnectionEnvironment(homeDirectoryURL: temporary,
            helperSourceURL: helper, executableSearchDirectories: [bin], detectCLIVersions: false,
            claudePluginSourceURL: source)
        try fm.createDirectory(at: environment.claudeHomeURL, withIntermediateDirectories: true)
        let settings = environment.claudeHomeURL.appendingPathComponent("settings.json")
        let original: [String: Any] = ["permissions": ["deny": ["Bash(rm *)"]], "unrelated": "keep",
                                      "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo foreign"]]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        let service = ClaudeConnectionService(environment: environment)
        let before = await service.check()
        try require(before.status == .notInstalled, "initial detection")
        try await service.installDirectly()
        let installed = await service.check()
        try require(installed.status == .installed && installed.installedHookCount == 12, "real CLI install verified")
        var current = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        try require(current["unrelated"] as? String == "keep" && current["hooks"] != nil && current["permissions"] != nil, "preserve user settings")
        let manifest = source.appendingPathComponent("plugins/lingchongdao/.claude-plugin/plugin.json")
        var version = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        version["version"] = "9.0.0"
        try JSONSerialization.data(withJSONObject: version).write(to: manifest)
        let marketplace = source.appendingPathComponent(".claude-plugin/marketplace.json")
        var catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: marketplace)) as! [String: Any]
        var entries = catalog["plugins"] as! [[String: Any]]
        entries[0]["version"] = "9.0.0"; catalog["plugins"] = entries
        try JSONSerialization.data(withJSONObject: catalog).write(to: marketplace)
        let update = await service.check()
        try require(update.pluginUpdateAvailable, "detect plugin update")
        try await service.installDirectly()
        let updated = await service.check()
        try require(updated.status == .installed && !updated.pluginUpdateAvailable, "real CLI update verified")
        let forwarder = source.appendingPathComponent("plugins/lingchongdao/scripts/forward-hook.sh")
        var script = try String(contentsOf: forwarder, encoding: .utf8)
        script += "\n# same-version update verification\n"
        try script.write(to: forwarder, atomically: true, encoding: .utf8)
        let changed = await service.check()
        try require(changed.pluginUpdateAvailable, "detect same-version content changes")
        try await service.installDirectly()
        let refreshed = await service.check()
        try require(refreshed.status == .installed && !refreshed.pluginUpdateAvailable, "same-version repair verified")
        let icon = source.appendingPathComponent("plugins/lingchongdao/assets/icon.png")
        var changedIcon = try Data(contentsOf: icon)
        changedIcon.append(10)
        try changedIcon.write(to: icon)
        let iconUpdate = await service.check()
        try require(iconUpdate.pluginUpdateAvailable, "icon-only updates must invalidate the package fingerprint")
        try await service.installDirectly()
        let iconRefreshed = await service.check()
        try require(iconRefreshed.status == .installed && !iconRefreshed.pluginUpdateAvailable, "refresh the cached icon asset")
        // Disabled plugin appears repairable, without changing global hook policy.
        current = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        current["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: current).write(to: settings)
        let disabled = await service.check()
        try require(disabled.status == .needsRepair, "respect globally disabled hooks")
        try await service.uninstall()
        current = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        try require(current["unrelated"] as? String == "keep" && current["hooks"] != nil && current["disableAllHooks"] as? Bool == true, "uninstall preserves unrelated config")
        let removed = await service.check()
        try require(removed.installedHookCount == 0, "uninstall verified")
        print("Claude verification passed: lifecycle, origin, correlated approval, real CLI install/update/uninstall, settings preservation")
    }
}
