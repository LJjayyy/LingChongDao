import Foundation
import XCTest
import IslandCore
@testable import IslandConnections

final class ConnectionTests: XCTestCase {
    private let existing = Data(#"{"permissions":{"allow":["Read"]},"hooks":{"PreToolUse":[{"matcher":"Read","custom":"keep","hooks":[{"type":"command","command":"echo keep","timeout":9}]}]}}"#.utf8)
    private func definitions(_ provider: ProviderID = .qoder) throws -> [ManagedHookDefinition] {
        try HookConfigurationEditor.definitions(provider: provider, helperURL: URL(fileURLWithPath: "/Users/Test User/AI's Tools/helper"), socketPath: "/Users/Test User/Library/Application Support/LingChongDao/run/bridge.sock")
    }
    func testQoderCNUsesItsOwnDefaultConfigurationDirectory() {
        let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderHome", isDirectory: true)
        let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false)
        XCTAssertEqual(environment.configurationURL(for: .qoder), home.appendingPathComponent(".qoder-cn/settings.json"))
    }
    func testQoderCNEnvironmentPathPrecedenceAndRelativeResolution() throws {
        let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderHome", isDirectory: true)
        let cwd = URL(fileURLWithPath: "/private/tmp/LingChongDao-QoderCwd", isDirectory: true)
        func resolve(_ values: [String: String]) throws -> URL {
            try ConnectionEnvironment.resolveQoderHomeURL(homeDirectoryURL: home, environment: values, currentDirectoryURL: cwd)
        }
        XCTAssertEqual(try resolve([:]), home.appendingPathComponent(".qoder-cn", isDirectory: true))
        XCTAssertEqual(try resolve(["QODERCN_CLI_HOME": "/private/tmp/cli", "QODERCN_CONFIG_DIR_NAME": "custom-cn"]), URL(fileURLWithPath: "/private/tmp/cli/custom-cn", isDirectory: true))
        XCTAssertEqual(try resolve(["QODERCN_CONFIG_DIR": "/private/tmp/config", "QODERCN_CLI_HOME": "/private/tmp/ignored", "QODERCN_CONFIG_DIR_NAME": "../invalid"]), URL(fileURLWithPath: "/private/tmp/config", isDirectory: true))
        XCTAssertEqual(try resolve(["QODERCN_CONFIG_DIR": "configs/../cn"]), cwd.appendingPathComponent("cn", isDirectory: true))
        XCTAssertEqual(try resolve(["QODERCN_CLI_HOME": "relative-home"]), cwd.appendingPathComponent("relative-home/.qoder-cn", isDirectory: true))
        XCTAssertEqual(try resolve(["QODERCN_CONFIG_DIR": "", "QODERCN_CLI_HOME": "", "QODERCN_CONFIG_DIR_NAME": ""]), home.appendingPathComponent(".qoder-cn", isDirectory: true))
        for name in ["../other", "/absolute", ".", "..", "trailing.", " leading", "CON", ".GiT", "node_modules", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try resolve(["QODERCN_CONFIG_DIR_NAME": name]))
        }
        let override = home.appendingPathComponent("specific-cn", isDirectory: true)
        XCTAssertEqual(ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false, qoderHomeURL: override).configurationURL(for: .qoder), override.appendingPathComponent("settings.json"))
    }
    func testInstallAndRemovePreserveUnrelatedConfigurationAndAreIdempotent() throws {
        let defs = try definitions()
        let installed = try HookConfigurationEditor.install(provider: .qoder, existing: existing, definitions: defs, recognizedCommands: [])
        let again = try HookConfigurationEditor.install(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: Set(defs.map(\.command)))
        XCTAssertEqual(installed, again)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        XCTAssertEqual((object["permissions"] as? [String: [String]])?["allow"], ["Read"])
        let removed = try XCTUnwrap(HookConfigurationEditor.remove(provider: .qoder, existing: installed, recognizedCommands: Set(defs.map(\.command))))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, try JSONSerialization.jsonObject(with: existing) as? NSDictionary)
    }
    func testMalformedConfigurationIsNotSilentlyDiscarded() throws {
        for raw in ["broken", "[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":{"hooks":[]}}}"#] {
            XCTAssertThrowsError(try HookConfigurationEditor.install(provider: .qoder, existing: Data(raw.utf8), definitions: definitions(), recognizedCommands: []))
        }
    }
    func testShellEscapingAndApprovalTimeBound() throws {
        let defs = try definitions(.codex)
        let approval = try XCTUnwrap(defs.first { $0.event == "PermissionRequest" })
        XCTAssertTrue(approval.command.contains("'\\''"))
        XCTAssertTrue(approval.command.contains("--timeout 45"))
        XCTAssertEqual(approval.timeout, 60)
        XCTAssertEqual(approval.statusMessage, "灵宠岛 · 处理权限请求")
        XCTAssertFalse(defs.contains { $0.event == "Notification" || $0.event == "PostToolUseFailure" })
    }
    func testHookLabelsAreDefinedForBothProvidersAndUniquePerProvider() throws {
        for provider in [ProviderID.qoder, .codex] {
            let defs = try definitions(provider)
            let labels = try defs.map { definition in
                try XCTUnwrap(definition.statusMessage, "Missing label for \(provider.rawValue)/\(definition.event)")
            }
            XCTAssertEqual(Set(labels).count, labels.count)
            XCTAssertEqual(defs.count, Set(defs.map(\.event)).count)
        }
        XCTAssertEqual(HookStatusMessages.all.count, 13)
    }
    func testInspectCannotCountUnrelatedCommandsAsInstalled() throws {
        let defs = try definitions()
        let status = try HookConfigurationEditor.inspect(provider: .qoder, existing: existing, definitions: defs, recognizedCommands: [])
        XCTAssertFalse(status.isComplete); XCTAssertEqual(status.ownedHookCount, 0)
    }
    func testInspectRejectsChangedMatcherTypeAndTimeout() throws {
        let defs = try definitions()
        let installed = try HookConfigurationEditor.install(provider: .qoder, existing: nil, definitions: defs, recognizedCommands: [])
        XCTAssertTrue(try HookConfigurationEditor.inspect(provider: .qoder, existing: installed, definitions: defs, recognizedCommands: []).isComplete)
        for field in ["matcher", "type", "timeout"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
            var hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
            var groups = try XCTUnwrap(hooks["PermissionRequest"])
            if field == "matcher" { groups[0]["matcher"] = "^NeverMatches$" }
            else {
                var entries = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
                if field == "type" { entries[0][field] = "prompt" }
                else { entries[0][field] = 1 }
                groups[0]["hooks"] = entries
            }
            hooks["PermissionRequest"] = groups; root["hooks"] = hooks
            let status = try HookConfigurationEditor.inspect(provider: .qoder, existing: JSONSerialization.data(withJSONObject: root), definitions: defs, recognizedCommands: [])
            XCTAssertFalse(status.isComplete, "Modified \(field) must require repair")
            XCTAssertEqual(status.ownedHookCount, defs.count)
        }
    }
    func testMissingLegacyStatusMessageRequiresRepairAndInstallIsIdempotent() throws {
        let defs = try definitions()
        let legacy = defs.map {
            ManagedHookDefinition(event: $0.event, matcher: $0.matcher, command: $0.command, timeout: $0.timeout)
        }
        let old = try HookConfigurationEditor.install(provider: .qoder, existing: existing, definitions: legacy, recognizedCommands: [])
        let beforeRepair = try HookConfigurationEditor.inspect(provider: .qoder, existing: old, definitions: defs, recognizedCommands: [])
        XCTAssertFalse(beforeRepair.isComplete)
        XCTAssertEqual(beforeRepair.ownedHookCount, defs.count)

        let repaired = try HookConfigurationEditor.install(provider: .qoder, existing: old, definitions: defs, recognizedCommands: Set(defs.map(\.command)))
        XCTAssertTrue(try HookConfigurationEditor.inspect(provider: .qoder, existing: repaired, definitions: defs, recognizedCommands: []).isComplete)
        XCTAssertEqual(repaired, try HookConfigurationEditor.install(provider: .qoder, existing: repaired, definitions: defs, recognizedCommands: Set(defs.map(\.command))))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: repaired) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: [[String: Any]]])
        let unrelated = try XCTUnwrap(hooks["PreToolUse"]?.first { group in
            (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == "echo keep" } == true
        })
        XCTAssertEqual(unrelated["matcher"] as? String, "Read")
        XCTAssertEqual(unrelated["custom"] as? String, "keep")
    }
    func testAtomicWritePreservesBackupAndRefusesChangedInputAndSymlink() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/LingChongDaoConnectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try existing.write(to: file)
        let replacement = Data("{}\n".utf8)
        let backup = try XCTUnwrap(ConnectionFileStore.writeAtomically(replacement, to: file, expected: existing))
        XCTAssertEqual(try Data(contentsOf: backup), existing)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        XCTAssertThrowsError(try ConnectionFileStore.writeAtomically(existing, to: file, expected: existing))
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ConnectionFileStore.readOptional(link))
    }
    func testInstallationServiceUsesSandboxHomeWithoutTrustingCodex() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/LingChongDaoInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("source-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ConnectionEnvironment(homeDirectoryURL: root, helperSourceURL: helper, detectCLIVersions: false)
        let service = HookConnectionService(environment: environment)
        let plan = try await service.prepare(provider: .codex)
        XCTAssertTrue(plan.reviewInstructions.contains("不会自动信任"))
        try await service.install(provider: .codex)
        let connection = await service.check(provider: .codex)
        XCTAssertEqual(connection.status, .needsReview)
        XCTAssertTrue(connection.hasInstalledHooks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/config.toml").path))
        try await service.remove(provider: .codex)
        let removed = await service.check(provider: .codex)
        XCTAssertFalse(removed.hasInstalledHooks)
    }
    func testBuddyDefinitionsUseMinimalObservationOnlySchema() throws {
        for provider in [ProviderID.codebuddy, .workbuddy] {
            let defs = try definitions(provider)
            XCTAssertEqual(defs.map(\.event), ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"])
            XCTAssertTrue(defs.allSatisfy { $0.timeout == 3 && $0.command.contains("--timeout 2") && $0.statusMessage == nil })
            XCTAssertTrue(defs.allSatisfy { $0.command.contains("--provider \(provider.rawValue)") })
            XCTAssertFalse(HookConnectionService.capabilities(provider).contains(.limitedApproval))
        }
    }
    func testBuddyConfigurationDirectoriesAndOverridesStaySeparate() {
        let home = URL(fileURLWithPath: "/private/tmp/BuddyHome", isDirectory: true)
        let defaults = ConnectionEnvironment(homeDirectoryURL: home)
        XCTAssertEqual(defaults.configurationURL(for: .codebuddy), home.appendingPathComponent(".codebuddy/settings.json"))
        XCTAssertEqual(defaults.configurationURL(for: .workbuddy), home.appendingPathComponent(".workbuddy/settings.json"))
        XCTAssertNotEqual(defaults.configurationURL(for: .generic), defaults.configurationURL(for: .codex))
        let code = home.appendingPathComponent("custom-code"), work = home.appendingPathComponent("custom-work")
        let overridden = ConnectionEnvironment(homeDirectoryURL: home, codebuddyHomeURL: code, workbuddyHomeURL: work)
        XCTAssertEqual(overridden.configurationURL(for: .codebuddy), code.appendingPathComponent("settings.json"))
        XCTAssertEqual(overridden.configurationURL(for: .workbuddy), work.appendingPathComponent("settings.json"))
    }
    func testBuddyConfigDirectoryEnvironmentPrecedence() throws {
        let home = URL(fileURLWithPath: "/Users/Test", isDirectory: true)
        let cwd = URL(fileURLWithPath: "/tmp/launcher", isDirectory: true)
        func resolve(_ provider: ProviderID, _ env: [String: String]) throws -> URL {
            try ConnectionEnvironment.resolveBuddyHomeURL(provider: provider, homeDirectoryURL: home, environment: env, currentDirectoryURL: cwd)
        }
        XCTAssertEqual(try resolve(.workbuddy, [:]), home.appendingPathComponent(".workbuddy", isDirectory: true))
        XCTAssertEqual(try resolve(.workbuddy, ["CODEBUDDY_CONFIG_DIR": "/tmp/shared"]), URL(fileURLWithPath: "/tmp/shared", isDirectory: true))
        XCTAssertEqual(try resolve(.workbuddy, ["CODEBUDDY_CONFIG_DIR": "/tmp/shared", "WORKBUDDY_CONFIG_DIR": "/tmp/work"]), URL(fileURLWithPath: "/tmp/work", isDirectory: true))
        XCTAssertEqual(try resolve(.workbuddy, ["CODEBUDDY_CONFIG_DIR": "relative", "WORKBUDDY_CONFIG_DIR": ""]), cwd.appendingPathComponent("relative", isDirectory: true))
        XCTAssertEqual(try resolve(.codebuddy, ["WORKBUDDY_CONFIG_DIR": "/tmp/work"]), home.appendingPathComponent(".codebuddy", isDirectory: true))
    }
    func testBuddyInstallRepairRemoveAreIsolatedAndPreserveUserSettings() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/BuddyInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("source-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ConnectionEnvironment(homeDirectoryURL: root, helperSourceURL: helper, detectCLIVersions: false)
        for provider in [ProviderID.codebuddy, .workbuddy] {
            let file = environment.configurationURL(for: provider)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try existing.write(to: file)
        }
        let service = HookConnectionService(environment: environment)
        for provider in [ProviderID.codebuddy, .workbuddy] {
            let plan = try await service.prepare(provider: provider)
            XCTAssertEqual(plan.provider, provider)
            XCTAssertTrue(plan.reviewInstructions.contains("新会话"))
            XCTAssertEqual(plan.hookLabels.count, 6)
            try await service.install(provider: provider)
            let checked = await service.check(provider: provider)
            XCTAssertEqual(checked.status, .installed)
            XCTAssertEqual(checked.installedHookCount, 6)
            XCTAssertFalse(checked.requiresTrustReview)
        }
        let workFile = environment.configurationURL(for: .workbuddy)
        let workData = try Data(contentsOf: workFile)
        _ = try await service.prepare(provider: .codebuddy)
        try await service.install(provider: .codebuddy)
        XCTAssertEqual(try Data(contentsOf: workFile), workData)
        try await service.remove(provider: .codebuddy)
        XCTAssertEqual(try Data(contentsOf: workFile), workData)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: environment.configurationURL(for: .codebuddy))) as? NSDictionary
        XCTAssertEqual(restored, try JSONSerialization.jsonObject(with: existing) as? NSDictionary)
        let retained = await service.check(provider: .workbuddy)
        XCTAssertEqual(retained.installedHookCount, 6)
        try await service.remove(provider: .workbuddy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".workbuddy-ai/settings.json").path))
    }
    func testBuddyDetectorRequiresExactDesktopBundleAndNeverUsesCLI() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/BuddyDetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, applicationDirectories: [root], executableSearchDirectories: [root], detectCLIVersions: false)
        for (provider, name, bundle) in [(ProviderID.codebuddy, "CodeBuddy CN.app", "com.tencent.codebuddycn"), (.workbuddy, "WorkBuddy.app", "com.tencent.workbuddy.mac")] {
            let contents = root.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = contents.appendingPathComponent("Info.plist")
            func write(_ id: String) throws { try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0).write(to: plist) }
            try write("com.example.wrong")
            let wrong = await ProviderDetector.detect(provider: provider, environment: environment)
            XCTAssertFalse(wrong.isDetected)
            XCTAssertNil(wrong.cliURL)
            try write(bundle)
            let correct = await ProviderDetector.detect(provider: provider, environment: environment)
            XCTAssertEqual(correct.appURL, root.appendingPathComponent(name, isDirectory: true))
            XCTAssertEqual(correct.appVersion, "1.2.3")
            XCTAssertNil(correct.cliURL)
        }
    }

    func testBuddyOwnedCommandsDoNotRemoveOtherProviderInSameConfiguration() throws {
        let code = try definitions(.codebuddy), work = try definitions(.workbuddy)
        let codeInstalled = try HookConfigurationEditor.install(provider: .codebuddy, existing: existing, definitions: code, recognizedCommands: [])
        let both = try HookConfigurationEditor.install(provider: .workbuddy, existing: codeInstalled, definitions: work, recognizedCommands: [])
        let removed = try XCTUnwrap(HookConfigurationEditor.remove(provider: .codebuddy, existing: both, recognizedCommands: Set(code.map(\.command))))
        XCTAssertTrue(try HookConfigurationEditor.inspect(provider: .workbuddy, existing: removed, definitions: work, recognizedCommands: []).isComplete)
        XCTAssertEqual(try HookConfigurationEditor.inspect(provider: .codebuddy, existing: removed, definitions: code, recognizedCommands: []).ownedHookCount, 0)
        let allRemoved = try XCTUnwrap(HookConfigurationEditor.remove(provider: .workbuddy, existing: removed, recognizedCommands: Set(work.map(\.command))))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: allRemoved) as? NSDictionary, try JSONSerialization.jsonObject(with: existing) as? NSDictionary)
    }

    func testZCodeUsesEnabledEventLayoutAndKeepsUnrelatedSettings() throws {
        let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-ZCodeHome", isDirectory: true)
        let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false)
        XCTAssertEqual(environment.configurationURL(for: .zcode), home.appendingPathComponent(".zcode/cli/config.json"))

        let defs = try definitions(.zcode)
        XCTAssertEqual(defs.map(\.event), ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"])
        XCTAssertTrue(defs.allSatisfy { $0.command.contains("--provider zcode") && $0.statusMessage?.hasPrefix("灵宠岛 · ") == true })
        let approval = try XCTUnwrap(defs.first { $0.event == "PermissionRequest" })
        XCTAssertEqual(approval.timeout, 60)
        XCTAssertTrue(approval.command.contains("--timeout 45"))
        XCTAssertEqual(HookConnectionService.capabilities(.zcode), [.lifecycle, .activity, .limitedApproval])

        // ZCode ignores configuration hooks unless hooks.enabled is true, so install
        // must flip the switch without disturbing unrelated keys.
        let user = Data(#"{"ui":{"locale":"zh-CN"},"hooks":{"enabled":false,"timeoutMs":5000}}"#.utf8)
        let installed = try HookConfigurationEditor.install(provider: .zcode, existing: user, definitions: defs, recognizedCommands: [])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        XCTAssertEqual((root["ui"] as? [String: String])?["locale"], "zh-CN")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 5000)
        XCTAssertEqual(Set((try XCTUnwrap(hooks["events"] as? [String: Any])).keys), Set(defs.map(\.event)))
        XCTAssertTrue(try HookConfigurationEditor.inspect(provider: .zcode, existing: installed, definitions: defs, recognizedCommands: []).isComplete)
        XCTAssertFalse(HookConfigurationEditor.configurationHooksDisabled(existing: installed, provider: .zcode))

        var disabledRoot = root
        var disabledHooks = hooks
        disabledHooks["enabled"] = false
        disabledRoot["hooks"] = disabledHooks
        let disabled = try JSONSerialization.data(withJSONObject: disabledRoot)
        XCTAssertTrue(HookConfigurationEditor.configurationHooksDisabled(existing: disabled, provider: .zcode))
        XCTAssertFalse(HookConfigurationEditor.configurationHooksDisabled(existing: disabled, provider: .qoder))
        let commands = Set(defs.map(\.command))
        XCTAssertEqual(HookConfigurationEditor.hooksEnabledState(existing: user, provider: .zcode), .disabled)
        let removed = try XCTUnwrap(HookConfigurationEditor.remove(provider: .zcode, existing: installed, recognizedCommands: commands,
                                                                 restoreHooksEnabled: .disabled))
        let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertEqual((remaining["ui"] as? [String: String])?["locale"], "zh-CN")
        let restoredHooks = try XCTUnwrap(remaining["hooks"] as? [String: Any])
        XCTAssertEqual(restoredHooks["enabled"] as? Bool, false)
        XCTAssertEqual(restoredHooks["timeoutMs"] as? Int, 5000)
        XCTAssertNil(restoredHooks["events"])
        XCTAssertNil(try HookConfigurationEditor.remove(provider: .zcode, existing: removed, recognizedCommands: commands))
    }

    func testZCodeMalformedConfigurationIsRejected() throws {
        for raw in ["[]", #"{"hooks":[]}"#, #"{"hooks":{"events":[]}}"#, #"{"hooks":{"enabled":"yes"}}"#, #"{"hooks":{"events":{"Stop":{"hooks":[]}}}}"#] {
            XCTAssertThrowsError(try HookConfigurationEditor.install(provider: .zcode, existing: Data(raw.utf8), definitions: definitions(.zcode), recognizedCommands: []))
        }
    }

    func testZCodeDetectorRequiresDesktopBundle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ZCodeDetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, applicationDirectories: [root], executableSearchDirectories: [root], detectCLIVersions: false)
        let contents = root.appendingPathComponent("ZCode.app").appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        func write(_ id: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": "3.16.3"], format: .xml, options: 0).write(to: plist)
        }
        try write("com.example.wrong")
        let wrong = await ProviderDetector.detect(provider: .zcode, environment: environment)
        XCTAssertFalse(wrong.isDetected)
        try write("dev.zcode.app")
        let correct = await ProviderDetector.detect(provider: .zcode, environment: environment)
        XCTAssertEqual(correct.appURL, root.appendingPathComponent("ZCode.app", isDirectory: true))
        XCTAssertEqual(correct.appVersion, "3.16.3")
    }

    func testZcodePluginLayoutAndActivation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ZcodePlugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, detectCLIVersions: false)
        XCTAssertEqual(ZcodePluginBridge.marketplaceName, "lingchongdao-local")
        XCTAssertEqual(ZcodePluginBridge.pluginID, "lingchongdao-zcode@lingchongdao-local")
        XCTAssertFalse(ZcodePluginBridge.pluginInstalled(environment))
        XCTAssertFalse(ZcodePluginBridge.isActive(environment))

        let cache = root.appendingPathComponent(".zcode/cli/plugins/cache/lingchongdao-local/lingchongdao-zcode/0.1.0/.zcode-plugin")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: cache.appendingPathComponent("plugin.json"))
        XCTAssertTrue(ZcodePluginBridge.pluginInstalled(environment))
        // ZCode treats a plugin without an explicit switch as enabled.
        XCTAssertNil(ZcodePluginBridge.pluginEnabled(environment))
        XCTAssertTrue(ZcodePluginBridge.isActive(environment))

        let config = root.appendingPathComponent(".zcode/cli/config.json")
        try Data(#"{"plugins":{"enabledPlugins":{"lingchongdao-zcode@lingchongdao-local":false}}}"#.utf8).write(to: config)
        XCTAssertFalse(ZcodePluginBridge.isActive(environment))
        try Data(#"{"plugins":{"enabledPlugins":{"lingchongdao-zcode@lingchongdao-local":true}}}"#.utf8).write(to: config)
        XCTAssertTrue(ZcodePluginBridge.isActive(environment))
    }

    func testZcodePluginInjectsMarketplaceIcon() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ZcodeIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("plugins/lingchongdao-zcode", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: plugin.appendingPathComponent("icon.png"))
        let marketplace = root.appendingPathComponent("marketplace.json")
        try Data(#"{"name":"lingchongdao-local","plugins":[{"name":"lingchongdao-zcode","source":"./plugins/lingchongdao-zcode"}]}"#.utf8).write(to: marketplace)

        try ZcodePluginBridge.injectIcon(into: root)
        let tagged = try Data(contentsOf: marketplace)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: tagged) as? [String: Any])
        let plugins = try XCTUnwrap(object["plugins"] as? [[String: Any]])
        XCTAssertTrue((plugins[0]["icon"] as? String)?.hasPrefix("data:image/png;base64,") == true)

        try ZcodePluginBridge.injectIcon(into: root)
        XCTAssertEqual(try Data(contentsOf: marketplace), tagged, "Injecting twice is a no-op")
    }

    func testQoderPluginTagsInstalledIcon() throws {
        let root = URL(fileURLWithPath: "/private/tmp/QoderIcon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, detectCLIVersions: false)
        let assets = QoderPluginBridge.packageRoot(environment).appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("icon.png"))
        let record = root.appendingPathComponent(".qoder-cn/plugins/installed_plugins_v2.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"plugins":{"lingchongdao-qoder@local":[{"scope":"user"}]}}"#.utf8).write(to: record)

        try QoderPluginBridge.tagInstalledIcon(environment)
        let tagged = try Data(contentsOf: record)
        let rootObject = try XCTUnwrap(JSONSerialization.jsonObject(with: tagged) as? [String: Any])
        let plugins = try XCTUnwrap(rootObject["plugins"] as? [String: Any])
        let entries = try XCTUnwrap(plugins["lingchongdao-qoder@local"] as? [[String: Any]])
        XCTAssertTrue((entries[0]["icon_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)

        try QoderPluginBridge.tagInstalledIcon(environment)
        XCTAssertEqual(try Data(contentsOf: record), tagged, "Tagging twice is a no-op")
    }

    func testPluginPackageVersionOrdering() {
        XCTAssertTrue(PluginPackage.isNewer("0.1.5", than: "0.1.4"))
        XCTAssertTrue(PluginPackage.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(PluginPackage.isNewer("0.1.4", than: "0.1.5"))
        XCTAssertFalse(PluginPackage.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertTrue(PluginPackage.isNewer("0.2.0-rc.1", than: "0.1.9"))
    }

    func testZcodeDetectsBundledUpdate() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ZcodeUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle/plugins/lingchongdao-zcode", isDirectory: true)
        let cache = root.appendingPathComponent(".zcode/cli/plugins/cache/lingchongdao-local/lingchongdao-zcode/0.1.0", isDirectory: true)
        for base in [bundled, cache] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(".zcode-plugin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: base.appendingPathComponent("hooks"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: base.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try Data(#"{"name":"lingchongdao-zcode","version":"0.1.0"}"#.utf8).write(to: base.appendingPathComponent(".zcode-plugin/plugin.json"))
            try Data("{}".utf8).write(to: base.appendingPathComponent("hooks/hooks.json"))
            try Data("#!/bin/sh\n".utf8).write(to: base.appendingPathComponent("scripts/forward-hook.sh"))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: base.appendingPathComponent("icon.png"))
        }
        let environment = ConnectionEnvironment(homeDirectoryURL: root,
            zcodeHomeURL: root.appendingPathComponent(".zcode"),
            zcodePluginSourceURL: root.appendingPathComponent("bundle"), detectCLIVersions: false)
        XCTAssertFalse(ZcodePluginBridge.updateAvailable(environment))

        try FileManager.default.removeItem(at: cache.appendingPathComponent("icon.png"))
        XCTAssertTrue(ZcodePluginBridge.updateAvailable(environment), "Same version with different files is an update")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cache.appendingPathComponent("icon.png"))
        XCTAssertFalse(ZcodePluginBridge.updateAvailable(environment))

        try Data(#"{"name":"lingchongdao-zcode","version":"0.2.0"}"#.utf8).write(to: bundled.appendingPathComponent(".zcode-plugin/plugin.json"))
        XCTAssertTrue(ZcodePluginBridge.updateAvailable(environment))
        try Data(#"{"name":"lingchongdao-zcode","version":"0.3.0"}"#.utf8).write(to: cache.appendingPathComponent(".zcode-plugin/plugin.json"))
        XCTAssertFalse(ZcodePluginBridge.updateAvailable(environment), "A newer host install is never downgraded")
    }

    func testQoderPluginLayoutAndActivation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/QoderPlugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, detectCLIVersions: false)
        XCTAssertEqual(QoderPluginBridge.pluginID, "lingchongdao-qoder@local")
        XCTAssertFalse(QoderPluginBridge.pluginInstalled(environment))
        XCTAssertFalse(QoderPluginBridge.isActive(environment))

        let cache = root.appendingPathComponent(".qoder-cn/plugins/cache/local/lingchongdao-qoder/0.1.0/.qoder-plugin")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: cache.appendingPathComponent("plugin.json"))
        XCTAssertTrue(QoderPluginBridge.pluginInstalled(environment))
        XCTAssertTrue(QoderPluginBridge.isActive(environment), "No explicit switch means enabled")

        let settings = root.appendingPathComponent(".qoder-cn/settings.json")
        try Data(#"{"enabledPlugins":{"lingchongdao-qoder@local":false}}"#.utf8).write(to: settings)
        XCTAssertFalse(QoderPluginBridge.isActive(environment))
        try Data(#"{"enabledPlugins":{"lingchongdao-qoder@local":true}}"#.utf8).write(to: settings)
        XCTAssertTrue(QoderPluginBridge.isActive(environment))
    }

    func testDeepSeekHarnessShipsItsOwnDshBundle() throws {
        let home = URL(fileURLWithPath: "/private/tmp/LingChongDao-DshHome", isDirectory: true)
        let support = URL(fileURLWithPath: "/private/tmp/LingChongDao-DshSupport", isDirectory: true)
        let environment = ConnectionEnvironment(homeDirectoryURL: home, applicationSupportURL: support, detectCLIVersions: false)
        XCTAssertEqual(environment.configurationURL(for: .dsh), home.appendingPathComponent(".dsh/profiles/desktop/package.json"))
        XCTAssertEqual(environment.dshPluginInstallURL, support.appendingPathComponent("dsh-plugin"))
        XCTAssertEqual(HookConnectionService.name(.dsh), "DeepSeek Harness")
        XCTAssertEqual(HookConnectionService.capabilities(.dsh), [.lifecycle, .activity])
        // The dsh integration never writes a hook config file, so the shared
        // editor must refuse the provider instead of inventing one.
        XCTAssertThrowsError(try HookConfigurationEditor.definitions(provider: .dsh, helperURL: URL(fileURLWithPath: "/tmp/helper"), socketPath: "/tmp/bridge.sock"))

        XCTAssertTrue(DshBridge.pluginFiles.contains("cordis.patch.yml"), "The bundle patch is part of the package")
        XCTAssertTrue(DshBridge.pluginFiles.contains("icon.png"), "The harness paints the package icon in its plugin list")
        let preview = DshBridge.preview()
        XCTAssertTrue(preview.contains("dsh.bundle.patch"))
        XCTAssertTrue(preview.contains("'lingchongdao-dsh-hooks'"))
        XCTAssertFalse(preview.contains("dsh-hooks-claude-code"), "The integration must not depend on the harness bridge packages")
    }

    func testDshLegacyLoaderRowCleanup() throws {
        let legacy = DshBridge.beginMarker
            + "\n- insert:\n    - id: lingchongdao-hooks\n      name: 'lingchongdao-dsh-hooks'\n"
            + DshBridge.endMarker + "\n"
        XCTAssertFalse(DshBridge.hasManagedRow(nil))
        XCTAssertNil(DshBridge.removingManagedRow(nil))
        XCTAssertNil(DshBridge.removingManagedRow("- id: agent-default-model\n"))

        let user = "# Your patch layer for this dsh profile\n- id: agent-default-model\n  name: '@deepseek-ai/dsh-agent-default-model'\n"
        XCTAssertEqual(DshBridge.removingManagedRow(existing: user + legacy), user)
        XCTAssertEqual(DshBridge.removingManagedRow(existing: legacy), "[]\n", "Comments alone still need a document body")
        XCTAssertEqual(DshBridge.removingManagedRow(existing: "# only a comment\n" + legacy), "# only a comment\n\n[]\n")
    }

    func testDshBundleSelectionPreservesTheProfileManifest() throws {
        let home = URL(fileURLWithPath: "/private/tmp/DshBundle-\(UUID().uuidString)", isDirectory: true)
        let profile = home.appendingPathComponent(".dsh/profiles/desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = profile.appendingPathComponent("package.json")
        try Data(#"{"name":"dsh-profile-desktop","private":true,"dependencies":{"other":"1.0.0"},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base"]}}}"#.utf8).write(to: manifest)
        let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false)

        XCTAssertFalse(DshBridge.bundleSelected(environment))
        try DshBridge.setBundleSelected(true, in: environment)
        XCTAssertTrue(DshBridge.bundleSelected(environment))
        XCTAssertEqual(DshBridge.profileBundles(environment), ["@deepseek-ai/dsh-base", "lingchongdao-dsh-hooks"])
        let selected = try Data(contentsOf: manifest)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: selected) as? [String: Any])
        XCTAssertEqual(root["name"] as? String, "dsh-profile-desktop")
        XCTAssertEqual((root["dependencies"] as? [String: Any])?["other"] as? String, "1.0.0")

        try DshBridge.setBundleSelected(true, in: environment)
        XCTAssertEqual(try Data(contentsOf: manifest), selected, "Selecting twice is a no-op")
        try DshBridge.setBundleSelected(false, in: environment)
        XCTAssertFalse(DshBridge.bundleSelected(environment))
        XCTAssertEqual(DshBridge.profileBundles(environment), ["@deepseek-ai/dsh-base"])
    }

    func testDshPluginDetectionRequiresManifestEntryAndResolvedBundle() throws {
        let home = URL(fileURLWithPath: "/private/tmp/DshDetect-\(UUID().uuidString)", isDirectory: true)
        let profile = home.appendingPathComponent(".dsh/profiles/desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ConnectionEnvironment(homeDirectoryURL: home, detectCLIVersions: false)
        XCTAssertFalse(DshBridge.profileExists(environment))
        let manifest = profile.appendingPathComponent("package.json")
        try Data(#"{"name":"dsh-profile-desktop","dependencies":{"lingchongdao-dsh-hooks":"link:../plugin"}}"#.utf8).write(to: manifest)
        XCTAssertTrue(DshBridge.profileExists(environment))
        XCTAssertFalse(DshBridge.pluginInstalled(environment), "A manifest entry without a resolved link is not installed")
        let resolved = profile.appendingPathComponent("node_modules/lingchongdao-dsh-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: resolved.appendingPathComponent("package.json"))
        XCTAssertFalse(DshBridge.pluginInstalled(environment), "The bundle patch is required")
        try Data("export const name = 'x'\n".utf8).write(to: resolved.appendingPathComponent("index.js"))
        try Data("- insert: []\n".utf8).write(to: resolved.appendingPathComponent("cordis.patch.yml"))
        XCTAssertFalse(DshBridge.pluginInstalled(environment), "The package icon is part of the runtime file set")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: resolved.appendingPathComponent("icon.png"))
        XCTAssertTrue(DshBridge.pluginInstalled(environment))
    }

    func testDshDetectorRequiresDesktopBundle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/DshApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ConnectionEnvironment(homeDirectoryURL: root, applicationDirectories: [root], executableSearchDirectories: [root], detectCLIVersions: false)
        let contents = root.appendingPathComponent("DeepSeek Harness.app").appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        func write(_ id: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": "0.2.1"], format: .xml, options: 0).write(to: plist)
        }
        try write("com.example.dsh")
        let wrong = await ProviderDetector.detect(provider: .dsh, environment: environment)
        XCTAssertFalse(wrong.isDetected)
        try write("com.deepseek.dsh")
        let correct = await ProviderDetector.detect(provider: .dsh, environment: environment)
        XCTAssertEqual(correct.appURL, root.appendingPathComponent("DeepSeek Harness.app", isDirectory: true))
    }

}
