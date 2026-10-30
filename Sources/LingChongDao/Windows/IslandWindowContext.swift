import AppKit
import Combine
import SwiftUI

/// Per-display presentation state. Provider state and drafts belong to AppModel.
@MainActor
final class IslandWindowContext: ObservableObject {
    let screenID: String
    @Published private(set) var hasNotch: Bool
    @Published private(set) var notchHeight: CGFloat
    @Published private(set) var notchWidth: CGFloat
    @Published private(set) var availableWidth: CGFloat
    @Published private(set) var compactWidth: CGFloat = 212
    @Published private(set) var compactHeight: CGFloat = 32
    @Published private(set) var expanded = false
    @Published private(set) var hovering = false
    @Published private(set) var idleEncounterActive = false
    @Published private(set) var idleEncounterNumber = 0
    @Published private(set) var expandedWidth: CGFloat
    @Published private(set) var contentHeight: CGFloat = 180
    @Published private(set) var editingRequestID: String?
    @Published private(set) var busy = false
    /// While set, the expanded surface shows only these sessions: the ones the
    /// automatic attention reveal announced. Cleared on any collapse and on
    /// user-initiated expansion, so normal opens show every session again.
    @Published private(set) var attentionFocus: Set<String>?

    weak var coordinator: IslandWindowCoordinator?
    private var hoverTask: Task<Void, Never>?
    private var autoCollapseTask: Task<Void, Never>?
    private var autoRevealed = false
    private var openedByHover = false
    private var hasActivity = false
    private var compactLeadingWidth: CGFloat = 20
    private var compactTrailingWidth: CGFloat = 0
    private var compactWidthPercent: Double = 100
    private var compactHeightPercent: Double = 100

    init(screenID: String, hasNotch: Bool, notchHeight: CGFloat, availableWidth: CGFloat, notchWidth: CGFloat = 0) {
        self.screenID = screenID
        self.hasNotch = hasNotch
        self.notchHeight = notchHeight
        self.notchWidth = Self.safeNotchWidth(notchWidth, hasNotch: hasNotch)
        self.availableWidth = availableWidth
        self.expandedWidth = min(hasNotch ? 590 : 552, max(1, availableWidth - 24))
        updateCompactGeometry()
    }

    func expand() {
        cancelAutoCollapse()
        attentionFocus = nil
        setExpanded(true, fromHover: false)
        coordinator?.requestKeyboardFocus(for: self)
    }

    func collapse() {
        cancelAutoCollapse()
        hoverTask?.cancel()
        hoverTask = nil
        endEditing()
        coordinator?.releaseKeyboardFocus(for: self)
        setExpanded(false, fromHover: false)
    }

    /// A session that needs the user is announced by pulling the surface down
    /// without asking the pointer to find it. Focus stays with the source app;
    /// the surface retracts after `IslandMotion.completionRevealDuration` once
    /// the user has stopped hovering, editing or waiting on an action. The
    /// announced sessions stay the only visible rows for this reveal.
    func revealCompletion(focusing: Set<String>) {
        let focus = focusing.isEmpty ? nil : focusing
        if expanded {
            guard autoRevealed else { return }
            attentionFocus = focus
            scheduleAutoCollapse(after: IslandMotion.completionRevealDuration)
            return
        }
        autoRevealed = true
        attentionFocus = focus
        setExpanded(true, fromHover: false)
        scheduleAutoCollapse(after: IslandMotion.completionRevealDuration)
    }

    func toggle() { expanded ? collapse() : expand() }

