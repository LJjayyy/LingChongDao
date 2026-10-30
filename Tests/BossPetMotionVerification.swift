import Foundation

@main
enum BossPetMotionVerification {
    static func main() {
        verifyPerformanceTimeline()
        verifyIdleSequences()
        verifyAttentionAndReducedMotion()
        verifyClickCoalescing()
        print("PASS boss pet 16-frame timeline, return states, Reduced Motion, and click coalescing")
    }

    private static func verifyPerformanceTimeline() {
        precondition(BossPetMotion.performanceFrames == [0, 4, 5, 6, 7, 8, 9, 8, 9, 11, 12, 13, 14, 0],
                     "Performance must use the approved 16-frame atlas path")
        precondition(BossPetMotion.transformKeyframeCount == BossPetMotion.performanceFrames.count + 1,
                     "Transform keys cover the start, every frame boundary, and the end")
        precondition(BossPetMotion.performanceFrame(elapsed: -0.2) == 0, "Negative elapsed time starts at idle")
        precondition(BossPetMotion.performanceFrame(elapsed: 0) == 0)
        precondition(BossPetMotion.performanceFrame(elapsed: 0.079) == 0)
        precondition(BossPetMotion.performanceFrame(elapsed: 0.08) == 4, "Frame boundaries use the elapsed timeline")
        precondition(BossPetMotion.performanceFrame(elapsed: 0.4) == 8, "Intermediate act frame must be reachable")
        precondition(BossPetMotion.performanceFrame(elapsed: 0.64) == 9)
        precondition(BossPetMotion.performanceFrame(elapsed: 1.03) == 14, "The final settle frame must remain visible")
        precondition(BossPetMotion.performanceFrame(elapsed: BossPetMotion.performanceDuration) == nil)
        precondition(BossPetMotion.performanceFrame(elapsed: 10) == nil, "Elapsed time beyond the performance returns to the base pose")
        precondition(BossPetMotion.performanceFrame(elapsed: .infinity) == nil)
        precondition(BossPetMotion.performanceFrames.allSatisfy { (0..<16).contains($0) })
        precondition(!BossPetMotion.performanceFrames.contains(10) && !BossPetMotion.performanceFrames.contains(15))

        let small = BossPetMotion.frame(now: Date(timeIntervalSince1970: 0.68),
                                        performanceStartedAt: .init(timeIntervalSince1970: 0),
                                        idleSequence: nil, idleStartedAt: nil,
                                        isAttentive: false, reduceMotion: false,
                                        staticReactionActive: false, size: 20)
        let large = BossPetMotion.frame(now: Date(timeIntervalSince1970: 0.68),
                                        performanceStartedAt: .init(timeIntervalSince1970: 0),
                                        idleSequence: nil, idleStartedAt: nil,
                                        isAttentive: false, reduceMotion: false,
                                        staticReactionActive: false, size: 40)
        precondition(small.index == 9 && large.index == 9,
                     "Both sizes use the same authored frame (small=\(small.index), large=\(large.index))")
        precondition(abs(small.scaleX - 1) < abs(large.scaleX - 1), "Compact island transforms must be damped")
        precondition((4...15).contains(small.index) && small.scaleX.isFinite && small.scaleY.isFinite)

        let nearEnd = BossPetMotion.frame(now: Date(timeIntervalSince1970: BossPetMotion.performanceDuration - 0.001),
                                          performanceStartedAt: .init(timeIntervalSince1970: 0),
                                          idleSequence: nil, idleStartedAt: nil,
                                          isAttentive: false, reduceMotion: false,
                                          staticReactionActive: false, size: 20)
        precondition(abs(nearEnd.scaleX - 1) < 0.000001 && abs(nearEnd.scaleY - 1) < 0.000001 &&
                     nearEnd.rotationDegrees == 0 && nearEnd.offsetX == 0 && nearEnd.offsetY == 0,
                     "The final transform reaches neutral before the timeline completes")

        let endedIdle = BossPetMotion.frame(now: Date(timeIntervalSince1970: BossPetMotion.performanceDuration),
                                            performanceStartedAt: .init(timeIntervalSince1970: 0),
                                            idleSequence: nil, idleStartedAt: nil,
                                            isAttentive: false, reduceMotion: false,
                                            staticReactionActive: false, size: 20)
        let endedHover = BossPetMotion.frame(now: Date(timeIntervalSince1970: BossPetMotion.performanceDuration),
                                             performanceStartedAt: .init(timeIntervalSince1970: 0),
                                             idleSequence: nil, idleStartedAt: nil,
                                             isAttentive: true, reduceMotion: false,
                                             staticReactionActive: false, size: 20)
        precondition(endedIdle.index == 0 && endedHover.index == 3, "The animation ends on the current idle or hover pose")
    }

