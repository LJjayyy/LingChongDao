import AppKit
import SwiftUI

/// Shared macOS/iOS notification-row clearing. A horizontal drag tracks the
/// pointer, fades the row, and flies it out past the threshold (a quick fling
/// counts too); anything less springs back. Trackpad two-finger swipes arrive
/// as `scrollWheel` events and mouse users press-drag; both feed the same
/// state machine. `catchesMouse` marks rows whose whole surface is one target
/// (island rows): the AppKit catcher claims mouse events because a SwiftUI
/// Button swallows drags. Rows with inner buttons (workbench) keep SwiftUI
/// mouse routing and take mouse drags from a plain DragGesture instead. When
/// `showsCloseButton` is set, a macOS-notification-style gray × fades in at the
/// top-left corner while the row is hovered.
struct SwipeDismissRow<Content: View>: View {
    var reduceMotion: Bool
    var haptic: () -> Void
    var catchesMouse: Bool = true
    var tap: (() -> Void)?
    var showsCloseButton = false
    var dismiss: () -> Bool
    @ViewBuilder var content: () -> Content

    @ViewState private var offset: CGFloat = 0
    @ViewState private var alpha: CGFloat = 1
    @ViewState private var confirmed = false
    @ViewState private var flyingOut = false
    @ViewState private var scrollTranslation: CGFloat = 0
    @ViewState private var lastScrollDelta: CGFloat = 0
    @ViewState private var hovering = false
    @ViewState private var closeHover = false
    /// Verification harness only: render the × without a pointer.
    private var forceCloseVisible: Bool { ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_CLOSE_BUTTON"] == "1" }
    private var closeVisible: Bool { hovering || closeHover || forceCloseVisible }

    var body: some View {
        content()
            .overlay {
                RowGestureCatcher(catchesMouse: catchesMouse,
                                  onScrollBegin: { scrollTranslation = 0; lastScrollDelta = 0 },
                                  onScroll: { delta in
                                      guard !flyingOut else { return }
                                      scrollTranslation += delta
                                      lastScrollDelta = delta
                                      follow(Self.resisted(scrollTranslation))
                                  },
                                  onScrollEnd: {
                                      guard !flyingOut else { return }
                                      let fling = abs(lastScrollDelta) > 10
                                      scrollTranslation = 0; lastScrollDelta = 0
                                      settle(fling: fling)
                                  },
                                  onDrag: { translation in
                                      guard !flyingOut else { return }
                                      follow(Self.resisted(translation))
                                  },
                                  onDragEnd: { guard !flyingOut else { return }; settle(fling: false) },
                                  onTap: {
                                      guard !flyingOut else { return }
                                      tap?()
                                  })
            }
            .gesture(catchesMouse ? nil : dragGesture)
            .overlay(alignment: .topLeading) {
                if showsCloseButton {
                    // The 20-point circle is centered 4 points inside both
                    // card edges, overlapping the rounded corner like macOS.
                    NotificationCloseButton(action: performClose, onHover: { closeHover = $0 })
                        .offset(x: -6, y: -6)
                        .opacity(closeVisible ? 1 : 0)
                        .allowsHitTesting(closeVisible)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: closeVisible)
                }
            }
            .onHover { hovering = $0 }
            .opacity(alpha)
            .offset(x: offset)
            .accessibilityAction(named: Text("移除任务")) { performDismiss() }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !flyingOut else { return }
                follow(Self.resisted(value.translation.width))
            }
            .onEnded { value in
                guard !flyingOut else { return }
                let fling = abs(value.predictedEndTranslation.width) > IslandMotion.swipeFlingPrediction
                if abs(offset) > IslandMotion.swipeDismissThreshold || fling { performDismiss() }
                else { springBack() }
            }
    }

    private func follow(_ newOffset: CGFloat) {
        offset = newOffset
        alpha = max(0.35, 1 - abs(offset) / 320)
        let crossed = abs(offset) > IslandMotion.swipeDismissThreshold
        if crossed != confirmed { confirmed = crossed; if crossed { haptic() } }
    }

    private func settle(fling: Bool) {
        if abs(offset) > IslandMotion.swipeDismissThreshold || fling { performDismiss() }
        else { springBack() }
    }

    /// 1:1 tracking until the limit, then heavy resistance like iOS rubber-banding.
    private static func resisted(_ value: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        guard magnitude > IslandMotion.swipeDragLimit else { return value }
        let sign: CGFloat = value < 0 ? -1 : 1
        return sign * (IslandMotion.swipeDragLimit + (magnitude - IslandMotion.swipeDragLimit) * 0.22)
    }

    private func performDismiss() {
        guard !flyingOut else { return }
        flyingOut = true
        guard !reduceMotion else { _ = dismiss(); return }
        withAnimation(.easeOut(duration: IslandMotion.swipeFlyOutDuration)) {
            offset = (offset < 0 ? -1 : 1) * 560
            alpha = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(IslandMotion.swipeFlyOutDuration * 1000) - 30))
            guard !dismiss() else { return }
            flyingOut = false
            springBack()
        }
    }

    /// macOS close-button clearing: the row fades out in place, then leaves.
    private func performClose() {
        guard !flyingOut else { return }
        flyingOut = true
        guard !reduceMotion else { _ = dismiss(); return }
        withAnimation(.easeOut(duration: 0.16)) { alpha = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !dismiss() else { return }
            flyingOut = false
            springBack()
        }
    }

    private func springBack() {
        confirmed = false
        if reduceMotion { offset = 0; alpha = 1; return }
        withAnimation(.spring(duration: IslandMotion.hoverDuration, bounce: 0.14)) { offset = 0; alpha = 1 }
    }
}