    func setHovered(active: Bool, hasActivity: Bool) {
        let activityChanged = hasActivity != self.hasActivity
        guard active != hovering || activityChanged else { return }
        hovering = active
        self.hasActivity = hasActivity
        hoverTask?.cancel()
        hoverTask = nil

        if active, !expanded {
            let delay = hasActivity ? IslandMotion.hoverEnterDelay : IslandMotion.idleEncounterEnterDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.hovering, self.hasActivity == hasActivity else { return }
                self.setExpanded(true, fromHover: true)
                if !hasActivity { self.beginIdleEncounter() }
            }
        } else if active, expanded, activityChanged {
            if hasActivity {
                // A real task takes over the already-open hover surface without
                // closing it or stealing keyboard focus.
                idleEncounterActive = false
            } else if openedByHover {
                // When the last task ends under the pointer, the open surface
                // becomes the idle boss encounter in place.
                beginIdleEncounter()
            }
        } else if !active, expanded, openedByHover {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: IslandMotion.hoverExitDelay)
                guard !Task.isCancelled, let self, !self.hovering,
                      self.editingRequestID == nil, !self.busy, self.openedByHover else { return }
                self.setExpanded(false, fromHover: false)
            }
        }
        coordinator?.contextGeometryDidChange(self)
    }

    @discardableResult
    func beginEditing(requestID: String) -> Bool {
        guard !requestID.isEmpty else { return false }
        guard coordinator?.requestEditing(for: self) ?? false else { return false }
        cancelAutoCollapse()
        editingRequestID = requestID
        setExpanded(true, fromHover: false)
        return true
    }

    func endEditing() {
        guard editingRequestID != nil else { return }
        editingRequestID = nil
        coordinator?.releaseEditing(for: self)
    }

    func setBusy(_ active: Bool) {
        busy = active
        if active { cancelAutoCollapse() }
        // Re-evaluate a hover-opened surface once its temporary protection ends.
        if !active, !hovering, openedByHover, editingRequestID == nil {
            hovering = true
            setHovered(active: false, hasActivity: hasActivity)
        }
    }

    func setContentSize(width: CGFloat, height: CGFloat) {
        let boundedWidth = min(max(1, width), max(1, availableWidth - 24))
        let boundedHeight = min(max(32, height), 480)
        guard abs(expandedWidth - boundedWidth) > 0.5 || abs(contentHeight - boundedHeight) > 0.5 else { return }
        expandedWidth = boundedWidth
        contentHeight = boundedHeight
        coordinator?.contextGeometryDidChange(self)
    }

    func setContentHeight(_ height: CGFloat) {
        setContentSize(width: expandedWidth, height: height)
    }

    /// The view reports only its actual pet stack and color/count badge widths.
    /// A centered camera gap reserves equal safe wings on both sides of the screen.
    func setCompactContentSize(leadingWidth: CGFloat, trailingWidth: CGFloat) {
        let leading = leadingWidth.isFinite ? max(0, leadingWidth) : 0
        let trailing = trailingWidth.isFinite ? max(0, trailingWidth) : 0
        guard compactLeadingWidth != leading || compactTrailingWidth != trailing else { return }
        compactLeadingWidth = leading
        compactTrailingWidth = trailing
        if updateCompactGeometry() { coordinator?.contextGeometryDidChange(self) }
    }

    func configure(hasNotch: Bool, notchHeight: CGFloat, availableWidth: CGFloat,
                   hasActivity: Bool, widthPercent: Double, heightPercent: Double, notchWidth: CGFloat = 0) {
        self.hasNotch = hasNotch
        self.notchHeight = notchHeight
        self.notchWidth = Self.safeNotchWidth(notchWidth, hasNotch: hasNotch)
        self.availableWidth = availableWidth
        compactWidthPercent = widthPercent.isFinite ? min(max(widthPercent, 20), 130) : 100
        compactHeightPercent = heightPercent.isFinite ? min(max(heightPercent, 75), 125) : 100
        // reconcile() explicitly resizes after configure(). Do not notify geometry here
        // and re-enter the coordinator while it is reconciling the display collection.
        updateCompactGeometry()
        expandedWidth = min(expandedWidth, max(1, availableWidth - 24))
        // An explicitly opened task surface must not become a blank panel when
        // its last task disappears. Collapse first; the unchanged pointer then
        // starts the normal deliberate idle hover delay in setHovered below.
        if !hasActivity, expanded, editingRequestID == nil, !busy,
           !idleEncounterActive, !openedByHover { collapse() }
        setHovered(active: hovering, hasActivity: hasActivity)
    }

    /// NSScreen auxiliary areas can be asymmetric. Centering the surface requires
    /// covering the farther camera edge, not merely the raw left/right gap width.
    static func measuredNotchWidth(screenFrame: NSRect, auxiliaryLeft: NSRect?, auxiliaryRight: NSRect?, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return 0 }
        guard let left = auxiliaryLeft, let right = auxiliaryRight,
              screenFrame.midX.isFinite, left.maxX.isFinite, right.minX.isFinite,
              right.minX > left.maxX else { return 192 }
        let halfWidth = max(abs(screenFrame.midX - left.maxX), abs(right.minX - screenFrame.midX))
        return safeNotchWidth(halfWidth * 2, hasNotch: true)
    }

    private static func safeNotchWidth(_ value: CGFloat, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return 0 }
        return value.isFinite && value > 0 ? value : 192
    }

    @discardableResult
    private func updateCompactGeometry() -> Bool {
        let minimumWidth: CGFloat
        if hasNotch {
            minimumWidth = notchWidth + 2 * (max(compactLeadingWidth, compactTrailingWidth) + 20)
        } else {
            minimumWidth = compactLeadingWidth + compactTrailingWidth + 20 + (compactTrailingWidth > 0 ? 10 : 0)
        }
        let width = min(max(1, availableWidth - 24), minimumWidth * CGFloat(max(1, compactWidthPercent / 100)))
        let height = max(hasNotch ? notchHeight : 0, 32 * CGFloat(compactHeightPercent / 100))
        let changed = compactWidth != width || compactHeight != height
        if compactWidth != width { compactWidth = width }
        if compactHeight != height { compactHeight = height }
        return changed
    }

    func invalidate() {
        cancelAutoCollapse()
        hoverTask?.cancel()
        hoverTask = nil
        idleEncounterActive = false
        endEditing()
        coordinator = nil
    }

    private func scheduleAutoCollapse(after delay: Duration) {
        autoCollapseTask?.cancel()
        autoCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.autoRevealed, self.expanded else { return }
            // Never yank the surface away from a pointer or an active draft;
            // re-check shortly instead, then close once the user is done.
            if self.hovering || self.editingRequestID != nil || self.busy {
                self.scheduleAutoCollapse(after: IslandMotion.completionRevealRetry)
                return
            }
            self.autoRevealed = false
            self.setExpanded(false, fromHover: false)
            if ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_WINDOWS"] == "1" {
                let line = "LINGCHONGDAO_COMPLETION_COLLAPSE screen=\(self.screenID)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    private func cancelAutoCollapse() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        autoRevealed = false
    }

    private func beginIdleEncounter() {
        guard !idleEncounterActive else { return }
        idleEncounterNumber = idleEncounterNumber == Int.max ? 1 : idleEncounterNumber + 1
        idleEncounterActive = true
    }

    private func setExpanded(_ active: Bool, fromHover: Bool) {
        if !fromHover {
            // A pending enter must not later convert an explicit click/editor pin
            // into hover ownership and unexpectedly close it on pointer exit.
            hoverTask?.cancel()
            hoverTask = nil
        }
        if !active {
            autoCollapseTask?.cancel()
            autoCollapseTask = nil
            autoRevealed = false
            attentionFocus = nil
        }
        let changed = expanded != active
        if active && fromHover { attentionFocus = nil }
        expanded = active
        openedByHover = active && fromHover
        if !active || !fromHover { idleEncounterActive = false }
        if changed { coordinator?.contextGeometryDidChange(self) }
    }
}
