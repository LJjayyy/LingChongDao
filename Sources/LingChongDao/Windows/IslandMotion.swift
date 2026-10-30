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
