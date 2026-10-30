// Render the current product views with synthetic task data. No real sessions
// or source settings are used. Run with render-showcase.sh in this directory.
import AppKit
import IslandConnections
import IslandCore
import SwiftUI

@MainActor
final class ReadmePowerGuard: ClamshellSleepGuardControlling {
    var isRunning: Bool { false }
    var needsRecovery: Bool { false }
    func start() async throws { throw ClamshellSleepGuardError.launchFailed }
    func stop() async -> Bool { true }
    func requestStop() {}
}

@main
struct ReadmeCapture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["README_FIXTURE_HOME"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let suite = "local.lingchongdao.readme." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.haptics = false
        let overview = AppModel(settings: settings, defaults: defaults)
        let question = AppModel(settings: settings, defaults: defaults)
        let idle = AppModel(settings: settings, defaults: defaults)
        let resources = output.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/build.noindex/灵宠岛.app/Contents/Resources")
        try prepareCodexFixture(at: fixture)
        let manager = ConnectionManager(environment: ConnectionEnvironment(
            homeDirectoryURL: fixture,
            applicationDirectories: [fixture.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")],
            executableSearchDirectories: [fixture.appendingPathComponent("bin")], detectCLIVersions: false,
            codexPluginSourceURL: resources.appendingPathComponent("LingChongDaoCodexPlugin"),
            dshPluginSourceURL: resources.appendingPathComponent("DshPlugin"),
            zcodePluginSourceURL: resources.appendingPathComponent("ZcodePlugin"),
            qoderPluginSourceURL: resources.appendingPathComponent("QoderPlugin"),
            claudePluginSourceURL: resources.appendingPathComponent("ClaudePlugin")))
        await manager.refresh()

        await event(overview, provider: .claude, application: .claudeDesktop, id: "homepage",
                    title: "给官网换个新首页", message: "正在调整排版与配色")
        await event(overview, provider: .qoder, application: .qoderIDE, id: "login",
                    title: "修复登录按钮", message: "正在检查边界情况")
        await event(overview, provider: .codex, application: .codexDesktop, id: "notes",
                    title: "整理本周更新", message: "更新说明已经整理好了")
        await event(overview, provider: .codex, application: .codexDesktop, id: "notes",
                    title: "整理本周更新", message: "更新说明已经整理好了", name: "TurnCompleted")
        let compact = context("compact")
        let expanded = context("expanded")
        expanded.expand()
        try await capture("overview.png", output: output, size: NSSize(width: 900, height: 490)) {
            ZStack(alignment: .top) {
                IslandView(model: overview, context: compact).scaleEffect(1.3, anchor: .top).padding(.top, 24)
                IslandView(model: overview, context: expanded).scaleEffect(1.5, anchor: .top).padding(.top, 96)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        await event(question, provider: .codex, application: .codexDesktop, id: "color",
                    title: "给官网换个新首页", message: "有个配色问题，想听听你的意见")
        _ = await question.handle(BridgeEnvelope(provider: .codex, raw: .object([
            "hook_event_name": .string("PreToolUse"), "session_id": .string("color"),
            "title": .string("给官网换个新首页"), "tool_use_id": .string("readme-color-question"),
            "tool_name": .string("request_user_input"),
            "tool_input": .object(["questions": .array([.object([
                "id": .string("color"), "question": .string("介绍页用暖色，还是清爽一点？"),
                "options": .array([.object(["label": .string("暖色")]), .object(["label": .string("清爽一点")])])
            ])])])
        ]), sourceApplication: .codexDesktop))
        let attention = context("attention")
        attention.expand()
        try await capture("attention.png", output: output, size: NSSize(width: 900, height: 270)) {
            IslandView(model: question, context: attention).scaleEffect(1.18, anchor: .top).padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        let encounter = context("encounter")
        encounter.setHovered(active: true, hasActivity: false)
        try await Task.sleep(for: .milliseconds(350))
        try await capture("boss-idle.png", output: output, size: NSSize(width: 900, height: 340)) {
            IslandView(model: idle, context: encounter).scaleEffect(1.5, anchor: .top).padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        try await capture("connections.png", output: output, size: NSSize(width: 900, height: 690)) {
            ScrollView { ConnectionsView(manager: manager).padding(28) }
                .font(.system(size: 13)).foregroundStyle(BossWorkbenchStyle.text)
                .tint(BossWorkbenchStyle.copperText).buttonStyle(BossButtonStyle())
        }
        compact.invalidate(); expanded.invalidate(); attention.invalidate(); encounter.invalidate()
        PetAppearanceStore.shared.stop()
        print("Captured four current product views with synthetic data")
    }

    @MainActor private static func context(_ id: String) -> IslandWindowContext {
        IslandWindowContext(screenID: id, hasNotch: true, notchHeight: 32,
                            availableWidth: 900, notchWidth: 160)
    }

    @MainActor private static func prepareCodexFixture(at fixture: URL) throws {
        // A tiny detected app + read-only CLI response gives the real service
        // its fresh-install state without invoking an installed agent CLI.
        let fm = FileManager.default
        let contents = fixture.appendingPathComponent("Applications/Codex.app/Contents")
        let bin = fixture.appendingPathComponent("bin")
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.openai.codex"]
        if let original = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
           let bundle = Bundle(url: original) {
            info["CFBundleShortVersionString"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
                let filename = iconName.contains(".") ? iconName : iconName + ".icns"
                let source = original.appendingPathComponent("Contents/Resources/" + filename)
                let target = contents.appendingPathComponent("Resources/" + filename)
                if fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                    info["CFBundleIconFile"] = filename
                }
            }
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let cli = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf '%s\\n' '{\"marketplaces\":[]}'\n".utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    @MainActor private static func event(_ model: AppModel, provider: ProviderID,
                                        application: SourceApplicationID, id: String,
                                        title: String, message: String, name: String = "UserPromptSubmit") async {
        _ = await model.handle(BridgeEnvelope(provider: provider, raw: .object([
            "hook_event_name": .string(name), "session_id": .string(id),
            "thread_id": .string("readme-" + id), "title": .string(title),
            "message": .string(message), "status": .string("completed"),
            "timestamp": .number(Date().timeIntervalSince1970)
        ]), sourceApplication: application))
    }

    @MainActor private static func capture<V: View>(_ name: String, output: URL, size: NSSize,
                                                   @ViewBuilder content: () -> V) async throws {
        let host = NSHostingView(rootView: content().frame(width: size.width, height: size.height)
            .background(Color(hex: 0xFAF8F4))
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(650))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        window.close()
        print("Rendered \(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
