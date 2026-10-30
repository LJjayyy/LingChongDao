import AppKit
import SwiftUI

@MainActor
final class IslandPanel: NSPanel {
    var acceptsKeyboard = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    // The island intentionally occupies the menu-bar / camera-housing strip.
    // AppKit's normal constraint would move a borderless panel below that strip.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// This also protects transparent hosting pixels between pointer-poll ticks.
@MainActor
final class IslandHostingView: NSHostingView<AnyView> {
    var acceptsPoint: ((NSPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let windowPoint = superview?.convert(point, to: nil) ?? convert(point, to: nil)
        guard acceptsPoint?(windowPoint) ?? true else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
struct IslandHostingRoot: View {
    @ObservedObject var context: IslandWindowContext
    let content: AnyView

    var body: some View {
        content
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
