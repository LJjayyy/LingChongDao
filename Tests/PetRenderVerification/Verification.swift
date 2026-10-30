import AppKit
import Darwin
import Foundation
import ImageIO
import IslandCore
import IslandPets

private enum CheckError: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw CheckError.failed(message) }
    print("PASS \(message)")
}
private func mustThrow(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { print("PASS \(message)"); return }
    throw CheckError.failed(message)
}
private func image(width: Int = 16, height: Int = 16, green: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: green ? 0 : 1, green: green ? 1 : 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
private func png(_ image: CGImage) -> Data {
    let bytes = NSMutableData()
    let output = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output)); return bytes as Data
}
private func gif() -> Data {
    let bytes = NSMutableData()
    let output = CGImageDestinationCreateWithData(bytes, "com.compuserve.gif" as CFString, 2, nil)!
    for (index, delay) in [0.08, 0.12].enumerated() {
        CGImageDestinationAddImage(output, image(green: index == 1), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(output)); return bytes as Data
}

@main
struct PetRendererVerification {
    static func main() async {
        do { try await verify() }
        catch { FileHandle.standardError.write(Data("FAIL pet renderer: \(error)\n".utf8)); exit(1) }
    }
    static func verify() async throws {
        let still = PetAnimationResource(data: png(image(width: 256, height: 256)), stillData: nil, spriteLayout: nil)
        let decoded = try PetAnimationDecoder.decode(still, stillOnly: false)
        try require(decoded.frames.count == 1 && decoded.frames[0].size.width <= 128, "Static source image is decoded and bounded for the island")
        let animated = PetAnimationResource(data: gif(), stillData: nil, spriteLayout: nil)
        let loop = try PetAnimationDecoder.decode(animated, stillOnly: false)
        try require(loop.frames.count == 2 && abs(loop.duration - 0.2) < 0.02, "Animated container preserves frame count and timing")
        try require(loop.frame(at: 0.03) === loop.frames[0] && loop.frame(at: 0.1) === loop.frames[1] && loop.frame(at: 0.23) === loop.frames[0], "Animation frame selection wraps at the actual duration")
        let reduced = try PetAnimationDecoder.decode(animated, stillOnly: true)
        try require(reduced.frames.count == 1, "Reduced motion decodes only the first frame")
        let sheet = png(image(width: 32, height: 32))
        let sprite = PetAnimationResource(data: sheet, stillData: nil, spriteLayout: PetSpriteLayout(columns: 2, rows: 2, row: 1, frameDurations: [0.1, 0.2]))
        let cells = try PetAnimationDecoder.decode(sprite, stillOnly: false)
        try require(cells.frames.count == 2 && cells.frames[0].size == NSSize(width: 16, height: 16), "Sprite grid selects the requested row without stretching cells")
        try require(try PetAnimationDecoder.decode(sprite, stillOnly: true).frames.count == 1, "Reduced motion uses a single sprite cell")
        try mustThrow("Malformed image data is refused") { _ = try PetAnimationDecoder.decode(PetAnimationResource(data: Data([1,2,3]), stillData: nil, spriteLayout: nil), stillOnly: false) }
        try mustThrow("A sprite row outside the sheet is refused") {
            _ = try PetAnimationDecoder.decode(PetAnimationResource(data: sheet, stillData: nil, spriteLayout: PetSpriteLayout(columns: 2, rows: 2, row: 2, frameDurations: [0.1])), stillOnly: false)
        }
        try mustThrow("A grid that cannot divide its sheet is refused") {
            _ = try PetAnimationDecoder.decode(PetAnimationResource(data: sheet, stillData: nil, spriteLayout: PetSpriteLayout(columns: 3, rows: 2, row: 0, frameDurations: [0.1])), stillOnly: false)
        }
        try mustThrow("Invalid animation timing is refused") {
            _ = try PetAnimationDecoder.decode(PetAnimationResource(data: sheet, stillData: nil, spriteLayout: PetSpriteLayout(columns: 2, rows: 2, row: 0, frameDurations: [0])), stillOnly: false)
        }
        try await verifyStore()
        if CommandLine.arguments.contains("--live") {
            let reader = LocalPetSourceReader()
            for provider in [ProviderID.qoder, .codex] {
                guard let appearance = try await reader.read(provider) else { throw CheckError.failed("No current \(provider.rawValue) pet found") }
                for state in PetAnimationState.allCases {
                    guard let resource = appearance.animations[state] else { throw CheckError.failed("Missing \(provider.rawValue) \(state)") }
                    let animation = try PetAnimationDecoder.decode(resource, stillOnly: false)
                    try require(!animation.frames.isEmpty, "Live \(provider.rawValue) / \(appearance.displayName) / \(state.rawValue): \(animation.frames.count) frames")
                }
            }
        }
        print("Pet renderer verification passed. No source application configuration was changed.")
    }

    @MainActor
    static func verifyStore() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lingchongdao-pet-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = PetSourceEnvironment(homeURL: home, appDirectories: [home.appendingPathComponent("Applications", isDirectory: true)])
        let reader = LocalPetSourceReader(environment: environment)
        let store = PetAppearanceStore(reader: reader)
        defer { store.stop() }

        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        func select(_ id: String) throws {
            try write(Data(("[desktop]\nselected-avatar-id = \"" + id + "\"\n").utf8), to: environment.codexHomeURL.appendingPathComponent("config.toml"))
        }
        func install(_ id: String, green: Bool, version: Int = 1) throws {
            let directory = environment.codexHomeURL.appendingPathComponent("pets/" + id, isDirectory: true)
            let manifest: [String: Any] = ["displayName": "Synthetic " + id, "spriteVersionNumber": version, "spritesheetPath": "spritesheet.png"]
            try write(JSONSerialization.data(withJSONObject: manifest), to: directory.appendingPathComponent("pet.json"))
            try write(png(image(width: 128, height: version == 2 ? 176 : 144, green: green)), to: directory.appendingPathComponent("spritesheet.png"))
        }
        func frameIDs(_ animation: DecodedPetAnimation?) -> [ObjectIdentifier]? { animation?.frames.map(ObjectIdentifier.init) }

        await store.refresh()
        try require(store.appearance(for: .codex) == nil && store.animation(for: .codex, state: .idle, reducedMotion: false) == nil,
                    "Store starts with no pet when the source is missing")
        try install("first", green: false)
        try select("custom:first")
        // Match SwiftUI replacing its initial .task immediately after a revision arrives.
        // Cancelling this caller must not discard decoding owned by the shared store.
        let cancelled = Task { @MainActor in
            await store.prepare(source: .codex, state: .idle, reducedMotion: false)
        }
        cancelled.cancel()
        await cancelled.value
        guard let first = store.appearance(for: .codex), let idle = store.animation(for: .codex, state: .idle, reducedMotion: false) else {
            throw CheckError.failed("Cancelled first caller did not populate the shared store")
        }
        try require(first.selectionID == "custom:first" && idle.frames.count == 6,
                    "First missing-to-loaded prepare caches frames even when its caller is immediately cancelled")

        try require(store.isPetEnabled(for: .codex), "A selected source pet follows Codex's default visible setting")
        let visibilityConfig = environment.codexHomeURL.appendingPathComponent("config.toml")
        try write(Data("[desktop]\nselected-avatar-id = \"custom:first\"\navatar-overlay-pet-visible = false\n".utf8), to: visibilityConfig)
        await store.refresh()
        try require(!store.isPetEnabled(for: .codex) && store.appearance(for: .codex)?.revision == first.revision,
                    "Closing the source pet updates visibility even when its selection is unchanged")
        try require(frameIDs(store.animation(for: .codex, state: .idle, reducedMotion: false)) == frameIDs(idle),
                    "Connection icon visibility does not discard the island's existing animation cache")
        try write(Data("[desktop]\nselected-avatar-id = \"custom:first\"\navatar-overlay-pet-visible = true\n".utf8), to: visibilityConfig)
        await store.refresh()
        try require(store.isPetEnabled(for: .codex), "Re-enabling the source pet updates the same store without restart")

        var callers: [Task<[ObjectIdentifier]?, Never>] = []
        for _ in 0..<8 {
            callers.append(Task { @MainActor in
                await store.prepare(source: .codex, state: .running, reducedMotion: false)
                return frameIDs(store.animation(for: .codex, state: .running, reducedMotion: false))
            })
        }
        callers[0].cancel(); callers[3].cancel()
        var results: [[ObjectIdentifier]?] = []
        for task in callers { results.append(await task.value) }
        guard let running = store.animation(for: .codex, state: .running, reducedMotion: false), let shared = frameIDs(running) else {
            throw CheckError.failed("Concurrent prepares did not cache running frames")
        }
        try require(running.frames.count == 6 && results.allSatisfy({ $0 == shared }),
                    "Concurrent same-key callers, including cancelled callers, observe the same cached frame objects")
        try require(frameIDs(store.animation(for: .codex, state: .idle, reducedMotion: false)) == frameIDs(idle),
                    "Preparing another state retains an already-visible state's cached frames")

        await store.prepare(source: .codex, state: .running, reducedMotion: true)
        let reduced = store.animation(for: .codex, state: .running, reducedMotion: true)
        try require(reduced?.frames.count == 1,
                    "Store reduced-motion preparation caches one frame")
        try require(frameIDs(store.animation(for: .codex, state: .running, reducedMotion: false)) == shared,
                    "Reduced-motion preparation preserves the full animation cache")
        await store.prepare(source: .codex, state: .running, reducedMotion: false)
        try require(frameIDs(store.animation(for: .codex, state: .running, reducedMotion: false)) == shared
                    && frameIDs(store.animation(for: .codex, state: .running, reducedMotion: true)) == frameIDs(reduced),
                    "Switching reduced motion off reuses the full animation without replacing either cache")

        try install("second", green: true, version: 2)
        try select("custom:second")
        await store.refresh()
        try require(store.appearance(for: .codex)?.selectionID == "custom:second" && store.appearance(for: .codex)?.revision != first.revision,
                    "A synthetic source selection change publishes a new revision")
        try require(store.animation(for: .codex, state: .idle, reducedMotion: false) == nil
                    && store.animation(for: .codex, state: .running, reducedMotion: false) == nil
                    && store.animation(for: .codex, state: .running, reducedMotion: true) == nil,
                    "A source revision change clears every old state and reduced-motion variant")
        await store.prepare(source: .codex, state: .running, reducedMotion: false)
        guard let updated = store.animation(for: .codex, state: .running, reducedMotion: false) else {
            throw CheckError.failed("New source revision did not decode")
        }
        try require(updated.frames.count == 6 && frameIDs(updated) != shared,
                    "New source revision decodes new frame objects")
        guard let cgImage = updated.frames.first?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let color = NSBitmapImageRep(cgImage: cgImage).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            throw CheckError.failed("Synthetic changed frame color could not be inspected")
        }
        try require(color.greenComponent > 0.9 && color.redComponent < 0.1,
                    "Changed source artwork, rather than the previous pet's frames, reaches the cache")
        try select("custom:missing")
        await store.refresh()
        try require(store.appearance(for: .codex) == nil && store.animation(for: .codex, state: .running, reducedMotion: false) == nil,
                    "A newly missing selected pet clears the prior appearance and frames")
    }

}
