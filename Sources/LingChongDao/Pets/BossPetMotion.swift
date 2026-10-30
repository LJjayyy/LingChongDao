import Foundation

enum BossPetIdleSequence: Equatable {
    case blink
    case inspect

    var duration: TimeInterval {
        switch self {
        case .blink: 0.35
        case .inspect: 0.72
        }
    }
}

struct BossPetFrameState: Equatable {
    let index: Int
    let scaleX: Double
    let scaleY: Double
    let rotationDegrees: Double
    let offsetX: Double
    let offsetY: Double

    static let neutral = Self(index: 0, scaleX: 1, scaleY: 1,
                              rotationDegrees: 0, offsetX: 0, offsetY: 0)
}

struct BossPetReactionQueue {
    enum Decision: Equatable { case start, queued, staticPoint }

    private(set) var isPlaying = false
    private(set) var hasPendingReaction = false

    mutating func request(reduceMotion: Bool) -> Decision {
        if reduceMotion {
            cancel()
            return .staticPoint
        }
        guard isPlaying else {
            isPlaying = true
            return .start
        }
        hasPendingReaction = true
        return .queued
    }

    /// Finishes the current performance and starts at most one coalesced replay.
    @discardableResult
    mutating func complete() -> Bool {
        guard isPlaying else { return false }
        guard hasPendingReaction else {
            isPlaying = false
            return false
        }
        hasPendingReaction = false
        return true
    }

    mutating func cancel() {
        isPlaying = false
        hasPendingReaction = false
    }
}

/// A small, deterministic timeline model for the default mascot. The view owns
/// only start times; this type selects frames and interpolates transforms.
enum BossPetMotion {
    static let performanceFrameInterval: TimeInterval = 0.08
    // Start/end on idle, skip frame 10 (reversed arm) and frame 15 (different
    // mouth), and sway through 8/9 instead of snapping to the reversed pose.
    static let performanceFrames = [0, 4, 5, 6, 7, 8, 9, 8, 9, 11, 12, 13, 14, 0]
    static let performanceDuration = Double(performanceFrames.count) * performanceFrameInterval
    static let idleBlinkFrameInterval: TimeInterval = 0.07
    static let idleBlinkFrames = [0, 1, 2, 1, 0]
    static let idleInspectDuration: TimeInterval = 0.72
    static let idleIntervalRange: ClosedRange<Double> = 4...6
    static let staticReactionDuration: TimeInterval = 0.6

    private struct Keyframe {
        let scaleX: Double
        let scaleY: Double
        let rotation: Double
        let x: Double
        let y: Double
    }

    // Small islands reduce the full-size keyframe movement to keep the mascot
    // inside its compact cell. The artwork itself and island geometry stay fixed.
    private static let actionKeyframes: [Keyframe] = [
        .init(scaleX: 1, scaleY: 1, rotation: 0, x: 0, y: 0),
        .init(scaleX: 0.96, scaleY: 1.04, rotation: 0, x: 0, y: 0),
        .init(scaleX: 1.06, scaleY: 0.94, rotation: -2, x: 0, y: 0.5),
        .init(scaleX: 0.96, scaleY: 1.04, rotation: -1, x: 0, y: -0.2),
        .init(scaleX: 1.04, scaleY: 0.96, rotation: -3, x: 0, y: 0),
        .init(scaleX: 0.92, scaleY: 1.08, rotation: -6, x: 1.2, y: -0.6),
        .init(scaleX: 1.03, scaleY: 0.97, rotation: -3, x: -0.6, y: 0),
        .init(scaleX: 0.92, scaleY: 1.08, rotation: -6, x: 0.8, y: -0.4),
        .init(scaleX: 1.03, scaleY: 0.97, rotation: -3, x: -0.6, y: 0),
        .init(scaleX: 0.92, scaleY: 1.08, rotation: -6, x: 0.2, y: 0.4),
        .init(scaleX: 0.98, scaleY: 1.02, rotation: -3, x: 0, y: 0),
        .init(scaleX: 1.06, scaleY: 0.94, rotation: 0, x: 0, y: 0.2),
        .init(scaleX: 0.94, scaleY: 1.06, rotation: 2, x: 0, y: 0.7),
        .init(scaleX: 1, scaleY: 1, rotation: 0, x: 0, y: 0),
        .init(scaleX: 1, scaleY: 1, rotation: 0, x: 0, y: 0)
    ]
    static var transformKeyframeCount: Int { actionKeyframes.count }

