import AppKit
import ImageIO
import SwiftUI

/// The island's own mascot, used when no connected provider has an active pet.
@MainActor
struct DefaultPetView: View {
    var size: CGFloat = 20
    var isAttentive: Bool = false
    var reactionToken: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var reactionQueue = BossPetReactionQueue()
    @ViewState private var performanceStartedAt: Date?
    @ViewState private var performanceID = 0
    @ViewState private var idleSequence: BossPetIdleSequence?
    @ViewState private var idleStartedAt: Date?
    @ViewState private var staticReactionUntil: Date?
    @ViewState private var staticReactionID = 0
    @ViewState private var pointerInside = false

    private struct IdleTaskKey: Equatable {
        let reduceMotion: Bool
        let attentive: Bool
        let reactionPlaying: Bool
    }

    private struct PerformanceAtlasManifest: Decodable {
        struct Frame: Decodable {
            let x: Int
            let y: Int
            let width: Int
            let height: Int
        }
        let version: Int
        let sheetWidth: Int
        let sheetHeight: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let bottomInset: Int
        let frames: [Frame]
    }

    private static let assets = loadAssets()
    private var attentive: Bool { isAttentive || pointerInside }
    private var idleTaskKey: IdleTaskKey {
        IdleTaskKey(reduceMotion: reduceMotion, attentive: attentive,
                    reactionPlaying: reactionQueue.isPlaying)
    }
    private var isTimelineActive: Bool {
        !reduceMotion && (performanceStartedAt != nil || idleStartedAt != nil)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isTimelineActive)) { timeline in
            let frame = BossPetMotion.frame(
                now: timeline.date,
                performanceStartedAt: performanceStartedAt,
                idleSequence: idleSequence,
                idleStartedAt: idleStartedAt,
                isAttentive: attentive,
                reduceMotion: reduceMotion,
                staticReactionActive: staticReactionUntil != nil,
                size: Double(size)
            )
            if let image = Self.image(for: frame.index) {
                Image(nsImage: image)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: size, height: size)
                    .scaleEffect(x: frame.scaleX, y: frame.scaleY, anchor: .bottom)
                    .rotationEffect(.degrees(frame.rotationDegrees), anchor: .bottom)
                    .offset(x: frame.offsetX, y: frame.offsetY)
            } else {
                Image(systemName: "computermouse.fill")
                    .resizable().scaledToFit().padding(size * 0.12)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("灵宠岛默认灵宠：老板鼠")
        .help("空闲时由老板鼠值班")
        .onHover { pointerInside = $0 }
        .task(id: idleTaskKey) { await runIdleSequence(for: idleTaskKey) }
        .task(id: performanceID) { await finishPerformance(id: performanceID) }
        .task(id: staticReactionID) { await finishStaticReaction(id: staticReactionID) }
        .onChange(of: reactionToken) { _, _ in startReaction() }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled, reactionQueue.isPlaying {
                cancelPerformance()
                showStaticReaction()
            }
        }
        .onDisappear(perform: resetMotion)
    }

    private func startReaction() {
        switch reactionQueue.request(reduceMotion: reduceMotion) {
        case .queued:
            break
        case .staticPoint:
            cancelPerformance()
            showStaticReaction()
        case .start:
            staticReactionUntil = nil
            staticReactionID += 1
            beginPerformance()
        }
    }

    private func beginPerformance() {
        performanceStartedAt = Date()
        performanceID += 1
    }

    private func finishPerformance(id: Int) async {
        guard id == performanceID, let startedAt = performanceStartedAt else { return }
        let remaining = BossPetMotion.performanceDuration - Date().timeIntervalSince(startedAt)
        do {
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try Task.checkCancellation()
        } catch {
            return
        }
        guard id == performanceID, performanceStartedAt == startedAt else { return }
        if reactionQueue.complete() {
            beginPerformance()
        } else {
            performanceStartedAt = nil
        }
    }

    private func cancelPerformance() {
        reactionQueue.cancel()
        performanceStartedAt = nil
        performanceID += 1
    }

    private func showStaticReaction() {
        staticReactionUntil = Date().addingTimeInterval(BossPetMotion.staticReactionDuration)
        staticReactionID += 1
    }

    private func finishStaticReaction(id: Int) async {
        guard id == staticReactionID, let end = staticReactionUntil else { return }
        let remaining = end.timeIntervalSinceNow
        do {
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try Task.checkCancellation()
        } catch {
            return
        }
        guard id == staticReactionID, staticReactionUntil == end else { return }
        staticReactionUntil = nil
    }

    private func runIdleSequence(for key: IdleTaskKey) async {
        idleSequence = nil
        idleStartedAt = nil
        guard !key.reduceMotion, !key.attentive, !key.reactionPlaying else { return }

        var cycle = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Double.random(in: BossPetMotion.idleIntervalRange)))
                try Task.checkCancellation()
            } catch {
                return
            }
            cycle += 1
            let sequence: BossPetIdleSequence = cycle.isMultiple(of: 4) ? .inspect : .blink
            idleSequence = sequence
            idleStartedAt = Date()
            do {
                try await Task.sleep(for: .seconds(sequence.duration))
                try Task.checkCancellation()
            } catch {
                return
            }
            idleSequence = nil
            idleStartedAt = nil
        }
    }

    private func resetMotion() {
        cancelPerformance()
        idleSequence = nil
        idleStartedAt = nil
        staticReactionUntil = nil
        staticReactionID += 1
    }

    private static func image(for index: Int) -> NSImage? {
        guard assets.frames.indices.contains(index) else { return assets.fallback }
        return assets.frames[index]
    }

    private static func loadAssets() -> (frames: [NSImage], fallback: NSImage?) {
        if let url = resourceURL(named: "boss-mouse-performance"),
           let manifestURL = resourceURL(named: "boss-mouse-performance", extension: "json"),
           let frames = cropPerformance(url: url, manifestURL: manifestURL), frames.count == 16 {
            return (frames, frames[0])
        }

        // Keep old installs/dev checkouts usable until the performance sheet is
        // copied into the app bundle.
        if let url = resourceURL(named: "boss-mouse-actions"),
           let oldFrames = crop(url: url, columns: 2, rows: 2), oldFrames.count == 4 {
            let remap = [0, 0, 2, 2, 2, 2, 3, 2, 3, 3, 3, 3, 2, 0, 0, 0]
            return (remap.map { oldFrames[$0] }, oldFrames[0])
        }

        let fallback = resourceURL(named: "boss-mouse").flatMap { NSImage(contentsOf: $0) }
        let repeatedFrames = fallback.map { Array(repeating: $0, count: 16) } ?? []
        return (repeatedFrames, fallback)
    }

    private static func crop(url: URL, columns: Int, rows: Int) -> [NSImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sheet.width >= columns, sheet.height >= rows else { return nil }
        var frames: [NSImage] = []
        frames.reserveCapacity(columns * rows)
        for index in 0..<(columns * rows) {
            let column = index % columns
            let row = index / columns
            let x0 = Int((Double(column) * Double(sheet.width) / Double(columns)).rounded())
            let x1 = Int((Double(column + 1) * Double(sheet.width) / Double(columns)).rounded())
            let y0 = Int((Double(row) * Double(sheet.height) / Double(rows)).rounded())
            let y1 = Int((Double(row + 1) * Double(sheet.height) / Double(rows)).rounded())
            let rect = CGRect(x: CGFloat(x0), y: CGFloat(y0),
                              width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
            guard let frame = sheet.cropping(to: rect) else { return nil }
            frames.append(NSImage(cgImage: frame,
                                  size: NSSize(width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))))
        }
        return frames
    }

    private static func cropPerformance(url: URL, manifestURL: URL) -> [NSImage]? {
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PerformanceAtlasManifest.self, from: manifestData),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              manifest.version == 1, manifest.sheetWidth == sheet.width, manifest.sheetHeight == sheet.height,
              manifest.canvasWidth > 0, manifest.canvasHeight > 0,
              manifest.bottomInset >= 0, manifest.frames.count == 16 else { return nil }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var frames: [NSImage] = []
        frames.reserveCapacity(manifest.frames.count)
        for box in manifest.frames {
            guard box.x >= 0, box.y >= 0, box.width > 0, box.height > 0,
                  box.x + box.width <= sheet.width, box.y + box.height <= sheet.height,
                  box.width <= manifest.canvasWidth,
                  box.height + manifest.bottomInset <= manifest.canvasHeight,
                  let crop = sheet.cropping(to: CGRect(x: CGFloat(box.x), y: CGFloat(box.y),
                                                       width: CGFloat(box.width), height: CGFloat(box.height))),
                  let context = CGContext(data: nil,
                                          width: manifest.canvasWidth,
                                          height: manifest.canvasHeight,
                                          bitsPerComponent: 8,
                                          bytesPerRow: manifest.canvasWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return nil }
            let canvas = CGRect(x: 0, y: 0,
                                width: CGFloat(manifest.canvasWidth), height: CGFloat(manifest.canvasHeight))
            context.clear(canvas)
            context.interpolationQuality = .high
            let origin = CGPoint(x: CGFloat((manifest.canvasWidth - box.width) / 2),
                                 y: CGFloat(manifest.bottomInset))
            let size = CGSize(width: CGFloat(box.width), height: CGFloat(box.height))
            context.draw(crop, in: CGRect(origin: origin, size: size))
            guard let normalized = context.makeImage() else { return nil }
            frames.append(NSImage(cgImage: normalized,
                                  size: NSSize(width: CGFloat(manifest.canvasWidth),
                                               height: CGFloat(manifest.canvasHeight))))
        }
        return frames
    }

    private static func resourceURL(named name: String, extension fileExtension: String = "png") -> URL? {
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "DefaultPet") {
            return bundledURL
        }
        // A packaged app must use its own resources, independent of the checkout.
        // Direct `swift run` can load the repository's artwork directory.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("assets/default-pet/\(name).\(fileExtension)")
    }
}
