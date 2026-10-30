import Foundation
import IslandCore

private enum CheckError: Error { case failed(String) }

@main
struct OriginVerification {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw CheckError.failed(message) }
        checks += 1
    }
    static let desktopPath = "/Applications/Source Desktop.app/Contents/MacOS/Qoder"
    static let idePath = "/Applications/Source IDE.app/Contents/MacOS/Qoder"
    static let hookPath = "/Users/fixture/Library/Application Support/LingChongDao/bin/lingchongdao-hook"
    static func process(_ pid: Int32, _ parent: Int32, _ path: String) -> SourceProcessRecord { .init(pid: pid, parentPID: parent, executablePath: path) }
    static func detect(_ records: [Int32: SourceProcessRecord], provider: ProviderID = .qoder, current: Int32 = 100, hints: [Int32] = [], bundles: [String: String] = [:]) -> SourceApplicationID? {
        let known = ["/Applications/Source Desktop.app": "com.qodercn.app", "/Applications/Source IDE.app": "com.aliyun.lingma.ide"].merging(bundles) { _, right in right }
        return QoderSourceApplicationDetector.detect(provider: provider, currentPID: current, hintedPIDs: hints,
                                                     processLookup: { records[$0] }, bundleIdentifierLookup: { known[$0.path] })
    }
    static func main() {
        do {
            let desktop: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 1, desktopPath)]
            let ide: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 1, idePath)]
            try require(URL(fileURLWithPath: desktopPath).lastPathComponent == URL(fileURLWithPath: idePath).lastPathComponent, "same short process name fixture")
            try require(detect(desktop) == .qoderDesktop && detect(ide) == .qoderIDE, "same short name is distinguished by outer app bundle identity")
            let backend: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 300, "/bin/zsh"), 300: process(300, 400, "/Applications/Source IDE.app/Contents/Resources/app/node_modules/backend/node"), 400: process(400, 1, idePath)]
            try require(detect(backend) == .qoderIDE, "IDE backend ancestry resolves full executable location")
            let helper: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 1, "/Applications/Source Desktop.app/Contents/Frameworks/Source Helper.app/Contents/MacOS/Qoder")]
            try require(detect(helper, bundles: ["/Applications/Source Desktop.app/Contents/Frameworks/Source Helper.app": "com.aliyun.lingma.ide"]) == .qoderDesktop,
                        "nested helper cannot override its outer app")
            let unknownOuter: [Int32: SourceProcessRecord] = [100: process(100, 1, "/Applications/Other.app/Contents/Frameworks/Source Helper.app/Contents/MacOS/Qoder")]
            try require(detect(unknownOuter, bundles: ["/Applications/Other.app": "com.example.other", "/Applications/Other.app/Contents/Frameworks/Source Helper.app": "com.qodercn.app"]) == .qoderUnknown,
                        "allowlisted nested helper does not identify an unknown outer app")
            try require(detect([100: process(100, 1, hookPath)]) == .qoderUnknown, "reparented hook stays unknown")
            try require(detect([100: process(100, 1, "/tmp/qoder")]) == .qoderUnknown, "short executable name is insufficient")
            try require(detect([100: process(100, 1, "/tmp/qodercn/backend")]) == .qoderUnknown, "qoder substring in path is insufficient")
            try require(detect([100: process(100, 1, desktopPath)], bundles: ["/Applications/Source Desktop.app": "com.example.spoof"]) == .qoderUnknown,
                        "app filename without allowlisted Info.plist identity is insufficient")
            try require(detect([100: process(100, 1, desktopPath)], bundles: ["/Applications/Source Desktop.app": "com.qodercn.app.helper"]) == .qoderUnknown,
                        "bundle identifier prefix does not pass the exact allowlist")
            try require(detect([100: process(100, 1, desktopPath)], bundles: ["/Applications/Source Desktop.app": "Com.qodercn.app"]) == .qoderUnknown,
                        "bundle identifier matching is exact")
            try require(detect([100: process(100, 1, "/Applications/Source Desktop.app/not-contents/Qoder")]) == .qoderUnknown,
                        "app-looking arbitrary folder does not identify a bundle")
            try require(detect([100: process(100, 1, "Source Desktop.app/Contents/MacOS/Qoder")]) == .qoderUnknown,
                        "relative executable path is refused")
            try require(detect([100: process(100, 1, "/Applications/Source Desktop.app/Contents/../../Qoder")]) == .qoderUnknown,
                        "path normalization cannot preserve escaped app evidence")

            let hinted: [Int32: SourceProcessRecord] = [100: process(100, 1, hookPath), 500: process(500, 1, idePath)]
            try require(detect(hinted, hints: [500]) == .qoderUnknown, "an allowlisted app PID outside ancestry does not prove source")
            try require(detect([100: process(100, 1, hookPath), 500: process(500, 1, "/tmp/Qoder")], hints: [500]) == .qoderUnknown,
                        "unvalidated hint executable is ignored")
            try require(detect([100: process(100, 1, hookPath)], hints: [500]) == .qoderUnknown,
                        "missing or exited hint PID is ignored")
            try require(detect(hinted, hints: [0, -1]) == .qoderUnknown, "invalid PID hints are ignored")
            try require(detect([100: process(100, 1, hookPath), 500: process(999, 1, idePath)], hints: [500]) == .qoderUnknown,
                        "lookup record must match the hinted PID")
            try require(detect([100: process(999, 1, desktopPath)]) == .qoderUnknown, "ancestor lookup record must match its PID")
            let conflicting: [Int32: SourceProcessRecord] = [100: process(100, 1, hookPath), 500: process(500, 1, desktopPath), 600: process(600, 1, idePath)]
            try require(detect(conflicting, hints: [500, 600]) == .qoderUnknown, "conflicting validated PID hints remain unknown")
            try require(detect(hinted, hints: [500, 500]) == .qoderUnknown, "duplicate weak hints cannot identify a source")
            try require(detect(hinted, hints: [0, -1, 500]) == .qoderUnknown, "weak hints never supply a source regardless of position")
            let staleDesktopHint: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 500: process(500, 1, desktopPath)]
            try require(detect(staleDesktopHint, hints: [500]) == .qoderUnknown,
                        "unreadable ancestry plus a stale inherited desktop PID stays unknown")
            let reparentedIDE: [Int32: SourceProcessRecord] = [100: process(100, 1, hookPath), 500: process(500, 1, desktopPath)]
            try require(detect(reparentedIDE, hints: [500]) == .qoderUnknown,
                        "reparented IDE hook cannot inherit a desktop classification from a stale PID hint")
            let ideWithDesktopHint = ide.merging([500: process(500, 1, desktopPath)]) { left, _ in left }
            try require(detect(ideWithDesktopHint, hints: [500]) == .qoderIDE,
                        "verified IDE ancestry remains IDE despite an inherited desktop PID")
            var hintLookups: [Int32] = []
            let ignoredHint = QoderSourceApplicationDetector.detect(provider: .qoder, currentPID: 100, hintedPIDs: [500], processLookup: { pid in hintLookups.append(pid); return reparentedIDE[pid] }, bundleIdentifierLookup: { _ in "com.qodercn.app" })
            try require(ignoredHint == .qoderUnknown && hintLookups == [100], "weak hinted processes are not inspected")
            var ancestorLookups: [Int32] = []
            let priorityRecords = desktop.merging([500: process(500, 1, idePath)]) { left, _ in left }
            let priority = QoderSourceApplicationDetector.detect(provider: .qoder, currentPID: 100, hintedPIDs: [500], processLookup: { pid in ancestorLookups.append(pid); return priorityRecords[pid] }, bundleIdentifierLookup: { url in url.path == "/Applications/Source Desktop.app" ? "com.qodercn.app" : "com.aliyun.lingma.ide" })
            try require(priority == .qoderDesktop && !ancestorLookups.contains(500), "verified ancestry takes priority over conflicting environment hints")
            var cyclicLookups = 0
            let cycle: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 100, "/bin/zsh")]
            let cyclic = QoderSourceApplicationDetector.detect(provider: .qoder, currentPID: 100, processLookup: { pid in cyclicLookups += 1; return cycle[pid] }, bundleIdentifierLookup: { _ in nil })
            try require(cyclic == .qoderUnknown && cyclicLookups == 2, "ancestry loops terminate without guessing")
            var depthLookups = 0
            let deep = QoderSourceApplicationDetector.detect(provider: .qoder, currentPID: 100, processLookup: { pid in depthLookups += 1; return process(pid, pid + 1, "/bin/zsh") }, bundleIdentifierLookup: { _ in nil })
            try require(deep == .qoderUnknown && depthLookups <= 48, "ancestry depth is bounded")
            var crossProviderLookups = 0
            for provider in [ProviderID.codex, .generic] {
                let result = QoderSourceApplicationDetector.detect(provider: provider, currentPID: 100, hintedPIDs: [500], processLookup: { _ in crossProviderLookups += 1; return process(100, 1, desktopPath) }, bundleIdentifierLookup: { _ in "com.qodercn.app" })
                try require(result == nil, "other providers do not inherit a Qoder source")
            }
            try require(crossProviderLookups == 0, "other providers do not inspect processes")
            try require(QoderSourceApplicationDetector.detect(provider: .codex) == nil, "live detector skips non-Qoder providers")
            let raw = Data(#"{"hook_event_name":"SessionStart","session_id":"source-fixture"}"#.utf8)
            let desktopEvent = try HookNormalizer.normalize(rawJSON: raw, provider: .qoder, sourceApplication: .qoderDesktop)
            let ideEvent = try HookNormalizer.normalize(rawJSON: raw, provider: .qoder, sourceApplication: .qoderIDE)
            try require(desktopEvent.sourceApplication == .qoderDesktop && ideEvent.sourceApplication == .qoderIDE && desktopEvent.sessionKey != ideEvent.sessionKey,
                        "normalized source metadata separates colliding desktop and IDE session IDs")
            let envelope = BridgeEnvelope(provider: .qoder, sourceApplication: .qoderIDE)
            let decoded = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(envelope))
            try require(decoded.sourceApplication == .qoderIDE, "source application metadata survives bridge encoding")
            let legacy = BridgeEnvelope(provider: .qoder)
            try require(legacy.sourceApplication == nil, "legacy and fixture envelopes do not fabricate an origin")
            func codexOrigin(_ path: String, bundle: String, parentPath: String? = nil) -> SourceApplicationID? {
                var records = [Int32(100): process(100, 200, hookPath), 200: process(200, parentPath == nil ? 1 : 300, path)]
                if let parentPath { records[300] = process(300, 1, parentPath) }
                return SourceApplicationDetector.detect(provider: .codex, currentPID: 100,
                    processLookup: { records[$0] }, bundleIdentifierLookup: { _ in bundle })
            }
            let codexPath = "/Applications/Codex.app/Contents/MacOS/Codex"
            let chatPath = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            try require(codexOrigin(codexPath, bundle: "com.openai.codex") == .codexDesktop, "Codex desktop exact outer bundle is identified")
            try require(codexOrigin(chatPath, bundle: "com.openai.chat") == .codexChatGPT, "ChatGPT exact outer bundle is identified")
            try require(codexOrigin("/usr/local/bin/codex", bundle: "com.openai.codex") == nil, "terminal CLI has no desktop origin")
            try require(codexOrigin(codexPath, bundle: "com.openai.codex.helper") == nil, "Codex bundle prefix is not sufficient")
            try require(codexOrigin(codexPath, bundle: "com.qodercn.app") == nil, "Codex cannot inherit a Qoder bundle")
            try require(detect([100: process(100, 1, codexPath)], bundles: ["/Applications/Codex.app": "com.openai.codex"]) == .qoderUnknown, "Qoder cannot inherit a Codex bundle")
            let bundledCLI = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            try require(codexOrigin(bundledCLI, bundle: "com.openai.chat") == nil, "bundled CLI launched from terminal does not prove ChatGPT host")
            try require(codexOrigin(bundledCLI, bundle: "com.openai.chat", parentPath: "/bin/zsh") == nil, "terminal parent of bundled CLI remains unclassified")
            try require(codexOrigin("/Applications/Codex.app/Contents/Resources/codex", bundle: "com.openai.codex") == nil, "resource CLI location does not prove Codex host")
            try require(codexOrigin(bundledCLI, bundle: "com.openai.chat", parentPath: chatPath) == .codexChatGPT, "real ChatGPT ancestor proves host beyond bundled CLI")
            var inspectedBundles: [String] = []
            let nestedSpoof = SourceApplicationDetector.detect(provider: .codex, currentPID: 100,
                processLookup: { _ in process(100, 1, "/Applications/Other.app/Contents/Frameworks/Codex.app/Contents/MacOS/Codex") },
                bundleIdentifierLookup: { url in inspectedBundles.append(url.path); return url.path == "/Applications/Other.app" ? "com.example.other" : "com.openai.codex" })
            try require(nestedSpoof == nil && inspectedBundles == ["/Applications/Other.app"], "allowlisted inner bundle cannot spoof an unknown outer app")
            var genericLookups = 0
            let genericOrigin = SourceApplicationDetector.detect(provider: .generic, currentPID: 100,
                processLookup: { _ in genericLookups += 1; return nil }, bundleIdentifierLookup: { _ in genericLookups += 1; return nil })
            try require(genericOrigin == nil && genericLookups == 0, "generic provider never inspects processes or bundles")
            for origin in [SourceApplicationID.codexDesktop, .codexChatGPT] {
                let wire = BridgeEnvelope(provider: .codex, sourceApplication: origin)
                let roundTrip = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(wire))
                try require(roundTrip.sourceApplication == origin && origin.provider == .codex, "Codex desktop origin survives bridge encoding")
                try require(SessionIdentity.key(source: .codex, sessionID: "stable", threadID: nil, sourceApplication: origin) == SessionIdentity.key(source: .codex, sessionID: "stable", threadID: nil), "Codex source metadata does not alter legacy session key")
            }
            let buddyOrigins: [(ProviderID, String, SourceApplicationID)] = [
                (.codebuddy, "com.tencent.codebuddycn", .codebuddyCNIDE),
                (.workbuddy, "com.tencent.workbuddy.mac", .workbuddyDesktop),
                (.workbuddy, "com.workbuddy.workbuddy-ai", .workbuddyAI)
            ]
            for (provider, bundle, expected) in buddyOrigins {
                let records: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 1, "/Applications/Buddy.app/Contents/MacOS/Buddy")]
                let origin = SourceApplicationDetector.detect(provider: provider, currentPID: 100, processLookup: { records[$0] }, bundleIdentifierLookup: { _ in bundle })
                try require(origin == expected, "Buddy exact bundle from observed ancestry identifies source")
                let cliPath = "/Applications/Buddy.app/Contents/Resources/runtime/buddy"
                let terminalCLI: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 300, cliPath), 300: process(300, 1, "/bin/zsh")]
                let isolatedCLI = SourceApplicationDetector.detect(provider: provider, currentPID: 100, processLookup: { terminalCLI[$0] }, bundleIdentifierLookup: { _ in bundle })
                let expectedUnknown: SourceApplicationID = provider == .codebuddy ? .codebuddyUnknown : .workbuddyUnknown
                try require(isolatedCLI == expectedUnknown, "Buddy bundled CLI launched from a terminal does not prove desktop origin")
                let desktopCLI: [Int32: SourceProcessRecord] = [100: process(100, 200, hookPath), 200: process(200, 300, cliPath), 300: process(300, 1, "/Applications/Buddy.app/Contents/MacOS/Buddy")]
                let observedGUI = SourceApplicationDetector.detect(provider: provider, currentPID: 100, processLookup: { desktopCLI[$0] }, bundleIdentifierLookup: { _ in bundle })
                try require(observedGUI == expected, "Buddy walk continues beyond bundled CLI to a real GUI ancestor")
                let unknown: SourceApplicationID = provider == .codebuddy ? .codebuddyUnknown : .workbuddyUnknown
                let reparented = SourceApplicationDetector.detect(provider: provider, currentPID: 100, hintedPIDs: [200], processLookup: { pid in pid == 100 ? process(100, 1, hookPath) : records[pid] }, bundleIdentifierLookup: { _ in bundle })
                try require(reparented == unknown, "Buddy environment PID hint cannot supply origin")
                let wrong = SourceApplicationDetector.detect(provider: provider, currentPID: 100, processLookup: { records[$0] }, bundleIdentifierLookup: { _ in "com.qodercn.app" })
                try require(wrong == unknown, "Buddy never inherits another provider application")
                let wire = BridgeEnvelope(provider: provider, sourceApplication: expected)
                let decoded = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(wire))
                try require(decoded.sourceApplication == expected, "Buddy bridge preserves precise source")
            }
            // ZCode hooks run inside helper processes of one Electron bundle; the
            // outer application identity is the only verified origin evidence.
            let zcodeRecords: [Int32: SourceProcessRecord] = [
                100: process(100, 200, hookPath),
                200: process(200, 300, "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper"),
                300: process(300, 1, "/Applications/ZCode.app/Contents/MacOS/ZCode")
            ]
            let zcodeOrigin = SourceApplicationDetector.detect(provider: .zcode, currentPID: 100,
                processLookup: { zcodeRecords[$0] },
                bundleIdentifierLookup: { url in url.path == "/Applications/ZCode.app" ? "dev.zcode.app" : "com.example.other" })
            try require(zcodeOrigin == .zcodeDesktop, "ZCode helper ancestry resolves to the desktop app")
            let zcodeSpoof = SourceApplicationDetector.detect(provider: .zcode, currentPID: 100,
                processLookup: { zcodeRecords[$0] }, bundleIdentifierLookup: { _ in "com.qodercn.app" })
            try require(zcodeSpoof == nil, "ZCode never inherits another provider application")
            let zcodeTerminal: [Int32: SourceProcessRecord] = [100: process(100, 1, "/bin/zsh")]
            let terminalOrigin = SourceApplicationDetector.detect(provider: .zcode, currentPID: 100,
                processLookup: { zcodeTerminal[$0] }, bundleIdentifierLookup: { _ in "dev.zcode.app" })
            try require(terminalOrigin == nil, "ZCode CLI in a terminal stays unclassified")
            let zcodeWire = BridgeEnvelope(provider: .zcode, sourceApplication: .zcodeDesktop)
            let decodedZCode = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(zcodeWire))
            try require(decodedZCode.sourceApplication == .zcodeDesktop, "ZCode bridge preserves precise source")
            let dshOrigin = SourceApplicationDetector.detect(provider: .dsh, currentPID: 100,
                processLookup: { zcodeRecords[$0] },
                bundleIdentifierLookup: { _ in "dev.zcode.app" })
            try require(dshOrigin == nil, "another application's bundle never classifies as DeepSeek Harness")
            let dshDesktop: [Int32: SourceProcessRecord] = [
                100: process(100, 200, hookPath),
                200: process(200, 300, "/Applications/DeepSeek Harness.app/Contents/Frameworks/Electron Helper.app/Contents/MacOS/Electron Helper"),
                300: process(300, 1, "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness")
            ]
            let dshApp = SourceApplicationDetector.detect(provider: .dsh, currentPID: 100,
                processLookup: { dshDesktop[$0] },
                bundleIdentifierLookup: { url in url.path == "/Applications/DeepSeek Harness.app" ? "com.deepseek.dsh" : "com.example.other" })
            try require(dshApp == .dshDesktop, "DeepSeek Harness helper ancestry resolves to the desktop app")
            let dshWire = BridgeEnvelope(provider: .dsh, sourceApplication: .dshDesktop)
            let decodedDsh = try JSONDecoder().decode(BridgeEnvelope.self, from: JSONEncoder().encode(dshWire))
            try require(decodedDsh.sourceApplication == .dshDesktop, "DeepSeek Harness bridge preserves precise source")
            print("PASS \(checks) source application checks; synthetic process records only")
        } catch {
            FileHandle.standardError.write(Data("FAIL origin verification: \(error)\n".utf8)); exit(1)
        }
    }
}
