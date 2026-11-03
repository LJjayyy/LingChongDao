import AppKit
import Foundation

// The real context owns all geometry. This double records only its coordinator seam;
// tests never inspect private state with Mirror or duplicate its sizing implementation.
@MainActor
final class IslandWindowCoordinator {
    var geometryChanges = 0
    var keyboardFocusRequests = 0
    var editingReleases = 0
    var allowsEditing = true
    func contextGeometryDidChange(_ context: IslandWindowContext) { geometryChanges += 1 }
    @discardableResult func requestKeyboardFocus(for context: IslandWindowContext) -> Bool { keyboardFocusRequests += 1; return true }
    func releaseKeyboardFocus(for context: IslandWindowContext) {}
    func requestEditing(for context: IslandWindowContext) -> Bool { allowsEditing }
    func releaseEditing(for context: IslandWindowContext) { editingReleases += 1 }
}

private enum CheckError: Error { case failed(String) }

@main
struct CompactWindowVerification {
    @MainActor
    static func main() async {
        var checks = 0
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw CheckError.failed(message) }
            checks += 1
        }
        func waitForExpansion(_ context: IslandWindowContext, _ expanded: Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(2)
            while context.expanded != expanded && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard context.expanded == expanded else {
                throw CheckError.failed("\(context.screenID) did not reach expanded=\(expanded) within two seconds")
            }
        }
        do {
            var scroll = IslandScrollCollapseGesture()
            func move(_ x: CGFloat = 0, _ up: CGFloat, phase: IslandScrollCollapseGesture.Phase = .changed,
                      precise: Bool = true, momentum: Bool = false, eligible: Bool = true, time: TimeInterval = 1) -> Bool {
                scroll.consume(deltaX: x, upwardDelta: up, precise: precise, phase: phase,
                               momentum: momentum, timestamp: time, canCollapse: eligible)
            }
            try require(!move(0, 10, phase: .began) && !move(0, 16)
                        && move(0, 0, phase: .ended), "trackpad upward travel commits only when the fingers lift")
            try require(!move(0, 30, phase: .ended), "a repeated terminal event cannot collapse a second surface")
            try require(!move(0, -40, phase: .began) && !move(0, 0, phase: .ended), "downward scrolling does not collapse")
            try require(!move(30, 2, phase: .began) && !move(0, 50)
                        && !move(0, 0, phase: .ended), "horizontal row swipes keep ownership through diagonal tails")
            try require(!move(0, 40, phase: .began, momentum: true)
                        && !move(0, 30, phase: .ended, momentum: true), "inertial scrolling cannot initiate collapse")
            try require(!move(0, 20, phase: .began, eligible: false) && !move(0, 40)
                        && !move(0, 0, phase: .ended),
                        "a gesture begun in scrollable content cannot become a collapse after crossing the header")
            try require(!move(0, 20, phase: .began, eligible: false, time: 1)
                        && !move(0, 40, time: 2) && !move(0, 0, phase: .ended, time: 2.1),
                        "a pause in a phased gesture cannot acquire collapse ownership after leaving scrollable content")
            try require(!move(0, 40, phase: .began) && !move(0, 0, phase: .cancelled), "cancelled gestures never collapse after crossing the threshold")
            try require(!move(0, 40, phase: .began) && !move(0, -30)
                        && !move(0, 0, phase: .ended), "pulling an upward swipe back keeps the island open")
            try require(!move(0, 60, phase: .began) && !move(0, -30)
                        && !move(0, 0, phase: .ended), "a deliberate reversal cancels even when net travel remains above the threshold")
            try require(!move(0, 40, phase: .began) && !move(0, -10) && !move(0, 50)
                        && !move(0, 0, phase: .ended), "a cancelled touch stays cancelled until a fresh gesture")
            try require(!move(0, 40, phase: .began) && !move(0, -4)
                        && move(0, 0, phase: .ended), "small trackpad jitter does not cancel an intentional swipe")
            try require(!move(0, 10, phase: .began) && !move(0, 0, phase: .ended), "short upward swipes stay expanded on release")
            try require(!move(0, 0, phase: .began) && move(0, 30, phase: .ended), "the terminal event contributes its final travel")
            try require(!move(0, 1, phase: .unphased, precise: false, time: 2)
                        && move(0, 2, phase: .unphased, precise: false, time: 2.1), "classic mouse wheels accumulate across adjacent ticks")
            try require(!move(0, 1, phase: .unphased, precise: false, time: 3)
                        && !move(0, 2, phase: .unphased, precise: false, time: 4), "isolated wheel ticks do not accumulate indefinitely")

            let putAway = IslandWindowContext(screenID: "scroll-collapse", hasNotch: false, notchHeight: 0, availableWidth: 1920)
            putAway.setHovered(active: true, hasActivity: true)
            putAway.revealCompletion(focusing: ["unread-message"])
            putAway.collapseTemporarily()
            try require(!putAway.expanded && putAway.attentionFocus == nil, "temporary collapse closes an automatic reveal and releases its presentation focus")
            putAway.setHovered(active: true, hasActivity: false)
            putAway.setHovered(active: true, hasActivity: true)
            try await Task.sleep(for: IslandMotion.idleEncounterEnterDelay + .milliseconds(45))
            try require(!putAway.expanded, "activity updates under the same pointer cannot undo a temporary collapse")
            putAway.setHovered(active: false, hasActivity: true)
            putAway.setHovered(active: true, hasActivity: true)
            try await waitForExpansion(putAway, true)
            putAway.collapseTemporarily()
            putAway.expand()
            try require(putAway.expanded, "an explicit click can reopen immediately after a temporary collapse")
            putAway.collapseTemporarily()
            putAway.revealCompletion(focusing: ["new-message"])
            try require(putAway.expanded && putAway.attentionFocus == ["new-message"], "a genuinely new announcement can still reveal after a temporary collapse")
            putAway.setBusy(true)
            putAway.collapseTemporarily()
            try require(putAway.expanded && putAway.busy, "a gesture cannot interrupt an in-flight action")
            putAway.setBusy(false)

            // Send a real AppKit scroll event through the actual panel dispatch
            // hook, before any hosted row/scroll view can consume it.
            _ = NSApplication.shared
            let panel = IslandPanel()
            let wheelCG = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0)!
            let wheel = NSEvent(cgEvent: wheelCG)!
            var routedScrolls = 0
            panel.onScrollCollapse = { event in
                routedScrolls += 1
                return putAway.handleScrollCollapse(event, inHeader: true)
            }
            panel.sendEvent(wheel)
            try require(routedScrolls == 1 && !putAway.expanded, "NSPanel.sendEvent routes upward wheel input to presentation-only collapse")
            putAway.setContentSize(width: 552, height: 700)
            putAway.expand()
            try require(!putAway.handleScrollCollapse(wheel, inHeader: false) && putAway.expanded,
                        "long content keeps native vertical scrolling in its body")
            // A fresh event sequence in the header remains available even when
            // long content is present, without scrolling or clearing a row.
            wheelCG.timestamp += 1_000_000_000
            let laterWheel = NSEvent(cgEvent: wheelCG)!
            try require(putAway.handleScrollCollapse(laterWheel, inHeader: true) && !putAway.expanded,
                        "the header can put away an island containing scrollable content")
            putAway.expand()
            putAway.setContentSize(width: 552, height: 200)
            let trackpadCG = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)!
            trackpadCG.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
            trackpadCG.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
            let momentum = NSEvent(cgEvent: trackpadCG)!
            try require(momentum.hasPreciseScrollingDeltas && !momentum.momentumPhase.isEmpty
                        && !putAway.handleScrollCollapse(momentum, inHeader: false) && putAway.expanded,
                        "real precise AppKit momentum flags preserve the expanded island")
            trackpadCG.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            trackpadCG.setIntegerValueField(.scrollWheelEventScrollPhase, value: 8)
            let cancelled = NSEvent(cgEvent: trackpadCG)!
            try require(cancelled.phase.contains(.cancelled)
                        && !putAway.handleScrollCollapse(cancelled, inHeader: false) && putAway.expanded,
                        "real AppKit cancellation flags cannot commit a collapse")
            trackpadCG.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
            let preciseScroll = NSEvent(cgEvent: trackpadCG)!
            try require(preciseScroll.phase.contains(.began) && preciseScroll.hasPreciseScrollingDeltas
                        && putAway.handleScrollCollapse(preciseScroll, inHeader: false) && putAway.expanded,
                        "real precise AppKit begin flags keep a threshold-crossing swipe reversible")
            func trackpadEvent(_ delta: Int32, phase: Int64) -> NSEvent {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: delta, wheel2: 0, wheel3: 0)!
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                return NSEvent(cgEvent: event)!
            }
            try require(putAway.isScrollCollapseActive && putAway.scrollCollapseProgress > 0
                        && putAway.surfaceWidth < putAway.expandedWidth
                        && putAway.surfaceHeight < putAway.contentHeight,
                        "trackpad movement shrinks the surface before release without marking it closed")
            let beforePullBack = putAway.surfaceHeight
            putAway.setHovered(active: false, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(40))
            try require(putAway.expanded && putAway.isScrollCollapseActive,
                        "shrinking away from the pointer cannot trigger hover exit while tracking")
            let pullBack = trackpadEvent(-30, phase: 2)
            let lift = trackpadEvent(0, phase: 4)
            try require(pullBack.phase.contains(.changed) && lift.phase.contains(.ended),
                        "synthetic AppKit events expose real change and release phases")
            panel.sendEvent(pullBack)
            try require(putAway.isScrollCollapseActive && putAway.surfaceHeight > beforePullBack,
                        "pulling back visibly expands the surface during the same gesture")
            panel.sendEvent(lift)
            try require(!putAway.isScrollCollapseActive && putAway.scrollCollapseProgress == 0
                        && putAway.surfaceHeight == putAway.contentHeight,
                        "releasing a reversed gesture restores the full surface target")
            try require(putAway.expanded, "the panel keeps the island open after an upward swipe is pulled back before release")
            panel.sendEvent(trackpadEvent(40, phase: 1))
            try require(putAway.expanded, "a fresh upward swipe still waits for release at the actual panel entry")
            panel.sendEvent(trackpadEvent(0, phase: 4))
            try require(!putAway.expanded, "lifting after a fresh deliberate upward swipe closes through the actual panel entry")
            putAway.expand()
            panel.sendEvent(trackpadEvent(10, phase: 1))
            try require(putAway.isScrollCollapseActive && putAway.scrollCollapseProgress > 0,
                        "a short upward touch supplies partial progress")
            panel.sendEvent(lift)
            try require(putAway.expanded && !putAway.isScrollCollapseActive && putAway.scrollCollapseProgress == 0,
                        "an insufficient upward touch springs back on release")
            panel.sendEvent(trackpadEvent(80, phase: 1))
            panel.sendEvent(trackpadEvent(0, phase: 8))
            try require(putAway.expanded && !putAway.isScrollCollapseActive && putAway.scrollCollapseProgress == 0,
                        "system cancellation clears partial progress and retains the open island")
            panel.sendEvent(trackpadEvent(80, phase: 1))
            putAway.collapse()
            putAway.expand()
            panel.sendEvent(lift)
            try require(putAway.expanded && putAway.scrollCollapseProgress == 0,
                        "an explicit state change cancels an old gesture before reopening")
            panel.close()
            putAway.invalidate()

            let context = IslandWindowContext(screenID: "synthetic", hasNotch: true, notchHeight: 38, availableWidth: 1512, notchWidth: 120)
            let coordinator = IslandWindowCoordinator()
            context.coordinator = coordinator
            context.setCompactContentSize(leadingWidth: 20, trailingWidth: 24)
            try require(context.compactWidth == 208, "one pet plus badge reserves camera-safe wings")
            try require(coordinator.geometryChanges == 1, "changed measurement notifies once")
            context.setCompactContentSize(leadingWidth: 20, trailingWidth: 24)
            try require(coordinator.geometryChanges == 1, "repeated measurement does not notify recursively")
            context.setCompactContentSize(leadingWidth: 50, trailingWidth: 36)
            try require(context.compactWidth == 260, "three pets plus badge remain compact")
            context.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true, widthPercent: 20, heightPercent: 75, notchWidth: 120)
            try require(context.compactWidth == 260 && context.compactWidth - context.notchWidth >= 140,
                        "twenty percent cannot cover pets or camera")
            try require(context.compactHeight == 38, "notch height remains the minimum")
            context.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true, widthPercent: 130, heightPercent: 125, notchWidth: 120)
            try require(abs(context.compactWidth - 338) < 0.001 && context.compactHeight == 40,
                        "percentages can enlarge the safe compact dimensions")
            context.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true, widthPercent: 100, heightPercent: 100, notchWidth: 200)
            try require(context.notchWidth == 200 && context.compactWidth == 340,
                        "display geometry update replaces the old camera width")
            context.configure(hasNotch: false, notchHeight: 0, availableWidth: 1920, hasActivity: true, widthPercent: 100, heightPercent: 100, notchWidth: 200)
            try require(context.notchWidth == 0 && context.compactWidth == 116,
                        "hot-plug to a capsule removes the camera reservation")
            context.setCompactContentSize(leadingWidth: 20, trailingWidth: 0)
            try require(context.compactWidth == 40 && context.compactHeight == 32,
                        "external idle island uses the smallest one-pet capsule")
            context.setCompactContentSize(leadingWidth: 20, trailingWidth: 24)
            context.configure(hasNotch: false, notchHeight: 0, availableWidth: 1920, hasActivity: true, widthPercent: 20, heightPercent: 100)
            try require(context.compactWidth == 74, "small width percentage preserves capsule pet and badge")
            context.setCompactContentSize(leadingWidth: 50, trailingWidth: 36)
            context.configure(hasNotch: false, notchHeight: 0, availableWidth: 100, hasActivity: true, widthPercent: 130, heightPercent: 100)
            try require(context.compactWidth == 76, "screen width remains the absolute upper bound")
            let badges = IslandWindowContext(screenID: "multi-badge", hasNotch: true, notchHeight: 38, availableWidth: 1512, notchWidth: 192)
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 136)
            try require(badges.compactWidth == 504, "all five one-digit statuses fit outside the centered camera")
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 196)
            try require(badges.compactWidth == 624, "all five 99+ badges reserve their full widths and gaps")
            badges.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true, widthPercent: 130, heightPercent: 100, notchWidth: 192)
            try require(abs(badges.compactWidth - 811.2) < 0.001, "large preference keeps five statuses camera-safe")
            badges.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true, widthPercent: 20, heightPercent: 100, notchWidth: 192)
            try require(badges.compactWidth == 624, "small preference never clips nonzero status groups")
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 52)
            try require(badges.compactWidth == 336, "two single-digit statuses shrink back after other groups disappear")
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 58)
            try require(badges.compactWidth == 348, "nine-to-ten digit change reserves the extra badge width")
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 64)
            try require(badges.compactWidth == 360, "99+ display reserves its third character")
            badges.setCompactContentSize(leadingWidth: 20, trailingWidth: 24)
            try require(badges.compactWidth == 280, "five-to-one status transition releases unused badge space")
            badges.setCompactContentSize(leadingWidth: 20, trailingWidth: 0)
            try require(badges.compactWidth == 272, "zero statuses restore the idle camera-safe island")
            badges.configure(hasNotch: false, notchHeight: 0, availableWidth: 1920, hasActivity: true, widthPercent: 100, heightPercent: 100)
            badges.setCompactContentSize(leadingWidth: 50, trailingWidth: 196)
            try require(badges.compactWidth == 276, "external capsule fits all five badges without symmetric camera wings")
            badges.configure(hasNotch: false, notchHeight: 0, availableWidth: 240, hasActivity: true, widthPercent: 130, heightPercent: 100)
            try require(badges.compactWidth == 216, "screen width remains the absolute cap for multiple badges")
            let legacy = IslandWindowContext(screenID: "legacy", hasNotch: true, notchHeight: 38, availableWidth: 1512)
            try require(legacy.notchWidth == 192 && legacy.compactWidth == 272,
                        "legacy callers without camera width get the conservative fallback")

            let screen = NSRect(x: -1512, y: 500, width: 1512, height: 982)
            let left = NSRect(x: -1512, y: 1444, width: 696, height: 38)
            let right = NSRect(x: -696, y: 1444, width: 696, height: 38)
            try require(IslandWindowContext.measuredNotchWidth(screenFrame: screen, auxiliaryLeft: left, auxiliaryRight: right, hasNotch: true) == 120,
                        "camera width uses screen coordinates with a negative origin")
            let asymmetricLeft = NSRect(x: -1512, y: 1444, width: 676, height: 38)
            try require(IslandWindowContext.measuredNotchWidth(screenFrame: screen, auxiliaryLeft: asymmetricLeft, auxiliaryRight: right, hasNotch: true) == 160,
                        "asymmetric camera uses the farther edge rather than raw gap")
            try require(IslandWindowContext.measuredNotchWidth(screenFrame: screen, auxiliaryLeft: left, auxiliaryRight: nil, hasNotch: true) == 192,
                        "missing right auxiliary area keeps a conservative camera width")
            try require(IslandWindowContext.measuredNotchWidth(screenFrame: screen, auxiliaryLeft: nil, auxiliaryRight: nil, hasNotch: false) == 0,
                        "external screens reserve no camera width")
            try require(IslandMotion.hoverWidth == 12 && IslandMotion.hoverHeight == 3,
                        "compact hover stays a small shared geometry change")
            let hover = IslandWindowContext(screenID: "hover-synthetic", hasNotch: true, notchHeight: 38, availableWidth: 1512, notchWidth: 120)
            let hoverCoordinator = IslandWindowCoordinator()
            hover.coordinator = hoverCoordinator
            defer { hover.invalidate() }
            // Await state transitions with a bounded deadline: a task can start late
            // on a shared runner. Keep pending enters and their cancellation in one
            // actor turn; even a short sleep can resume after the enter deadline.
            hover.setHovered(active: true, hasActivity: true)
            hover.setHovered(active: false, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverEnterDelay + .milliseconds(45))
            try require(!hover.expanded && !hover.hovering, "quick entry and exit cancel the pending open")
            // Reproduce a queued main actor so this cannot regress to a fixed
            // sleep that resumes before the hover task has even started its delay.
            DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.25) }
            hover.setHovered(active: true, hasActivity: true)
            try await waitForExpansion(hover, true)
            try require(hover.expanded && hoverCoordinator.keyboardFocusRequests == 0,
                        "re-entry opens after the new delay without taking keyboard focus")
            hover.setHovered(active: false, hasActivity: true)
            // Keep the quick return in one actor turn. A nominal 60ms sleep
            // can resume after the 180ms close deadline on a shared runner.
            hover.setHovered(active: true, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(45))
            try require(hover.expanded, "quick return cancels a pending hover close")
            hover.setHovered(active: false, hasActivity: true)
            try await waitForExpansion(hover, false)
            try require(!hover.expanded, "hover-owned surface closes after a stable exit")

            // A click that races the enter task must not later become hover-owned.
            hover.setHovered(active: true, hasActivity: true)
            hover.expand()
            try await Task.sleep(for: IslandMotion.hoverEnterDelay + .milliseconds(45))
            try require(hover.expanded && hoverCoordinator.keyboardFocusRequests == 1,
                        "explicit open cancels the pending hover ownership change")
            hover.setHovered(active: false, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(45))
            try require(hover.expanded, "pointer exit does not close an explicitly opened surface")
            hover.collapse()
            try require(!hover.expanded, "explicit collapse remains immediate")

            hover.setHovered(active: true, hasActivity: true)
            try await waitForExpansion(hover, true)
            try require(hover.beginEditing(requestID: "synthetic-request"), "editor pin can acquire the window lock")
            hover.setHovered(active: false, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(45))
            try require(hover.expanded && hover.editingRequestID == "synthetic-request", "editor pin survives pointer exit")
            hover.endEditing()
            try require(hover.editingRequestID == nil && hover.expanded && hoverCoordinator.editingReleases == 1,
                        "ending editing releases its lock without an implicit submit or close")
            hover.collapse()

            hover.setHovered(active: true, hasActivity: true)
            try await waitForExpansion(hover, true)
            hover.setBusy(true)
            hover.setHovered(active: false, hasActivity: true)
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(45))
            try require(hover.expanded && hover.busy, "busy work protects a hover-owned surface from closing")
            hover.setBusy(false)
            try await waitForExpansion(hover, false)
            try require(!hover.expanded && !hover.busy, "busy release re-evaluates a pending hover exit")

            hoverCoordinator.allowsEditing = false
            hover.setHovered(active: true, hasActivity: true)
            try await waitForExpansion(hover, true)
            try require(!hover.beginEditing(requestID: "blocked-request") && hover.editingRequestID == nil,
                        "a denied editor lock does not pin the surface")
            hover.setHovered(active: false, hasActivity: true)
            try await waitForExpansion(hover, false)
            try require(!hover.expanded, "denied editor acquisition preserves normal hover closing")
            hoverCoordinator.allowsEditing = true
            let idle = IslandWindowContext(screenID: "idle-boss", hasNotch: true, notchHeight: 38,
                                           availableWidth: 1512, notchWidth: 120)
            let idleCoordinator = IslandWindowCoordinator()
            idle.coordinator = idleCoordinator
            idle.setHovered(active: true, hasActivity: false)
            try await Task.sleep(for: IslandMotion.hoverEnterDelay + .milliseconds(45))
            try require(!idle.expanded && idle.idleEncounterNumber == 0,
                        "idle encounter waits for the longer deliberate-hover delay")
            try await waitForExpansion(idle, true)
            try require(idle.expanded && idle.idleEncounterActive && idle.idleEncounterNumber == 1,
                        "stable idle hover opens one boss encounter")
            try require(idleCoordinator.keyboardFocusRequests == 0,
                        "idle encounter opens without taking keyboard focus")
            idle.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: false,
                           widthPercent: 100, heightPercent: 100, notchWidth: 120)
            idle.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: false,
                           widthPercent: 100, heightPercent: 100, notchWidth: 120)
            try require(idle.expanded && idle.idleEncounterActive && idle.idleEncounterNumber == 1,
                        "repeated idle coordinator updates preserve the open encounter")

            idle.setHovered(active: false, hasActivity: false)
            idle.setHovered(active: true, hasActivity: false)
            // Scheduling can pause after the return; the cancelled close must
            // still leave the same encounter open without replaying it.
            DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.25) }
            try await Task.sleep(for: IslandMotion.hoverExitDelay + .milliseconds(45))
            try require(idle.expanded && idle.idleEncounterActive && idle.idleEncounterNumber == 1,
                        "quick return cancels idle encounter closing without replay")
            idle.setHovered(active: false, hasActivity: false)
            try await waitForExpansion(idle, false)
            try require(!idle.expanded && !idle.idleEncounterActive,
                        "leaving the island closes and clears the idle encounter")
            idle.setHovered(active: true, hasActivity: false)
            try await waitForExpansion(idle, true)
            try require(idle.expanded && idle.idleEncounterActive && idle.idleEncounterNumber == 2,
                        "a later idle visit starts a fresh encounter")

            idle.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: true,
                           widthPercent: 100, heightPercent: 100, notchWidth: 120)
            try require(idle.expanded && !idle.idleEncounterActive && idle.idleEncounterNumber == 2,
                        "a new task takes over the same hover-opened surface")
            try require(idleCoordinator.keyboardFocusRequests == 0,
                        "task takeover does not steal keyboard focus")
            idle.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: false,
                           widthPercent: 100, heightPercent: 100, notchWidth: 120)
            try require(idle.expanded && idle.idleEncounterActive && idle.idleEncounterNumber == 3,
                        "when the last task ends under the pointer, the boss takes over in place")

            try require(idle.beginEditing(requestID: "idle-editor-pin"), "task editor may take over an idle encounter")
            try require(idle.expanded && !idle.idleEncounterActive,
                        "an explicit editor pin clears idle encounter ownership")
            idle.endEditing(); idle.collapse()
            try require(!idle.expanded && !idle.idleEncounterActive,
                        "explicit collapse and Escape clear the idle encounter")
            idle.setHovered(active: true, hasActivity: false)
            try await Task.sleep(for: IslandMotion.idleEncounterEnterDelay + .milliseconds(45))
            try require(idle.idleEncounterNumber == 3,
                        "a still-hovered pointer does not immediately reopen an explicitly collapsed island")
            idle.setHovered(active: false, hasActivity: false)
            idle.setHovered(active: true, hasActivity: false)
            try await waitForExpansion(idle, true)
            try require(idle.expanded && idle.idleEncounterNumber == 4,
                        "a fresh pointer re-entry after collapse starts a new encounter")
            idle.invalidate()
            try require(!idle.idleEncounterActive && idle.coordinator == nil,
                        "window invalidation clears idle state")

            let explicitTask = IslandWindowContext(screenID: "explicit-task-end", hasNotch: true, notchHeight: 38,
                                                   availableWidth: 1512, notchWidth: 120)
            let explicitTaskCoordinator = IslandWindowCoordinator()
            explicitTask.coordinator = explicitTaskCoordinator
            explicitTask.setHovered(active: true, hasActivity: true)
            explicitTask.expand()
            try require(explicitTask.expanded && !explicitTask.idleEncounterActive,
                        "explicitly opening a task is not owned by idle hover")
            explicitTask.configure(hasNotch: true, notchHeight: 38, availableWidth: 1512, hasActivity: false,
                                   widthPercent: 100, heightPercent: 100, notchWidth: 120)
            try require(!explicitTask.expanded && !explicitTask.idleEncounterActive,
                        "last task ending under an explicit hover does not leave a blank expanded surface")
            try await waitForExpansion(explicitTask, true)
            try require(explicitTask.expanded && explicitTask.idleEncounterActive && explicitTask.idleEncounterNumber == 1,
                        "the steady pointer opens a fresh idle encounter after the task surface collapses")
            explicitTask.invalidate()

            hover.setHovered(active: true, hasActivity: true)
            hover.invalidate()
            try await Task.sleep(for: IslandMotion.hoverEnterDelay + .milliseconds(45))
            try require(!hover.expanded && hover.coordinator == nil, "window invalidation cancels a pending enter")
            print("PASS \(checks) compact geometry and hover state checks; synthetic displays only")
        } catch {
            FileHandle.standardError.write(Data("FAIL compact window: \(error)\n".utf8)); exit(1)
        }
    }
}