    private static func verifyIdleSequences() {
        let blinkTimes: [(Double, Int?)] = [
            (-0.1, 0), (0, 0), (0.07, 1), (0.14, 2), (0.21, 1), (0.28, 0), (0.35, nil), (8, nil),
            (.greatestFiniteMagnitude, nil)
        ]
        for (time, expected) in blinkTimes {
            precondition(BossPetMotion.idleFrame(sequence: .blink, elapsed: time) == expected,
                         "Unexpected blink frame at elapsed=\(time)")
        }
        precondition(BossPetMotion.idleFrame(sequence: .inspect, elapsed: 0) == 3)
        precondition(BossPetMotion.idleFrame(sequence: .inspect, elapsed: 0.719) == 3)
        precondition(BossPetMotion.idleFrame(sequence: .inspect, elapsed: 0.72) == nil)
        precondition(BossPetMotion.idleFrame(sequence: .blink, elapsed: .infinity) == nil)
    }

    private static func verifyAttentionAndReducedMotion() {
        let now = Date(timeIntervalSince1970: 0.5)
        let activePerformance = Date(timeIntervalSince1970: 0)
        let reducedIdle = BossPetMotion.frame(now: now, performanceStartedAt: activePerformance,
                                             idleSequence: .blink, idleStartedAt: .init(timeIntervalSince1970: 0),
                                             isAttentive: false, reduceMotion: true,
                                             staticReactionActive: false, size: 20)
        let reducedHover = BossPetMotion.frame(now: now, performanceStartedAt: nil,
                                              idleSequence: nil, idleStartedAt: nil,
                                              isAttentive: true, reduceMotion: true,
                                              staticReactionActive: false, size: 20)
        let reducedClick = BossPetMotion.frame(now: now, performanceStartedAt: nil,
                                              idleSequence: nil, idleStartedAt: nil,
                                              isAttentive: true, reduceMotion: true,
                                              staticReactionActive: true, size: 20)
        let staticClickAfterPreferenceChange = BossPetMotion.frame(now: now, performanceStartedAt: nil,
                                                                   idleSequence: nil, idleStartedAt: nil,
                                                                   isAttentive: false, reduceMotion: false,
                                                                   staticReactionActive: true, size: 20)
        let hoverOverIdle = BossPetMotion.frame(now: now, performanceStartedAt: nil,
                                                idleSequence: .blink, idleStartedAt: .init(timeIntervalSince1970: 0),
                                                isAttentive: true, reduceMotion: false,
                                                staticReactionActive: false, size: 20)
        precondition(reducedIdle.index == 0 && reducedIdle.scaleX == 1 && reducedIdle.rotationDegrees == 0,
                     "Reduced Motion suppresses playback and transforms")
        precondition(reducedHover.index == 3 && reducedClick.index == 8 && staticClickAfterPreferenceChange.index == 8,
                     "Reduced Motion keeps static inspection and click feedback")
        precondition(hoverOverIdle.index == 3, "Hover takes priority over an idle blink")
    }

    private static func verifyClickCoalescing() {
        var queue = BossPetReactionQueue()
        precondition(queue.request(reduceMotion: false) == .start)
        precondition(queue.request(reduceMotion: false) == .queued)
        precondition(queue.request(reduceMotion: false) == .queued)
        precondition(queue.hasPendingReaction, "Rapid clicks coalesce into one follow-up performance")
        precondition(queue.complete() && queue.isPlaying && !queue.hasPendingReaction,
                     "Completing the current act starts the queued replay")
        precondition(queue.request(reduceMotion: false) == .queued)
        precondition(queue.complete() && queue.isPlaying, "Clicks during replay queue one more continuation")
        precondition(!queue.complete() && !queue.isPlaying, "The animation ends after the final queued act")

        precondition(queue.request(reduceMotion: false) == .start)
        precondition(queue.request(reduceMotion: true) == .staticPoint)
        precondition(!queue.isPlaying && !queue.hasPendingReaction, "Reduced Motion cancels animated playback")
        precondition(queue.request(reduceMotion: true) == .staticPoint)
    }
}
