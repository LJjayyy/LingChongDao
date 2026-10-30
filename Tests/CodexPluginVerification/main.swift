import Foundation
import IslandCore
import IslandConnections

@main struct Verify {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let base = URL(fileURLWithPath: "/private/tmp/lcd-plugin-test-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let missingHome = base.appendingPathComponent("without-codex")
        let missingEnvironment = ConnectionEnvironment(homeDirectoryURL: missingHome,
            detectCLIVersions: false, codexPluginSourceURL: root)
        let missingPlugin = CodexPluginService(environment: missingEnvironment,
            hooks: HookConnectionService(environment: missingEnvironment))
        let missing = await missingPlugin.check()
        precondition(missing.status == .notDetected, "Missing Codex must not be reported as broken configuration: \(missing.message)")
        let applications = missingHome.appendingPathComponent("Applications")
        let appContents = applications.appendingPathComponent("Codex.app/Contents")
        try fm.createDirectory(at: appContents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.openai.codex"], format: .xml, options: 0)
            .write(to: appContents.appendingPathComponent("Info.plist"))
        var appOnlyEnvironment = missingEnvironment
        appOnlyEnvironment.applicationDirectories = [applications]
        let appOnlyPlugin = CodexPluginService(environment: appOnlyEnvironment,
            hooks: HookConnectionService(environment: appOnlyEnvironment))
        let appOnly = await appOnlyPlugin.check()
        precondition(appOnly.status == .notInstalled && appOnly.detection.appURL != nil,
                     "A detected app without its CLI needs setup, not repair")
        try fm.createDirectory(at: missingEnvironment.codexHomeURL, withIntermediateDirectories: true)
        try Data("{invalid-json".utf8).write(to: missingEnvironment.configurationURL(for: .codex))
        let malformed = await missingPlugin.check()
        precondition(malformed.status == .configurationError, "Missing CLI must not conceal a malformed existing configuration")
        let bin = base.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("codex")
        let code = """
#!/usr/bin/python3
import os,sys,json
p=os.path.join(os.environ['HOME'],'state.json')
s=json.load(open(p)) if os.path.exists(p) else {}
a=sys.argv[1:]
if os.path.exists(os.path.join(os.environ['HOME'],'timeout')):
 import time;time.sleep(5)
if os.path.exists(os.path.join(os.environ['HOME'],'overflow')):
 print('x'*1100000);sys.exit(0)
if os.path.exists(os.path.join(os.environ['HOME'],'fail')) and a[:2]==['plugin','add']: sys.exit(2)
if a[:3]==['plugin','marketplace','list']:
 print(json.dumps({'marketplaces':([{'name':'lingchongdao-local','root':s['root'],'marketplaceSource':{'sourceType':'local','source':s['root']}}] if 'root' in s else [])}))
elif a[:3]==['plugin','marketplace','add']:
 s['root']=a[3];print('{}')
elif a[:2]==['plugin','add']:
 s['installed']=True;print('{}')
elif a[:2]==['plugin','remove']:
 s['installed']=False;print('{}')
elif a[:2]==['plugin','list']:
 print(json.dumps({'installed':([{'name':'lingchongdao-codex','marketplaceName':'lingchongdao-local','installed':True,'version':json.load(open(os.path.join(s['root'],'package-info.json')))['pluginVersion'],'source':{'path':s['root']+'/plugins/lingchongdao-codex'},'marketplaceSource':{'source':s['root']},'enabled':not os.path.exists(os.path.join(os.environ['HOME'],'disabled'))}] if s.get('installed') else [])}))
else: print('{}')
json.dump(s,open(p,'w'))
"""
        try Data(code.utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions:0o700], ofItemAtPath:cli.path)
        let environment = ConnectionEnvironment(homeDirectoryURL:base, helperSourceURL:root.appendingPathComponent("plugins/lingchongdao-codex/bin/lingchongdao-hook"), executableSearchDirectories:[bin], detectCLIVersions:false, codexPluginSourceURL:root)
        let hooks = HookConnectionService(environment:environment)
        let plugin = CodexPluginService(environment:environment, hooks:hooks)
        try fm.createDirectory(at:environment.codexHomeURL, withIntermediateDirectories:true)
        let foreign: [String:Any] = ["hooks":["SessionStart":[["hooks":[["type":"command","command":"echo foreign-user-hook"]]]]]]
        try JSONSerialization.data(withJSONObject:foreign).write(to:environment.configurationURL(for:.codex))
        _ = try await hooks.prepare(provider:.qoder)
        try await hooks.install(provider:.qoder)
        let qoderBefore = try Data(contentsOf:environment.configurationURL(for:.qoder))
        _ = try await hooks.prepare(provider:.codex)
        try await hooks.install(provider:.codex)
        let initial = await plugin.check()
        precondition(initial.status == .notInstalled, initial.message)
        try Data().write(to:base.appendingPathComponent("fail"))
        do { try await plugin.install(); fatalError("failure accepted") } catch {}
        let retained = await hooks.check(provider:.codex)
        precondition(retained.installedHookCount == 10)
        try fm.removeItem(at:base.appendingPathComponent("fail"))
        print("stage install")
        try await plugin.install()
        let pluginRoot = environment.applicationSupportURL.appendingPathComponent("codex-plugin")
        let marker = pluginRoot.appendingPathComponent("owned-tree.sha256")
        let markerData = try Data(contentsOf:marker)
        try fm.removeItem(at:marker)
        try markerData.write(to:pluginRoot.appendingPathComponent("pending-tree.sha256"))
        try await plugin.install()
        print("stage check")
        let installed = await plugin.check()
        precondition(installed.status == .installed, installed.message)
        let direct = await hooks.check(provider:.codex)
        precondition(direct.installedHookCount == 0)
        let remaining = try String(contentsOf:environment.configurationURL(for:.codex), encoding:.utf8)
        precondition(remaining.contains("echo foreign-user-hook"))
        let qoderAfter = try Data(contentsOf:environment.configurationURL(for:.qoder))
        precondition(qoderBefore == qoderAfter)
        try await plugin.install()
        try Data().write(to:base.appendingPathComponent("disabled"))
        let disabled = await plugin.check()
        precondition(disabled.status == .needsReview)
        do { try await plugin.install(); fatalError("disabled accepted") } catch {}
        try await plugin.remove()
        try fm.removeItem(at:base.appendingPathComponent("disabled"))
        let upgraded = base.appendingPathComponent("upgraded")
        try fm.copyItem(at:root, to:upgraded)
        let metadataURL = upgraded.appendingPathComponent("package-info.json")
        var metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:metadataURL)) as! [String:Any]
        metadata["appVersion"] = "next-version"
        try JSONSerialization.data(withJSONObject:metadata).write(to:metadataURL)
        var nextEnvironment = environment
        nextEnvironment.codexPluginSourceURL = upgraded
        let nextPlugin = CodexPluginService(environment:nextEnvironment, hooks:hooks)
        try await nextPlugin.install()
        let next = await nextPlugin.check()
        precondition(next.status == .installed, next.message)
        // Simulate interruption after old tree rename, then after new tree publish.
        let support = environment.applicationSupportURL.appendingPathComponent("codex-plugin")
        let target = support.appendingPathComponent("marketplace")
        let interruptedBackup = support.appendingPathComponent(".previous-interruption-test")
        try fm.moveItem(at:target, to:interruptedBackup)
        try await nextPlugin.install()
        try fm.moveItem(at:target, to:interruptedBackup)
        try fm.copyItem(at:root, to:target)
        try await nextPlugin.install()
        var state = try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("state.json"))) as! [String:Any]
        state["root"] = "/foreign-marketplace"
        try JSONSerialization.data(withJSONObject:state).write(to:base.appendingPathComponent("state.json"))
        do { try await nextPlugin.install(); fatalError("foreign marketplace accepted") } catch {}
        state["root"] = target.path
        try JSONSerialization.data(withJSONObject:state).write(to:base.appendingPathComponent("state.json"))
        try Data().write(to:base.appendingPathComponent("timeout"))
        let boundedPlugin = CodexPluginService(environment:nextEnvironment, hooks:hooks, commandTimeout:0.2)
        do { try await boundedPlugin.install(); fatalError("timeout accepted") } catch {}
        try fm.removeItem(at:base.appendingPathComponent("timeout"))
        try Data().write(to:base.appendingPathComponent("overflow"))
        do { try await nextPlugin.install(); fatalError("overflow accepted") } catch {}
        try fm.removeItem(at:base.appendingPathComponent("overflow"))
        let helperURL = upgraded.appendingPathComponent("plugins/lingchongdao-codex/bin/lingchongdao-hook")
        let helper = try Data(contentsOf:helperURL)
        try Data("corrupt".utf8).write(to:helperURL)
        do { try await nextPlugin.install(); fatalError("bad helper accepted") } catch {}
        try helper.write(to:helperURL)
        try fm.createSymbolicLink(at:upgraded.appendingPathComponent("unexpected-link"), withDestinationURL:root)
        do { try await nextPlugin.install(); fatalError("symlink accepted") } catch {}

        print("PASS: missing source/app-only/malformed config/install/migration/failure retention/idempotency/disabled/uninstall/upgrade/interruption recovery/foreign marketplace/output limit/helper hash/symlink")
    }
}
