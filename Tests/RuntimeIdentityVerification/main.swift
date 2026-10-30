import Foundation
import Darwin
import IslandCore

@main struct RuntimeIdentityVerification {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw NSError(domain: "RuntimeIdentityVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        checks += 1
    }
    static func fails(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NSError(domain: "RuntimeIdentityVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected refusal: " + name])
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/lcd-migration-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        func base(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let fresh = try base("fresh")
        try RuntimeIdentityMigration.migrateSupport(in: fresh)
        try expect(fm.fileExists(atPath: fresh.appendingPathComponent("LingChongDao").path), "fresh canonical directory")
        try expect(try fm.destinationOfSymbolicLink(atPath: fresh.appendingPathComponent("AIIsland").path) == fresh.appendingPathComponent("LingChongDao").path, "controlled legacy alias")
        try RuntimeIdentityMigration.migrateSupport(in: fresh)
        checks += 1

        let oldBase = try base("old")
        let old = oldBase.appendingPathComponent("AIIsland")
        try fm.createDirectory(at: old.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let bytes = Data("#!/bin/sh\nexit 0\n".utf8)
        let helper = old.appendingPathComponent("bin/ai-island-hook")
        try bytes.write(to: helper); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let manifest = HookInstallationManifest(helperSHA256: ConnectionFileStore.digest(bytes), ownedCommands: ["codex": ["untouched old command"]])
        let manifestBytes = try JSONEncoder().encode(manifest)
        try manifestBytes.write(to: old.appendingPathComponent("hook-installation.json"))
        try Data("draft data".utf8).write(to: old.appendingPathComponent("keep.txt"))
        try RuntimeIdentityMigration.migrateSupport(in: oldBase)
        let canonical = oldBase.appendingPathComponent("LingChongDao")
        try expect(try Data(contentsOf: canonical.appendingPathComponent("bin/lingchongdao-hook")) == bytes, "copies owned helper")
        try expect(try Data(contentsOf: old.appendingPathComponent("bin/ai-island-hook")) == bytes, "old helper remains executable by alias")
        try expect(try Data(contentsOf: canonical.appendingPathComponent("hook-installation.json")) == manifestBytes, "manifest bytes preserved")
        try expect(try String(contentsOf: old.appendingPathComponent("keep.txt"), encoding: .utf8) == "draft data", "data retained via legacy alias")
        try RuntimeIdentityMigration.migrateSupport(in: oldBase); checks += 1
        let server = IslandSocketServer(socketPath: canonical.appendingPathComponent("run/bridge.sock").path)
        try server.start(handler: { _ in .acknowledged })
        let reply = try IslandSocketClient(socketPath: old.appendingPathComponent("run/bridge.sock").path).send(BridgeEnvelope(provider: .generic, operation: .ping))
        try expect(reply.disposition == .status, "old socket alias reaches canonical server")
        server.stop()

        let conflict = try base("conflict")
        for name in ["AIIsland", "LingChongDao"] { try fm.createDirectory(at: conflict.appendingPathComponent(name), withIntermediateDirectories: false) }
        try fails("both stores") { try RuntimeIdentityMigration.migrateSupport(in: conflict) }
        try expect(try fm.contentsOfDirectory(atPath: conflict.path).count == 2, "conflict kept both")
        let badLink = try base("bad-link")
        try fm.createSymbolicLink(atPath: badLink.appendingPathComponent("AIIsland").path, withDestinationPath: fresh.path)
        try fails("foreign symlink") { try RuntimeIdentityMigration.migrateSupport(in: badLink) }
        let nestedLink = try base("nested-link")
        try fm.createDirectory(at: nestedLink.appendingPathComponent("AIIsland"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: nestedLink.appendingPathComponent("AIIsland/data").path, withDestinationPath: fresh.path)
        try fails("nested symlink") { try RuntimeIdentityMigration.migrateSupport(in: nestedLink) }
        let canonicalLink = try base("canonical-link")
        try fm.createSymbolicLink(atPath: canonicalLink.appendingPathComponent("LingChongDao").path, withDestinationPath: fresh.path)
        try fails("canonical symlink") { try RuntimeIdentityMigration.migrateSupport(in: canonicalLink) }
        let ordinaryFile = try base("ordinary-file")
        try bytes.write(to: ordinaryFile.appendingPathComponent("AIIsland"))
        try fails("legacy regular file") { try RuntimeIdentityMigration.migrateSupport(in: ordinaryFile) }
        let partial = try base("partial")
        try fm.createDirectory(at: partial.appendingPathComponent("LingChongDao/bin"), withIntermediateDirectories: true)
        let unknown = Data("leave this alone".utf8)
        try unknown.write(to: partial.appendingPathComponent("LingChongDao/bin/lingchongdao-hook"))
        try RuntimeIdentityMigration.migrateSupport(in: partial)
        try expect(try Data(contentsOf: partial.appendingPathComponent("LingChongDao/bin/lingchongdao-hook")) == unknown, "migration never overwrites unknown canonical helper")
        let unowned = try base("unowned")
        try fm.createDirectory(at: unowned.appendingPathComponent("AIIsland/bin"), withIntermediateDirectories: true)
        try bytes.write(to: unowned.appendingPathComponent("AIIsland/bin/ai-island-hook"))
        try fails("helper without manifest ownership") { try RuntimeIdentityMigration.migrateSupport(in: unowned) }
        try expect(fm.fileExists(atPath: unowned.appendingPathComponent("AIIsland").path), "unowned helper refused before move")

        let merged = RuntimeIdentityMigration.mergedPreferences(legacy: ["island.enabled": true, "sources.codex": false, "island.widthPercent": 110.0, "draft.task": "hi", "AppleInterfaceStyle": "Dark", "island.haptics": "invalid"], current: ["island.enabled": false, "current": "kept"])
        try expect(merged["island.enabled"] as? Bool == false, "existing setting wins")
        try expect(merged["sources.codex"] as? Bool == false, "owned bool copied")
        try expect(merged["island.widthPercent"] as? Double == 110, "owned dimension copied")
        try expect(merged["draft.task"] as? String == "hi", "draft copied")
        try expect(merged["AppleInterfaceStyle"] == nil && merged["island.haptics"] == nil, "global and invalid preference excluded")

        // Historical commands are recognized only if manifest-recorded and tied
        // to the exact historical helper. A marker on a foreign hook survives.
        let home = try base("hook-home")
        let source = root.appendingPathComponent("new-helper")
        try bytes.write(to: source); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let environment = ConnectionEnvironment(homeDirectoryURL: home, helperSourceURL: source, detectCLIVersions: false)
        let legacyPath = home.appendingPathComponent("Library/Application Support/AIIsland/bin/ai-island-hook")
        let oldCommand = "\(HookConfigurationEditor.shellQuote(legacyPath.path)) --provider codex --socket '/old/socket' --timeout 2 # ai-island-managed:v1:codex"
        let foreign = "'/foreign/ai-island-hook' --provider codex --socket '/old/socket' --timeout 2 # ai-island-managed:v1:codex"
        try fm.createDirectory(at: environment.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records = HookInstallationManifest(ownedCommands: ["codex": [oldCommand, foreign]])
        try JSONEncoder().encode(records).write(to: environment.manifestURL)
        let config: [String: Any] = ["keep": true, "hooks": ["Stop": [["hooks": [["type": "command", "command": oldCommand], ["type": "command", "command": foreign]]]]]]
        try fm.createDirectory(at: environment.configurationURL(for: .codex).deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: environment.configurationURL(for: .codex))
        let service = HookConnectionService(environment: environment)
        let plan = try await service.prepare(provider: .codex)
        try expect(plan.hookPreview.contains("lingchongdao-managed:v1:codex") && !plan.hookPreview.contains("ai-island-managed"), "new definitions canonical")
        try await service.install(provider: .codex)
        let installed = try String(contentsOf: environment.configurationURL(for: .codex), encoding: .utf8)
        try expect(!installed.contains(oldCommand), "legacy exact command replaced")
        try expect(installed.contains("/foreign/ai-island-hook"), "foreign marker retained")
        try await service.remove(provider: .codex)
        let removed = try String(contentsOf: environment.configurationURL(for: .codex), encoding: .utf8)
        try expect(!removed.contains("lingchongdao-managed") && removed.contains("/foreign/ai-island-hook"), "remove only managed new and legacy hooks")
        print("Runtime identity verification: \(checks) checks passed")
    }
}
