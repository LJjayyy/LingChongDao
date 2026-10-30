import AppKit
import Foundation
import IslandCore
import SwiftUI

// A deterministic fixture preserves the production pet frame/matched-geometry
// path without reading another application's settings or decoding local assets.
@MainActor
struct PetView: View {
    var source: ProviderID = .qoder
    var phase: SessionPhase? = nil
    var sourceApplication: SourceApplicationID? = nil
    var size: CGFloat = 20
    var body: some View {
        Circle().fill(.yellow).frame(width: size, height: size)
    }
}

@MainActor
struct DefaultPetView: View {
    var size: CGFloat = 20
    var isAttentive: Bool = false
    var reactionToken: Int = 0
    var body: some View {
        Circle().fill(.yellow).frame(width: size, height: size)
            .accessibilityLabel("灵宠岛默认灵宠：老板鼠")
            .help("空闲时由老板鼠值班")
    }
}

// verify-motion.sh injects only this passive callback into a temporary copy of
// IslandShell.path. It does not replace any frame or animation implementation.
enum MotionVerificationSamples {
    static var onPath: ((CGFloat, CGFloat, CGFloat) -> Void)?
}

final class MotionRecorder: @unchecked Sendable {
    struct Sample: Codable {
        let time: Double
        let width: CGFloat
        let height: CGFloat
        let expansion: CGFloat
    }
    struct PresentationSample: Codable {
        let time: Double
        let top: CGFloat?
        let modelTop: CGFloat?
        let hostHeight: CGFloat
        let surfaceIdentifier: String?
        let mappingError: String?
    }
    struct Segment: Codable {
        let name: String
        let start: Double
        let end: Double
        let hoverHeight: CGFloat
        let targetHeight: CGFloat
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var presentationSamples: [PresentationSample] = []
    // SwiftUI can briefly rebuild the shape subtree during a body update. Keep
    // sampling an already-verified model layer while its object identity and
    // direct-root geometry are unchanged; never substitute a different layer.
    private weak var validatedSurface: CALayer?
    private var validatedSurfaceID: ObjectIdentifier?
    private let origin = ProcessInfo.processInfo.systemUptime
    var now: Double { ProcessInfo.processInfo.systemUptime - origin }
    func record(width: CGFloat, height: CGFloat, expansion: CGFloat) {
        let sample = Sample(time: now, width: width, height: height, expansion: expansion)
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }
    func snapshot() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
    @MainActor func observePresentation() {
        let time = now
        func append(_ value: PresentationSample) {
            lock.lock()
            presentationSamples.append(value)
            lock.unlock()
        }
        guard let panel = NSApplication.shared.windows.first(where: { $0 is IslandPanel }),
              let host = panel.contentView as? IslandHostingView, let root = host.layer else {
            append(PresentationSample(time: time, top: nil, modelTop: nil, hostHeight: 0,
                                      surfaceIdentifier: nil, mappingError: "owned hosting root missing"))
            return
        }
        func fail(_ reason: String) {
            append(PresentationSample(time: time, top: nil, modelTop: nil, hostHeight: host.bounds.height,
                                      surfaceIdentifier: nil, mappingError: reason))
        }
        // This is an SDK-specific diagnostic seam, not a guaranteed SwiftUI
        // layer order. Revalidate it explicitly after a framework/view change.
        guard root.isGeometryFlipped, root.bounds.origin == .zero else {
            fail("hosting root coordinates changed; layer mapping needs revalidation")
            return
        }
        let candidates = (root.sublayers ?? []).filter { layer in
            String(describing: type(of: layer)) == "NSViewBackingLayer" &&
            (layer.sublayers ?? []).contains { child in
                String(describing: type(of: child)) == "ColorShapeLayer" &&
                (child.sublayers ?? []).contains { $0 is CAShapeLayer }
            }
        }
        let surface: CALayer
        if candidates.count == 1, let owned = candidates.first {
            if let knownID = validatedSurfaceID, knownID != ObjectIdentifier(owned) {
                fail("surface model identity changed; layer mapping needs revalidation")
                return
            }
            surface = owned
            validatedSurface = owned
            validatedSurfaceID = ObjectIdentifier(owned)
        } else if candidates.isEmpty, let owned = validatedSurface,
                  owned.superlayer === root {
            surface = owned
        } else {
            fail("surface ownership changed; layer mapping needs revalidation")
            return
        }
        guard surface.superlayer === root,
              let present = surface.presentation(), present.model() === surface,
              let rootPresent = present.superlayer, rootPresent.model() === root,
              rootPresent.isGeometryFlipped, rootPresent.bounds.origin == .zero else {
            fail("surface presentation identity unavailable")
            return
        }
        // Convert actual presentation geometry instead of assuming a child
        // order, zero anchor or identity model transform. SwiftUI briefly uses
        // a nonidentity model transform during otherwise stationary updates.
        let rect = present.convert(present.bounds, to: rootPresent)
        let top = rect.minY - rootPresent.bounds.minY
        guard top.isFinite, rect.width.isFinite, rect.height.isFinite else {
            fail("surface presentation coordinates are not finite")
            return
        }
        append(PresentationSample(time: time, top: top,
            modelTop: surface.convert(surface.bounds, to: root).minY,
            hostHeight: host.bounds.height,
            surfaceIdentifier: String(describing: ObjectIdentifier(surface)), mappingError: nil))
    }
    func verifyTopAnchor(_ segment: Segment) -> Bool {
        lock.lock()
        let values = presentationSamples.filter { $0.time >= segment.start && $0.time <= segment.end }
        lock.unlock()
        let invalid = values.compactMap { $0.mappingError }
        let tops = values.compactMap { $0.top }
        let peak = tops.map { abs($0) }.max() ?? .infinity
        let hoverDelay = IslandMotion.hoverEnterDelay.components
        let openingTime = segment.start + Double(hoverDelay.seconds) + Double(hoverDelay.attoseconds) / 1e18
        let early = values.filter { $0.mappingError == nil && $0.top != nil && $0.time >= openingTime && $0.time <= openingTime + 0.20 }
        let firstEarly = early.first.map { $0.time - openingTime } ?? .infinity
        let passed = invalid.isEmpty && tops.count >= 12 && early.count >= 5 && firstEarly <= 0.06 && peak <= 1
        print(String(format: "%@ %@ top-anchor: peak=%.2fpt samples=%d early=%d mappingErrors=%d",
                     passed ? "PASS" : "FAIL", segment.name, Double(peak), tops.count, early.count, invalid.count))
        if let firstError = invalid.first { print("  \(firstError)") }
        return passed
    }
    func verify(_ segment: Segment) -> Bool {
        let values = snapshot().filter { $0.time >= segment.start && $0.time <= segment.end }
        let span = segment.targetHeight - segment.hoverHeight
        guard span > 1 else {
            print("FAIL \(segment.name): expanded content did not acquire a measurable height")
            return false
        }
        let midflight = values.filter {
            let heightProgress = ($0.height - segment.hoverHeight) / span
            return (0.25...0.75).contains(heightProgress)
        }
        let error = midflight.map { abs($0.expansion - ($0.height - segment.hoverHeight) / span) }.max() ?? .infinity
        let intermediate = Set(midflight.map { Int(($0.height * 100).rounded()) }).count
        let ended = values.last.map { abs($0.height - segment.targetHeight) < 1 } ?? false
        let passed = error < 0.08 && intermediate >= 3 && ended
        print(String(format: "%@ %@: shape/height error=%.4f intermediate=%d settled=%@",
                     passed ? "PASS" : "FAIL", segment.name, Double(error), intermediate, ended ? "yes" : "no"))
        return passed
    }
    func writeTrace(to path: String, segments: [Segment]) throws {
        struct Trace: Encodable {
            let kind = "SwiftUI shape evaluation and owned presentation top; not display frames or FPS"
            let samples: [Sample]
            let presentationSamples: [PresentationSample]
            let segments: [Segment]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lock.lock()
        let presentation = presentationSamples
        lock.unlock()
        try encoder.encode(Trace(samples: snapshot(), presentationSamples: presentation, segments: segments)).write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
private final class TestPointer {
    var inside = false
    func location() -> NSPoint {
        guard inside, let panel = NSApplication.shared.windows.first(where: { $0 is IslandPanel }) else {
            return NSPoint(x: -20000, y: -20000)
        }
        return NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 10)
    }
}

@MainActor
private final class OffscreenPanels {
    private var moving = false
    func conceal(_ object: Any?) {
        guard !moving, let panel = object as? IslandPanel else { return }
        moving = true
        panel.alphaValue = 0.001
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        moving = false
    }
}

@main
struct MotionVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard !NSScreen.screens.isEmpty else {
            fputs("FAIL motion verification requires an active macOS graphical session. Run outside the sandbox.\n", stderr)
            exit(1)
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            print("SKIP native motion interpolation checks: Reduce Motion is enabled in system settings")
            exit(0)
        }
        let recorder = MotionRecorder()
        MotionVerificationSamples.onPath = { recorder.record(width: $0, height: $1, expansion: $2) }
        let suiteName = "LingChongDao.MotionVerification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        model.settings.haptics = false
        model.loadPreview("running")
        let pointer = TestPointer()
        let offscreen = OffscreenPanels()
        let center = NotificationCenter.default
        let moveObserver = center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { offscreen.conceal(note.object) }
        }
        let resizeObserver = center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { offscreen.conceal(note.object) }
        }
        var capturedContext: IslandWindowContext?
        let coordinator = IslandWindowCoordinator(pointerLocation: { pointer.location() }) { context in
            capturedContext = context
            return AnyView(IslandView(model: model, context: context))
        }
        coordinator.update(enabled: true, idleVisible: true, showOnOtherDisplays: false,
                           hasSessions: true, widthPercent: 100, heightPercent: 100)
        for window in app.windows { offscreen.conceal(window) }
        guard let context = capturedContext else {
            fputs("FAIL test coordinator did not create a display context\n", stderr)
            coordinator.stop()
            center.removeObserver(moveObserver)
            center.removeObserver(resizeObserver)
            defaults.removePersistentDomain(forName: suiteName)
            exit(1)
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func enter() {
            pointer.inside = true
            context.setHovered(active: true, hasActivity: true)
        }
        func close() {
            pointer.inside = false
            context.collapse()
            context.setHovered(active: false, hasActivity: true)
        }
        func refreshPreview(after delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.loadPreview("running") }
        }
        var segments: [MotionRecorder.Segment] = []
        var results: [Bool] = []
        var topResults: [Bool] = []
        let presentationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { recorder.observePresentation() }
        }
        RunLoop.main.add(presentationTimer, forMode: .common)
        func finish(_ name: String, since start: Double, expectedIdle: Bool = false) {
            let segment = MotionRecorder.Segment(name: name, start: start, end: recorder.now,
                hoverHeight: context.compactHeight + IslandMotion.hoverHeight, targetHeight: context.contentHeight)
            segments.append(segment)
            results.append(context.expanded && context.idleEncounterActive == expectedIdle && recorder.verify(segment))
            topResults.append(recorder.verifyTopAnchor(segment))
        }
        wait(1.0) // Let the real hidden expanded layer measure its destination.
        for round in 1...3 {
            let coldStart = recorder.now
            enter()
            refreshPreview(after: 0.08)
            wait(0.85)
            finish("cold-\(round)", since: coldStart)
            close()
            wait(0.30) // Reenter while the preceding closing spring is still settling.
            let warmStart = recorder.now
            enter()
            refreshPreview(after: 0.08)
            wait(0.85)
            finish("warm-\(round)", since: warmStart)
            close()
            wait(0.90) // Exceeds the production 620 ms canvas-release delay.
        }
        for pulse in [0.08, 0.18] {
            close()
            wait(0.90)
            let start = recorder.now
            enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + pulse) {
                // A native view exit can race the coordinator's still-inside
                // sample. The injected pointer remains inside throughout.
                context.setHovered(active: false, hasActivity: true)
            }
            refreshPreview(after: 0.10)
            wait(0.95)
            finish("view-exit-\(Int(pulse * 1000))ms", since: start)
        }
        close()
        model.endPreview()
        coordinator.update(enabled: true, idleVisible: true, showOnOtherDisplays: false,
                           hasSessions: false, widthPercent: 100, heightPercent: 100)
        context.setHovered(active: false, hasActivity: false)
        wait(0.9)
        let idleStart = recorder.now
        pointer.inside = true
        context.setHovered(active: true, hasActivity: false)
        wait(1.05)
        finish("idle-boss-encounter", since: idleStart, expectedIdle: true)
        if let tracePath = ProcessInfo.processInfo.environment["LINGCHONGDAO_MOTION_TRACE"] {
            do { try recorder.writeTrace(to: tracePath, segments: segments) }
            catch { fputs("FAIL could not write requested motion trace: \(error)\n", stderr); results.append(false) }
        }
        presentationTimer.invalidate()
        coordinator.stop()
        center.removeObserver(moveObserver)
        center.removeObserver(resizeObserver)
        defaults.removePersistentDomain(forName: suiteName)
        MotionVerificationSamples.onPath = nil
        let passed = results.filter { $0 }.count
        print("\(passed == results.count ? "PASS" : "FAIL") \(passed)/\(results.count) native motion synchronization checks; offscreen fixtures only")
        let topPassed = topResults.filter { $0 }.count
        print("\(topPassed == topResults.count ? "PASS" : "FAIL") \(topPassed)/\(topResults.count) native presentation top-anchor checks; not FPS")
        exit(results.allSatisfy { $0 } && topResults.allSatisfy { $0 } ? 0 : 1)
    }
}
