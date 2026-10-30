import AppKit
import Combine
import IslandConnections
import IslandCore
import SwiftUI

@main
struct LingChongDaoMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let isolated = CommandLine.arguments.contains("--isolated")
        if !isolated {
            let identifiers = [RuntimeIdentityMigration.bundleIdentifier, RuntimeIdentityMigration.legacyBundleIdentifier]
            let others = identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [.activateAllWindows])
                let alert = NSAlert()
                alert.messageText = "灵宠岛已在运行"
                alert.informativeText = "请先退出当前版本，再启动新版本，以安全迁移连接与设置。"
                alert.runModal()
                return
            }
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                try RuntimeIdentityMigration.migrateSupport(in: support)
                RuntimeIdentityMigration.migratePreferences()
            } catch {
                let alert = NSAlert()
                alert.messageText = "灵宠岛数据迁移未完成"
                alert.informativeText = error.localizedDescription + "\n原有数据已保留，应用未启动本地连接。"
                alert.runModal()
                return
            }
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let settings: AppSettings
    private let keepAwake = KeepAwakeController.shared
    private let model: AppModel
    private let connections: ConnectionManager
    private let bridgeSocketPath: String
    private let isolatedRoot: URL?
    private var coordinator: IslandWindowCoordinator!
    private var statusItem: NSStatusItem!
    private var workbench: NSWindow?
    private var terminationPending = false
    private var sourceAttention: SourceAttentionMonitor?
    private var revealTracker = AttentionRevealTracker()
    private var cancellables = Set<AnyCancellable>()
    private let preview: String?

    override init() {
        let args = CommandLine.arguments
        let previewIndex = args.firstIndex(of: "--preview")
        preview = previewIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let defaults: UserDefaults
        if args.contains("--isolated") {
            let root = URL(fileURLWithPath: "/private/tmp/lingchongdao-preview-" + UUID().uuidString, isDirectory: true)
            isolatedRoot = root
            defaults = UserDefaults(suiteName: "local.lingchongdao.preview." + UUID().uuidString)!
            let environment = ConnectionEnvironment(homeDirectoryURL: root,
                applicationSupportURL: root.appendingPathComponent("support"),
                helperSourceURL: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lingchongdao-hook"),
                detectCLIVersions: false)
            connections = ConnectionManager(environment: environment)
            bridgeSocketPath = environment.socketPath
        } else {
            isolatedRoot = nil
            defaults = .standard
            connections = ConnectionManager()
            bridgeSocketPath = IslandCore.BridgePaths.defaultSocketPath
        }
        settings = AppSettings(defaults: defaults)
        model = AppModel(settings: settings, defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetAppearanceStore.shared.start()
        coordinator = IslandWindowCoordinator { [weak self] context in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(IslandView(model: self.model, context: context))
        }
        model.openWorkbench = { [weak self] in self?.showWorkbench() }
        model.onProviderEvent = { [weak self] provider, at in self?.connections.recordEvent(provider: provider, at: at) }
        model.startBridge(socketPath: bridgeSocketPath)
        sourceAttention = SourceAttentionMonitor(model: model)
        sourceAttention?.start()
        if let preview { settings.enabled = true; model.loadPreview(preview) }
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.makeImage()
        statusItem.button?.setAccessibilityLabel("灵宠岛")
        let menu = NSMenu()
        addMenu("打开工作台", action: #selector(openWorkbench), key: "o", menu: menu)
        addMenu("显示灵宠岛", action: #selector(toggleIsland), menu: menu)
        addMenu("保持唤醒", action: #selector(toggleKeepAwake), menu: menu)
        menu.addItem(.separator())
        addMenu("检查连接", action: #selector(refreshConnections), menu: menu)
        addMenu("退出 灵宠岛", action: #selector(quit), key: "q", menu: menu)
        statusItem.menu = menu
        settings.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateWindows() } }.store(in: &cancellables)
        keepAwake.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateWindows() } }.store(in: &cancellables)
        model.$sessions.sink { [weak self] sessions in
            DispatchQueue.main.async {
                self?.updateWindows()
                self?.announceAttentionSessions(sessions)
            }
        }.store(in: &cancellables)
        updateWindows()
        Task { await connections.refresh() }
        if !CommandLine.arguments.contains("--background") { showWorkbench() }
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "灵宠岛")
        addMenu("打开工作台", action: #selector(openWorkbench), key: "o", menu: applicationMenu)
        addMenu("保持唤醒", action: #selector(toggleKeepAwake), menu: applicationMenu)
        applicationMenu.addItem(.separator())
        addMenu("退出 灵宠岛", action: #selector(quit), key: "q", menu: applicationMenu)
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                       ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func addMenu(_ title: String, action: Selector, key: String = "", menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func updateWindows() {
        coordinator.update(enabled: settings.enabled, idleVisible: settings.idleVisible,
            showOnOtherDisplays: settings.additionalDisplays, hasSessions: !model.visibleSessions.isEmpty,
            widthPercent: settings.widthPercent, heightPercent: settings.heightPercent)
        statusItem?.menu?.items.first(where: { $0.action == #selector(toggleIsland) })?.state = settings.enabled ? .on : .off
        updateKeepAwakeMenu(statusItem?.menu)
        updateKeepAwakeMenu(NSApp.mainMenu)
    }

    /// Pull the island down without pointer or keyboard focus whenever a session
    /// enters a state that needs the user: an approval or question waiting for an
    /// answer, an ended turn whose result awaits review, or a completion, failure
    /// or interruption. The reveal focuses on those sessions only — running work
    /// stays hidden until the surface is opened again by the user. Attention
    /// tracking stays independent of the setting so toggling it on cannot replay
    /// stale states as new.
    private func announceAttentionSessions(_ sessions: [IslandSession]) {
        let announcement = revealTracker.ingest(sessions)
        guard settings.autoRevealOnFinish, !model.demoMode, announcement.hasNewAnnouncement else { return }
        coordinator.revealCompletion(focusing: announcement.attentionSessionIDs)
    }
    private func updateKeepAwakeMenu(_ menu: NSMenu?) {
        for item in menu?.items ?? [] {
            if item.action == #selector(toggleKeepAwake) {
                item.state = keepAwake.isEnabled ? .on : .off
                item.title = keepAwake.isChanging ? keepAwake.actionTitle : (keepAwake.state == .partial ? "重试恢复休眠" : "保持唤醒（含合盖）")
                item.isEnabled = !keepAwake.isChanging
            }
            updateKeepAwakeMenu(item.submenu)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(toggleKeepAwake) || !keepAwake.isChanging
    }
    @objc private func toggleKeepAwake() { keepAwake.toggle() }
    @objc private func openWorkbench() { showWorkbench() }
    @objc private func toggleIsland() { settings.enabled.toggle() }
    @objc private func refreshConnections() { Task { await connections.refresh() } }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWorkbench(); return true }
    private func showWorkbench() {
        // The workbench behaves like a normal app; the island alone stays a menu bar utility.
        NSApp.setActivationPolicy(.regular)
        if let workbench { workbench.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "灵宠岛"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 850, height: 650)
        window.contentView = NSHostingView(rootView: WorkbenchView(model: model, settings: settings, connections: connections))
        window.delegate = self; window.center(); workbench = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === workbench else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard keepAwake.isEnabled || keepAwake.isChanging else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { [weak self] in
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            let restored = await self.keepAwake.stopBeforeTermination()
            self.terminationPending = false
            if !restored { self.showWorkbench() }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { keepAwake.requestStopForTermination(); sourceAttention?.stop(); coordinator?.stop(); model.stopBridge(); PetAppearanceStore.shared.stop(); if let isolatedRoot { try? FileManager.default.removeItem(at: isolatedRoot) } }
}
