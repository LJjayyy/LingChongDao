import AppKit
import SwiftUI
import CoreGraphics

@MainActor
final class IslandWindowCoordinator {
    private struct Settings {
        var enabled = false
        var idleVisible = true
        var showOnOtherDisplays = false
        var hasSessions = false
        var widthPercent: Double = 100
        var heightPercent: Double = 100
    }

    private final class Entry {
        let context: IslandWindowContext
        let panel: IslandPanel
        var screen: NSScreen
        var closeResizeTask: Task<Void, Never>?
        var retainedCanvasSize = NSSize.zero
        var retainsExpandedCanvas = false

        init(context: IslandWindowContext, panel: IslandPanel, screen: NSScreen) {
            self.context = context
            self.panel = panel
            self.screen = screen
        }
    }

    private let content: (IslandWindowContext) -> AnyView
    private let pointerLocation: () -> NSPoint
    private var settings = Settings()
    private var entries: [String: Entry] = [:]
    private var screenObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var started = false
    private var editingScreenID: String?
    private var keyboardScreenID: String?
    private var previousApplication: NSRunningApplication?

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         content: @escaping (IslandWindowContext) -> AnyView) {
        self.pointerLocation = pointerLocation
        self.content = content
    }

    func start() {
        guard !started else { return }
        started = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        if let pointerTimer { RunLoop.main.add(pointerTimer, forMode: .common) }
        reconcile()
    }

    func stop() {
        started = false
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for id in Array(entries.keys) { removeEntry(id) }
    }

    func update(enabled: Bool, idleVisible: Bool, showOnOtherDisplays: Bool,
                hasSessions: Bool, widthPercent: Double, heightPercent: Double) {
        settings = Settings(enabled: enabled, idleVisible: idleVisible,
                            showOnOtherDisplays: showOnOtherDisplays, hasSessions: hasSessions,
                            widthPercent: widthPercent, heightPercent: heightPercent)
        if !started { start() } else { reconcile() }
    }

    /// Announce sessions that need the user by opening the island on the active
    /// display, focused on those sessions only. No keyboard focus is requested,
    /// so the source app keeps typing focus.
    func revealCompletion(focusing: Set<String>) {
        guard settings.enabled else { return }
        let main = NSScreen.main
        let target = entries.values.first { $0.screen === main } ?? entries.values.first
        target?.context.revealCompletion(focusing: focusing)
        if ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_WINDOWS"] == "1" {
            let line = "LINGCHONGDAO_COMPLETION_REVEAL screen=\(target?.context.screenID ?? "none") expanded=\(target?.context.expanded ?? false) focus=\(focusing.count)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    func reconcile() {
        guard started else { return }
        let shouldShow = settings.enabled && (settings.hasSessions || settings.idleVisible)
        let screens = shouldShow ? targetScreens() : []
        let targetIDs = Set(screens.map(screenID))
        for id in Array(entries.keys) where !targetIDs.contains(id) { removeEntry(id) }
        for screen in screens {
            let id = screenID(screen)
            let hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
            let notchHeight = hasNotch ? screen.safeAreaInsets.top : 0
            let notchWidth = IslandWindowContext.measuredNotchWidth(screenFrame: screen.frame,
                auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea, hasNotch: hasNotch)
            let entry: Entry
            if let existing = entries[id] {
                entry = existing
                entry.screen = screen
            } else {
                let context = IslandWindowContext(screenID: id, hasNotch: hasNotch,
                                                   notchHeight: notchHeight, availableWidth: screen.frame.width, notchWidth: notchWidth)
                context.coordinator = self
                let panel = IslandPanel()
                entry = Entry(context: context, panel: panel, screen: screen)
                entries[id] = entry
                panel.onEscape = { [weak context] in context?.collapse() }
                let host = IslandHostingView(rootView: AnyView(IslandHostingRoot(context: context, content: content(context))))
                host.acceptsPoint = { [weak self, weak context] point in
                    guard let self, let context, let entry = self.entries[context.screenID] else { return false }
                    return self.hitPath(for: entry).contains(point)
                }
                panel.contentView = host
            }
            entry.context.configure(hasNotch: hasNotch, notchHeight: notchHeight,
                                    availableWidth: screen.frame.width, hasActivity: settings.hasSessions,
                                    widthPercent: settings.widthPercent, heightPercent: settings.heightPercent, notchWidth: notchWidth)
            resize(entry)
            entry.panel.orderFrontRegardless()
            if ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_WINDOWS"] == "1" {
                let delta = screen.frame.maxY - entry.panel.frame.maxY
                let line = "LINGCHONGDAO_WINDOW notch=\(hasNotch) topGap=\(delta) level=\(entry.panel.level.rawValue) expanded=\(entry.context.expanded)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        pollPointer()
    }

    func contextGeometryDidChange(_ context: IslandWindowContext) {
        guard let entry = entries[context.screenID] else { return }
        entry.closeResizeTask?.cancel()
        entry.closeResizeTask = nil
        if context.expanded {
            entry.retainsExpandedCanvas = true
            resize(entry)
        } else if entry.retainsExpandedCanvas {
            // Keep the high-water canvas through closing and quick out/in reversals.
            // reconcile() uses the same retained dimensions, so an unrelated provider
            // update cannot crop a spring while this delayed release is pending.
            resize(entry)
            entry.closeResizeTask = Task { [weak self, weak entry] in
                try? await Task.sleep(for: IslandMotion.canvasReleaseDelay)
                guard !Task.isCancelled, let self, let entry, !entry.context.expanded else { return }
                entry.retainsExpandedCanvas = false
                entry.closeResizeTask = nil
                self.resize(entry)
                self.updateMousePassthrough(entry)
            }
        } else {
            resize(entry)
        }
        updateMousePassthrough(entry)
    }

    func requestEditing(for context: IslandWindowContext) -> Bool {
        guard editingScreenID == nil || editingScreenID == context.screenID,
              let entry = entries[context.screenID] else { return false }
        guard requestKeyboardFocus(for: context) else { return false }
        editingScreenID = context.screenID
        entry.panel.ignoresMouseEvents = false
        return true
    }

    @discardableResult
    func requestKeyboardFocus(for context: IslandWindowContext) -> Bool {
        guard editingScreenID == nil || editingScreenID == context.screenID,
              let entry = entries[context.screenID] else { return false }
        if keyboardScreenID == nil {
            let front = NSWorkspace.shared.frontmostApplication
            previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        if let previousID = keyboardScreenID, previousID != context.screenID {
            entries[previousID]?.panel.acceptsKeyboard = false
        }
        keyboardScreenID = context.screenID
        entry.panel.acceptsKeyboard = true
        entry.panel.makeKeyAndOrderFront(nil)
        return true
    }

    func releaseEditing(for context: IslandWindowContext) {
        guard editingScreenID == context.screenID else { return }
        editingScreenID = nil
        releaseKeyboardFocus(for: context)
    }

    func releaseKeyboardFocus(for context: IslandWindowContext) {
        guard keyboardScreenID == context.screenID else { return }
        keyboardScreenID = nil
        let entry = entries[context.screenID]
        let ownedKeyFocus = entry?.panel.isKeyWindow ?? false
        entry?.panel.acceptsKeyboard = false
        if ownedKeyFocus { entry?.panel.resignKey() }
        let front = NSWorkspace.shared.frontmostApplication
        // Never pull focus back from an application the user switched to meanwhile.
        if ownedKeyFocus, let previousApplication, !previousApplication.isTerminated,
           front == nil || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || front?.processIdentifier == previousApplication.processIdentifier {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }

    private func removeEntry(_ id: String) {
        guard let entry = entries[id] else { return }
        entry.closeResizeTask?.cancel()
        entry.context.invalidate()
        releaseKeyboardFocus(for: entry.context)
        entry.panel.orderOut(nil)
        entry.panel.close()
        entries.removeValue(forKey: id)
    }

    private func targetScreens() -> [NSScreen] {
        // AppKit returns drawable screens rather than one independent surface per mirrored output.
        let screens = NSScreen.screens
        if settings.showOnOtherDisplays { return screens }
        let preferred = screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        } ?? screens.first
        return preferred.map { [$0] } ?? []
    }

    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? "screen-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
    }

    private func resize(_ entry: Entry) {
        let context = entry.context
        let screenWidth = max(1, entry.screen.frame.width - 24)
        let desiredWidth = min(max(590, max(context.expandedWidth, context.compactWidth + IslandMotion.hoverWidth)) + 48, screenWidth)
        let desiredHeight = max(IslandMotion.canvasHeight, context.compactHeight + IslandMotion.hoverHeight)
        let viewportWidth = entry.retainsExpandedCanvas ? min(max(entry.retainedCanvasSize.width, desiredWidth), screenWidth) : desiredWidth
        let viewportHeight = entry.retainsExpandedCanvas ? max(entry.retainedCanvasSize.height, desiredHeight) : desiredHeight
        entry.retainedCanvasSize = NSSize(width: viewportWidth, height: viewportHeight)
        let topGap: CGFloat = context.hasNotch ? 0 : 6
        let frame = NSRect(x: entry.screen.frame.midX - viewportWidth / 2,
                           y: entry.screen.frame.maxY - topGap - viewportHeight,
                           width: viewportWidth, height: viewportHeight)
        if entry.panel.frame != frame { entry.panel.setFrame(frame, display: true) }
    }

    private func pollPointer() {
        for entry in entries.values {
            updateMousePassthrough(entry)
        }
    }

    private func updateMousePassthrough(_ entry: Entry) {
        let local = entry.panel.convertPoint(fromScreen: pointerLocation())
        let inside = hitPath(for: entry).contains(local)
        entry.panel.ignoresMouseEvents = !inside
        entry.context.setHovered(active: inside, hasActivity: settings.hasSessions)
    }

    /// Coordinates are in the unflipped window coordinate system, including shoulders.
    private func hitPath(for entry: Entry) -> NSBezierPath {
        let context = entry.context
        let hoverGrow = context.hovering && !context.expanded
        let width = context.expanded ? context.expandedWidth : context.compactWidth + (hoverGrow ? IslandMotion.hoverWidth : 0)
        let height = context.expanded ? context.contentHeight : context.compactHeight + (hoverGrow ? IslandMotion.hoverHeight : 0)
        let rect = NSRect(x: (entry.panel.frame.width - width) / 2,
                          y: entry.panel.frame.height - height, width: width, height: height)
        guard context.hasNotch else {
            let radius: CGFloat = context.expanded ? 24 : 16
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        let shoulder: CGFloat = min(context.expanded ? 19 : 6, width / 4)
        let radius: CGFloat = min(context.expanded ? 24 : 14, max(0, height - shoulder))
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let top = rect.maxY
        let bottom = rect.minY
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: top))
        path.line(to: NSPoint(x: rect.maxX, y: top))
        path.curve(to: NSPoint(x: right, y: top - shoulder),
                   controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
        path.line(to: NSPoint(x: right, y: bottom + radius))
        path.curve(to: NSPoint(x: right - radius, y: bottom),
                   controlPoint1: NSPoint(x: right, y: bottom + radius / 3),
                   controlPoint2: NSPoint(x: right - radius / 3, y: bottom))
        path.line(to: NSPoint(x: left + radius, y: bottom))
        path.curve(to: NSPoint(x: left, y: bottom + radius),
                   controlPoint1: NSPoint(x: left + radius / 3, y: bottom),
                   controlPoint2: NSPoint(x: left, y: bottom + radius / 3))
        path.line(to: NSPoint(x: left, y: top - shoulder))
        path.curve(to: NSPoint(x: rect.minX, y: top),
                   controlPoint1: NSPoint(x: left, y: top), controlPoint2: NSPoint(x: left, y: top))
        path.close()
        return path
    }
}