    static func performanceFrame(elapsed: TimeInterval) -> Int? {
        guard elapsed.isFinite, elapsed < performanceDuration else { return nil }
        let clamped = max(0, elapsed)
        let offset = Int(clamped / performanceFrameInterval + 1e-12)
        guard performanceFrames.indices.contains(offset) else { return nil }
        return performanceFrames[offset]
    }

    static func idleFrame(sequence: BossPetIdleSequence, elapsed: TimeInterval) -> Int? {
        guard elapsed.isFinite else { return nil }
        guard elapsed >= 0 else { return sequence == .blink ? 0 : 3 }
        guard elapsed < sequence.duration else { return nil }
        switch sequence {
        case .blink:
            let offset = Int(elapsed / idleBlinkFrameInterval + 1e-12)
            return idleBlinkFrames.indices.contains(offset) ? idleBlinkFrames[offset] : nil
        case .inspect:
            return elapsed < idleInspectDuration ? 3 : nil
        }
    }

    static func frame(now: Date, performanceStartedAt: Date?,
                      idleSequence: BossPetIdleSequence?, idleStartedAt: Date?,
                      isAttentive: Bool, reduceMotion: Bool,
                      staticReactionActive: Bool, size: Double) -> BossPetFrameState {
        if staticReactionActive {
            return .init(index: 8, scaleX: 1, scaleY: 1,
                         rotationDegrees: 0, offsetX: 0, offsetY: 0)
        }
        if reduceMotion {
            let index = isAttentive ? 3 : 0
            return .init(index: index, scaleX: 1, scaleY: 1,
                         rotationDegrees: 0, offsetX: 0, offsetY: 0)
        }

        if let performanceStartedAt {
            let elapsed = now.timeIntervalSince(performanceStartedAt)
            if let index = performanceFrame(elapsed: elapsed) {
                return performanceState(index: index, elapsed: elapsed, size: size)
            }
        }

        if isAttentive {
            return .init(index: 3, scaleX: 1, scaleY: 1,
                         rotationDegrees: 0, offsetX: 0, offsetY: 0)
        }

        if let idleSequence, let idleStartedAt,
           let index = idleFrame(sequence: idleSequence, elapsed: now.timeIntervalSince(idleStartedAt)) {
            return .init(index: index, scaleX: 1, scaleY: 1,
                         rotationDegrees: 0, offsetX: 0, offsetY: 0)
        }
        return .neutral
    }

    private static func performanceState(index: Int, elapsed: TimeInterval, size: Double) -> BossPetFrameState {
        let framePosition = min(Double(performanceFrames.count), max(0, elapsed / performanceFrameInterval))
        let segment = min(actionKeyframes.count - 2, Int(framePosition))
        let nextSegment = segment + 1
        let fraction = framePosition - Double(segment)
        let first = actionKeyframes[segment]
        let second = actionKeyframes[nextSegment]
        let movementScale = size <= 28 ? 0.45 : min(1, max(0.45, size / 36))

        func interpolate(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        let scaleX = interpolate(first.scaleX, second.scaleX)
        let scaleY = interpolate(first.scaleY, second.scaleY)
        return .init(index: index,
                     scaleX: 1 + (scaleX - 1) * movementScale,
                     scaleY: 1 + (scaleY - 1) * movementScale,
                     rotationDegrees: interpolate(first.rotation, second.rotation) * movementScale,
                     offsetX: interpolate(first.x, second.x) * movementScale,
                     offsetY: interpolate(first.y, second.y) * movementScale)
    }
}
