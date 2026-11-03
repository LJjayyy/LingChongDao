import Foundation

/// Shared timing and geometry policy for the native host and SwiftUI presentation.
/// Animation construction stays in the view; these values do not assume a frame rate.
enum IslandMotion {
    static let hoverWidth: CGFloat = 12
    static let hoverHeight: CGFloat = 3
    static let hoverEnterDelay: Duration = .milliseconds(140)
    static let idleEncounterEnterDelay: Duration = .milliseconds(280)
    static let hoverExitDelay: Duration = .milliseconds(180)
    static let canvasReleaseDelay: Duration = .milliseconds(620)
    // The surface is capped at 480pt; keep its 24pt shadow margin allocated.
    // Resizing the hosting canvas on first hover animates the whole island down.
    static let canvasHeight: CGFloat = 480 + 24
    // Keep one persistent spring for hover, opening and closing. Switching its
    // duration mid-flight lets frame and newly animated shape values diverge.
    static let surfaceDuration: Double = 0.42
    static let surfaceBounce: Double = 0.045
    static let hoverDuration: Double = 0.22
    // A finished task pulls the surface down without pointer or keyboard focus.
    // It closes itself only after the user has had time to notice the result.
    static let completionRevealDuration: Duration = .seconds(8)
    static let completionRevealRetry: Duration = .seconds(2)
    static let contentEnterDelay: Double = 0.035
    static let contentEnterDuration: Double = 0.20
    static let contentExitDuration: Double = 0.10
    // Notification-row swipe clearing, matching macOS Notification Center and
    // iOS: the row tracks the drag 1:1 up to the limit, flies out past the
    // threshold (a quick fling counts too), and springs back otherwise.
    static let swipeDismissThreshold: CGFloat = 110
    static let swipeFlingPrediction: CGFloat = 420
    static let swipeDragLimit: CGFloat = 180
    static let swipeFlyOutDuration: Double = 0.24
}

/// Trackpad gestures commit on release, allowing an intentional downward pull
/// to cancel. Unphased wheels commit at the threshold. Horizontal gestures
/// belong to rows; momentum and gestures begun in scrollable content never do.
struct IslandScrollCollapseGesture {
    enum Phase { case began, changed, ended, cancelled, unphased }
    private enum Axis { case undecided, vertical, horizontal }
    private var axis = Axis.undecided
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var peakUpwardTravel: CGFloat = 0
    private var eligible = false
    private var cancelledForCommit = false
    private(set) var isTracking = false
    private(set) var progress: CGFloat = 0
    private var lastTimestamp: TimeInterval?

    mutating func consume(deltaX: CGFloat, upwardDelta: CGFloat, precise: Bool,
                          phase: Phase, momentum: Bool, timestamp: TimeInterval,
                          canCollapse: Bool) -> Bool {
        // A terminal event without an active gesture cannot start a dismissal.
        guard lastTimestamp != nil || (phase != .ended && phase != .cancelled) else { return false }
        if phase == .began || lastTimestamp == nil ||
           (phase == .unphased && timestamp - (lastTimestamp ?? 0) > 0.25) {
            reset()
            eligible = canCollapse
        }
        lastTimestamp = timestamp
        defer { if phase == .ended || phase == .cancelled { reset() } }
        guard !momentum, phase != .cancelled, eligible, canCollapse,
              deltaX.isFinite, upwardDelta.isFinite else { return false }
        let scale: CGFloat = precise ? 1 : 10
        x += deltaX * scale
        y += upwardDelta * scale
        if axis == .undecided, max(abs(x), abs(y)) >= 3 {
            axis = abs(y) > abs(x) ? .vertical : .horizontal
        }
        peakUpwardTravel = max(peakUpwardTravel, y)
        if phase != .unphased, axis == .vertical,
           peakUpwardTravel >= 3, peakUpwardTravel - y >= 8 {
            // A deliberate reversal cancels this gesture, even when its net
            // distance is still above the dismissal threshold. Tiny jitter is
            // tolerated; a fresh touch can always begin another attempt.
            cancelledForCommit = true
        }
        if phase != .unphased, axis == .vertical {
            isTracking = true
            progress = min(1, max(0, y / 120))
        }
        guard phase == .ended || phase == .unphased else { return false }
        guard axis == .vertical, y >= 24, !cancelledForCommit else { return false }
        // Consume once per gesture, including any tail after the surface closes.
        eligible = false
        return true
    }

    mutating func reset() {
        axis = .undecided
        x = 0
        y = 0
        peakUpwardTravel = 0
        eligible = false
        cancelledForCommit = false
        isTracking = false
        progress = 0
        lastTimestamp = nil
    }
}
