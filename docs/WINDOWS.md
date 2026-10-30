# Native island windows

The window layer is AppKit NSPanel + NSHostingView, macOS 14+. It contains no provider or approval logic. Its interface is in WINDOW-CONTRACT.md.

## Current documentation check

On 2026-10-23, Context7 was queried outside the default sandbox: one `library AppKit` call, then two docs calls using `/websites/developer_apple_appkit` (Apple documentation, High source reputation). These confirmed:

- [nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel) does not activate the owning application.
- [becomesKeyOnlyIfNeeded](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded) and [needsPanelToBecomeKey](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey) distinguish nonactivating browsing from controls that require keyboard focus.
- [hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate) defaults true for NSPanel, so this implementation explicitly sets false.
- [safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets), [auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc), and [auxiliaryTopRightArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n) describe actual unobscured display areas and are available since macOS 12.
- [makeFirstResponder](https://developer.apple.com/documentation/appkit/nswindow/makefirstresponder(_:)) is the normal responder transition; forcing `endEditing(for:)` is a last resort and is not used here.

NSHostingView integration follows the existing platform notes and the SDK's typed API. Context7 did not return a complete NSHostingView/focus-restoration example in the three-call budget; the implementation is compiled against the installed SDK rather than presenting an unreturned example as documentation evidence.

## Window and screen behavior

- Each drawable NSScreen has an independent transparent borderless nonactivating panel.
- Default target is the built-in display, otherwise the first AppKit screen. Additional-display mode creates one per reported screen. `didChangeScreenParametersNotification` rebuilds this selection and recalculates geometry.
- A nonzero top safe-area inset plus auxiliaryTopLeftArea selects notch styling. No model-name, menu-bar-height, or hard-coded camera-height heuristic is used.
- Surfaces are horizontally centered. Capsule surfaces begin 6pt below the screen's top; notched surfaces touch the top. Screen coordinates account for negative origins and vertically arranged displays.
- The public `.statusBar` level and `.canJoinAllSpaces`, `.fullScreenAuxiliary`, and `.ignoresCycle` window behavior are requested. This does not promise visibility over lock screens, protected system windows, every third-party fullscreen experience, or all Stage Manager configurations.
- The native host leaves sufficient transparent animation space. The host height stays at 504pt (the 480pt surface cap plus a 24pt shadow margin) across idle, hover, expansion and collapse; the content view owns its visual animation. Width high-water retention still lasts 620ms after closing.

## Content-sized compact geometry

The compact island keeps the current source pets on the left and a color/count badge on the right. The window layer receives their measured widths, without owning session counts or interpreting status. Pet stacks use 20/35/50pt; badges use 24/30/36pt and disappear when no sessions are active.

The screen camera is measured from `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX`. Because the surface remains centered, the reserved camera width is twice the farther edge's distance from `screen.frame.midX`. This conservatively covers an asymmetric camera gap and works for screen coordinates with negative origins. Missing/unusable auxiliary bounds on a known notched screen fall back to 192pt. A non-notched screen reserves 0pt. Reconciliation recalculates these values on screen changes.

Minimum compact widths are:

- Notched: `notchWidth + 2 × (max(petStackWidth, badgeWidth) + 20)`.
- Capsule: `petStackWidth + badgeWidth + 20 + (badgeWidth > 0 ? 10 : 0)`.

For example, a simulated 120pt notch with one pet and a 24pt badge needs 208pt; three pets and a 36pt badge need 260pt. A capsule with one idle pet needs 40pt; one pet and a 24pt badge need 74pt. These are visible surface widths; the transparent animation host can be wider.

The default 100% width uses this minimum. The width slider is 100–130%; legacy values below 100% remain safe because context never shrinks beneath the camera/content minimum. Width remains capped at the screen's width minus 24pt. Height keeps the 32pt baseline and physical notch minimum. Hover adds only 12pt width and 3pt height, and both the view and hit path read the same context values.

`setCompactContentSize` ignores repeated identical measurements and notifies the coordinator only if compact geometry changes. `configure` recomputes metrics during screen reconciliation; the coordinator performs the resize in that existing pass. This avoids a measurement/resize feedback loop.

## Hover and mouse passthrough

Pointer location is sampled at 30Hz using `NSEvent.mouseLocation`, including when the panel ignores mouse events. A global keyboard monitor, event tap, Accessibility permission, or private window-server API is not required.

The visible surface has a shape-aware hit region: rounded capsule, or a notched body with 6pt compact / 19pt expanded shoulders and rounded bottom corners. `ignoresMouseEvents` is enabled outside it. NSHostingView also rejects transparent points in its own hitTest. The host's large animation rectangle is never intentionally treated as a full clickable rectangle.

The pointer sampler can lag a physical pointer crossing by up to one sampling interval. Native click-through must be checked on real desktop windows, especially at shoulder corners and during width/height animation; a SwiftUI screenshot is insufficient evidence. Content geometry must match `compactWidth/Height`, `expandedWidth`, and `contentHeight`, or the rendered surface and hit region can disagree.

Hover entry schedules expansion after 140ms. Hover exit checks again after 180ms and only closes a hover-opened surface without an editing pin or busy operation. Explicit click-opened surfaces remain until a deliberate collapse. Explicit opening or acquiring an editor pin cancels a pending hover transition, including an enter task scheduled before the click. The SwiftUI root can also forward onHover; repeated identical values are idempotent.

## Motion and retained canvas

`IslandMotion` centralizes the shape/presentation timings used by both the native host and SwiftUI: one 0.42s surface spring across hover, expansion and collapse, 0.045 surface bounce, and 0.22s compact hover. Content enters after a 0.035s delay over 0.20s and exits over 0.10s. These are design parameters; they do not imply a measured frame rate or a system-provided effect.

The transparent host reserves `max(590, expandedWidth, compactWidth + 12) + 48` points of width, capped by the display width minus 24pt. Height stays at `max(504, compactHeight + 3)` in every state. Resizing the hosting canvas on the first open can introduce an unintended whole-surface Y animation, so a smaller visual surface must not shrink its host height. Width high-water protection remains for 620ms after closing; quick out/in renews that protection. A normal display/provider reconciliation also respects the retention flag, so it cannot cut a closing animation short. Actual screen-width limits continue to apply during hot-plug.

Retained canvas space does not enlarge the click region. The shape-aware hit path still follows only the compact/expanded surface and its 12pt/3pt compact hover growth. Native checks remain necessary during shape transitions and at shoulder corners.

## Keyboard, editing lock, and focus

Pure hover never makes the panel key. Explicit `expand()`/`toggle()` requests key focus; `beginEditing(requestID:)` requests it and reserves the global editor lock. The NSPanel style remains nonactivating; no unconditional NSApp.activate is used.

If another screen owns editing, beginEditing returns false before changing keyboard focus. The UI shows the conflict message; window code does not cancel or move the other editor. The lock covers a screen, not just a request, so two screens cannot simultaneously edit unrelated requests either.

Collapse, Escape, endEditing, window removal, and coordinator stop release ownership. Provider drafts are outside the window module, so releasing a lock cannot erase a draft or send a decision. Busy status prevents accidental hover collapse but does not turn Escape into a provider cancellation.

The foreground application before key acquisition is remembered. On release, the panel resigns key and may activate that application if still running. It does not reactivate a stale application if the user has deliberately switched to a third application meanwhile. macOS ultimately controls responder and application activation behavior; this must be checked with actual text controls.

**Escape limitation:** an unfocused hover-opened panel does not receive Escape pressed in the previous application. This implementation deliberately does not globally capture Escape or request Accessibility permission. Escape is handled when the panel receives keyboard events after active clicking or input focus; cancelOperation uses the same collapse action.

## Verification

`scripts/verify-compact-window.sh` compiles the actual context with a small coordinator test double. Synthetic checks cover one/three-pet sizes, narrow percentages, idle capsules, repeated measurements, asymmetric/missing camera bounds, and changed display metrics. Bounded asynchronous checks cover cancelled entry, quick re-entry, explicit opening, editor ownership, busy protection and invalidation. They assert resulting state rather than guessed FPS; repeat the runner for timing regressions. They do not replace rendered or native hit testing.

Build checks verify SDK compatibility, not native interaction. The following require the assembled app and real desktop checks:

1. Underlying controls remain clickable outside the rounded visible body, in transparent shoulders, and beneath the retained close-animation canvas.
2. Hovering does not interrupt typing in the previous application; explicit input accepts text; Escape collapses and returns usable focus.
3. Two-screen editor acquisition returns false on the second screen without stealing focus; close/disconnect releases ownership.
4. Hot-plug, negative display origins, scaling, menu-bar behavior, fullscreen Spaces, and Stage Manager preserve expected placement.
5. Window teardown and app deactivation neither leave a blocking invisible panel nor erase provider drafts.

## Screen-top anchoring

The panel uses the status-bar window level, matching the reference application. `constrainFrameRect` preserves the explicitly calculated screen frame so AppKit does not push it below the menu bar. The hosting root ignores the screen safe-area inset; the island itself reserves the compact strip above expanded content. On a notched screen the window top equals `NSScreen.frame.maxY`; an unnotched screen retains the reference 6-point gap. This does not elevate the panel above lock screens or secure system UI.

The surface spring must keep the same duration through the compact-hover prelude and expansion. The 0.1.5 dynamic 0.30s/0.42s choice produced divergent frame and shape trajectories on a cold hover. `scripts/verify-motion.sh` observes the real view/window path using injected pointer coordinates and passive shell tracing; it compares normalized shell and geometry progress, not FPS. Production pointer input defaults to `NSEvent.mouseLocation`.

Version 0.1.7 also validates the absolute top edge of the real surface backing layer through `CALayer.presentation()`. The 0.1.6 cold path showed a 73pt root-relative Y jump while its shape interpolation test still passed. Keeping the hosting height fixed eliminated that jump in the controlled comparison. Presentation sampling is not display FPS measurement.
