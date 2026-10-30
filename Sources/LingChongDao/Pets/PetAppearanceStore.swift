import AppKit
import Combine
import Foundation
import IslandCore
import IslandPets

private actor PetAnimationDecodingEngine {
    func decode(_ resource: PetAnimationResource, stillOnly: Bool) throws -> DecodedPetAnimation {
        try Task.checkCancellation()
        return try PetAnimationDecoder.decode(resource, stillOnly: stillOnly)
    }
}

@MainActor
final class PetAppearanceStore: ObservableObject {
    static let shared = PetAppearanceStore()
    private struct AnimationKey: Hashable {
        let source: ProviderID
        let revision: String
        let state: PetAnimationState
        let reducedMotion: Bool
    }
    @Published private var appearances: [ProviderID: ProviderPetAppearance] = [:]
    @Published private var enabledPets: [ProviderID: Bool] = [:]
    @Published private var decoded: [AnimationKey: DecodedPetAnimation] = [:]
    private let reader: LocalPetSourceReader
    private var polling: Task<Void, Never>?
    private let decoder = PetAnimationDecodingEngine()
    private struct DecodeJob {
        let id = UUID()
        let task: Task<DecodedPetAnimation?, Never>
    }
    private var decoding: [AnimationKey: DecodeJob] = [:]
    private var readFailures: [ProviderID: Int] = [:]
    private var icons: [String: NSImage] = [:]

    init(reader: LocalPetSourceReader = LocalPetSourceReader()) { self.reader = reader }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        polling?.cancel(); polling = nil
        for job in decoding.values { job.task.cancel() }
        decoding.removeAll()
    }

    func refresh() async {
        for source in [ProviderID.qoder, .codex] {
            let enabled = (try? await reader.isPetEnabled(source)) ?? false
            if enabledPets[source] != enabled { enabledPets[source] = enabled }
            do {
                let appearance = try await reader.read(source)
                readFailures[source] = 0
                guard appearance?.revision != appearances[source]?.revision else { continue }
                appearances[source] = appearance
                decoded = decoded.filter { $0.key.source != source }
                cancelDecoding(for: source)
            } catch {
                // A short source save can temporarily lock or replace its settings.
                // Repeated failures fall back to the application icon instead of
                // presenting an old pet as the current selection indefinitely.
                readFailures[source, default: 0] += 1
                if readFailures[source, default: 0] >= 3, appearances[source] != nil {
                    appearances[source] = nil
                    decoded = decoded.filter { $0.key.source != source }
                    cancelDecoding(for: source)
                }
            }
        }
    }

    func isPetEnabled(for source: ProviderID) -> Bool { enabledPets[source] ?? false }

    func appearance(for source: ProviderID) -> ProviderPetAppearance? { appearances[source] }

    func animation(for source: ProviderID, state: PetAnimationState, reducedMotion: Bool) -> DecodedPetAnimation? {
        guard let appearance = appearances[source] else { return nil }
        return decoded[AnimationKey(source: source, revision: appearance.revision, state: state, reducedMotion: reducedMotion)]
    }

    func prepare(source: ProviderID, state: PetAnimationState, reducedMotion: Bool) async {
        if appearances[source] == nil { await refresh() }
        guard let appearance = appearances[source], let resource = appearance.animations[state] ?? appearance.animations[.idle] else { return }
        let key = AnimationKey(source: source, revision: appearance.revision, state: state, reducedMotion: reducedMotion)
        guard decoded[key] == nil else { return }
        let job: DecodeJob
        if let pending = decoding[key] { job = pending }
        else {
            let decoder = self.decoder
            job = DecodeJob(task: Task.detached(priority: .utility) { try? await decoder.decode(resource, stillOnly: reducedMotion) })
            decoding[key] = job
        }
        let animation = await job.task.value
        if decoding[key]?.id == job.id { decoding.removeValue(forKey: key) }
        // The cache belongs to this store. A SwiftUI task may be replaced while
        // its source revision first arrives; it must not discard shared decoding.
        guard appearances[source]?.revision == key.revision, let animation else { return }
        if decoded[key] == nil { decoded[key] = animation }
        // Keep every state of the current two appearances; removing a visible
        // state's frames would leave its unchanged View task without a reload.
        // Pixel/frame limits bound each animation, and source changes clear it.
    }

    private func cancelDecoding(for source: ProviderID) {
        for key in Array(decoding.keys) where key.source == source {
            decoding.removeValue(forKey: key)?.task.cancel()
        }
    }

    func applicationIcon(for source: ProviderID, application: SourceApplicationID? = nil, applicationURL: URL? = nil) -> NSImage? {
        if let applicationURL, FileManager.default.fileExists(atPath: applicationURL.path) {
            let key = applicationURL.path
            if let cached = icons[key] { return cached }
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            icons[key] = icon
            return icon
        }
        let bundleID: String
        if let application, application.provider == source {
            guard let identifier = application.bundleIdentifier else { return nil }
            bundleID = identifier
        } else {
            switch source { case .qoder: bundleID = "com.qodercn.app"; case .claude: bundleID = "com.anthropic.claudefordesktop"; case .codex: bundleID = "com.openai.codex"; case .zcode: bundleID = "dev.zcode.app"; case .dsh: bundleID = "com.deepseek.dsh"; case .codebuddy: bundleID = "com.tencent.codebuddycn"; case .workbuddy: bundleID = "com.tencent.workbuddy.mac"; case .generic: return nil }
        }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}