/// macOS-notification-style gray ×. Faint circle chip, slightly darker while
/// hovered; the parent controls visibility with opacity and hit testing.
private struct NotificationCloseButton: View {
    var action: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; onHover($0) }
        .help("移除这个任务")
        .accessibilityLabel("移除任务")
    }
}

/// Transparent gesture surface over one row. `catchesMouse` rows claim mouse
/// events natively (mouse-down/drag/up plus trackpad two-finger swipes); the
/// rest answer `hitTest` only for scroll events so clicks, tooltips and
/// accessibility keep their SwiftUI routing. Vertical scrolling — and classic
/// mouse wheels — always forward to the enclosing list untouched.
struct RowGestureCatcher: NSViewRepresentable {
    var catchesMouse: Bool
    var onScrollBegin: () -> Void
    var onScroll: (CGFloat) -> Void
    var onScrollEnd: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    var onTap: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView(); apply(view); return view
    }
    func updateNSView(_ view: CatcherView, context: Context) { apply(view) }
    private func apply(_ view: CatcherView) {
        view.catchesMouse = catchesMouse
        view.onScrollBegin = onScrollBegin; view.onScroll = onScroll; view.onScrollEnd = onScrollEnd
        view.onDrag = onDrag; view.onDragEnd = onDragEnd; view.onTap = onTap
    }

    final class CatcherView: NSView {
        var catchesMouse = true
        var onScrollBegin: (() -> Void)?
        var onScroll: ((CGFloat) -> Void)?
        var onScrollEnd: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnd: (() -> Void)?
        var onTap: (() -> Void)?
        private var trackingHorizontal = false
        private var mouseStart: NSPoint?
        private var mouseDragging = false
        private static let dragActivation: CGFloat = 4
        private static let tapSlop: CGFloat = 5

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if catchesMouse { return self }
            guard let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            mouseStart = convert(event.locationInWindow, from: nil)
            mouseDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseStart else { return }
            let dx = convert(event.locationInWindow, from: nil).x - start.x
            if !mouseDragging, abs(dx) > Self.dragActivation { mouseDragging = true }
            if mouseDragging { onDrag?(dx) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseStart = nil; mouseDragging = false }
            guard let start = mouseStart else { return }
            let here = convert(event.locationInWindow, from: nil)
            if mouseDragging { onDragEnd?() }
            else if abs(here.x - start.x) <= Self.tapSlop, abs(here.y - start.y) <= Self.tapSlop { onTap?() }
        }

        override func scrollWheel(with event: NSEvent) {
            let live = event.phase == .began || event.phase == .changed || event.phase == .ended
            guard live, event.hasPreciseScrollingDeltas else { super.scrollWheel(with: event); return }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if event.phase == .began { trackingHorizontal = false; onScrollBegin?() }
            if !trackingHorizontal, abs(dx) >= abs(dy), abs(dx) >= 1 { trackingHorizontal = true }
            if trackingHorizontal {
                onScroll?(dx)
                if event.phase == .ended { trackingHorizontal = false; onScrollEnd?() }
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}
