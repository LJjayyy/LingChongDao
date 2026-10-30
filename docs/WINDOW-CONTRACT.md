# Native island window contract

Window implementation owns `Sources/LingChongDao/Windows/**`; app/model/views are owned by the parent thread. All APIs below are `@MainActor`. Target is macOS 14+.

```swift
final class IslandWindowCoordinator {
    init(content: @escaping (IslandWindowContext) -> AnyView)
    func start()
    func stop()
    func reconcile()
    func update(enabled: Bool, idleVisible: Bool,
                showOnOtherDisplays: Bool, hasSessions: Bool,
                widthPercent: Double, heightPercent: Double)
}

final class IslandWindowContext: ObservableObject {
    init(screenID: String, hasNotch: Bool, notchHeight: CGFloat,
         availableWidth: CGFloat, notchWidth: CGFloat = 0)
    let screenID: String
    @Published private(set) var hasNotch: Bool
    @Published private(set) var notchHeight: CGFloat
    @Published private(set) var notchWidth: CGFloat
    @Published private(set) var availableWidth: CGFloat
    @Published private(set) var compactWidth: CGFloat
    @Published private(set) var compactHeight: CGFloat
    @Published private(set) var expanded: Bool
    @Published private(set) var hovering: Bool
    @Published private(set) var expandedWidth: CGFloat
    @Published private(set) var contentHeight: CGFloat
    @Published private(set) var editingRequestID: String?
    @Published private(set) var busy: Bool

    func expand()
    func collapse()  // ends editing and restores prior application's focus
    func toggle()
    func setHovered(active: Bool, hasActivity: Bool) // IslandMotion: 140ms enter / 180ms leave
    func beginEditing(requestID: String) -> Bool // false if another screen owns input
    func endEditing()
    func setBusy(_ active: Bool)
    func setContentSize(width: CGFloat, height: CGFloat)
    func setContentHeight(_ height: CGFloat)
    func setCompactContentSize(leadingWidth: CGFloat, trailingWidth: CGFloat)
    func configure(hasNotch: Bool, notchHeight: CGFloat, availableWidth: CGFloat,
                   hasActivity: Bool, widthPercent: Double, heightPercent: Double,
                   notchWidth: CGFloat = 0)
}
```

Root content observes context with `@ObservedObject`. Root sets outer expanded width to 590 for notched or 552 for capsule; a pure running list uses 420. `setContentSize` reports the complete visible surface height, capped at 480. The 590 includes two 19pt shoulders around the 552pt body. Compact geometry comes from context and the view's content metrics. The view reports pet-stack width (20/35/50pt for one/two/three pets) and the fixed color/count badge width (24/30/36pt; 0 when idle) through `setCompactContentSize`. No status text is reserved in the compact surface. The minimum width is `notchWidth + 2 * (max(leadingWidth, trailingWidth) + 20)` on notched screens; otherwise it is `leadingWidth + trailingWidth + 20 + (trailingWidth > 0 ? 10 : 0)`. At 100% this is the narrowest safe width. Width percentages below 100% retain that safety minimum; 100–130% can enlarge it. The screen-width upper bound remains `max(1, availableWidth - 24)`. The compact height retains its 32pt baseline, 75–125% scale, and a physical notch-height minimum. Root must give its surface the reported compact/expanded size and top-align it; hosting viewport remains larger than the closed visual surface.

`notchWidth` comes from the two auxiliary top screen areas: twice the farther camera-edge distance from `screen.frame.midX` safely covers an asymmetric gap. A notched display missing usable auxiliary bounds uses 192pt. The default `notchWidth: 0` argument preserves older call sites while selecting this conservative fallback for notched contexts. Display reconciliation updates the width after hot-plug or changed screen geometry. Compact content measurements notify the coordinator only when the resulting geometry changes; `configure` leaves its geometry resize to the ongoing reconciliation instead of calling it recursively.

`IslandMotion` is the shared policy for host geometry and view animation: hover growth is 12pt × 3pt; entry waits 140ms and exit waits 180ms; all surface states use the same 0.42s spring with bounce 0.045 and blendDuration 0.08; hover animation is 0.22s; content enters after 0.035s over 0.20s and exits over 0.10s. The view constructs the animations and honors reduced motion.

Window code keeps a screen-limited canvas width of `max(590, expandedWidth, compactWidth + 12) + 48`, with a stable height of `max(504, compactHeight + 3)` in every state. The 504pt reservation covers the 480pt maximum surface plus a 24pt shadow margin. The host must not shrink vertically after collapse, because its next resize can animate the whole surface away from the top anchor. Each entry retains its width high-water dimensions through expansion and for 620ms after closing. Reconciliation uses that same retention state, so provider updates cannot prematurely crop a closing spring. Quick re-entry cancels or renews the release timer; screen-width bounds still apply. The canvas does not stretch the view to fill it. Expanded surface is horizontally centered, top anchored. Non-notch surface starts 6pt below the screen top. Window hit region follows the visible rounded body/shoulders; polling NSEvent.mouseLocation toggles ignoresMouseEvents without Accessibility permission. Context hover is also forwarded by this poll; root's `.onHover` may call the same API (idempotent).

Text input calls `beginEditing` before setting SwiftUI FocusState. It makes the nonactivating panel key, without calling NSApp.activate. Explicit `expand`/`toggle` also requests key focus, unless another screen owns editing; hover does not. `endEditing`, collapse, Escape and window teardown release the single global screen lock. Escape collapses when delivered to the panel through sendEvent/cancelOperation; it never submits/denies a source request. Unfocused hover panels do not globally intercept Escape. UI/model retains drafts separately from the window editing lock. Busy blocks hover collapse, not explicit Escape. Explicit open/editor pin cancels any pending hover transition so a delayed enter cannot convert a click-opened surface into hover ownership.

Coordinator starts disabled until the first update. `enabled && (hasSessions || idleVisible)` determines window existence. With additional displays off it prefers built-in, otherwise first screen; on it uses all reported drawable screens. Display changes reconcile windows. Screen geometry and safe-area APIs determine notch treatment. The public status-bar window level plus canJoinAllSpaces/fullScreenAuxiliary are used; system/lock-screen coverage is not promised.

No provider state, approvals, pet assets or business actions live in this module.
