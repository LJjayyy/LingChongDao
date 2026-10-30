import AppKit
import IslandCore
import IslandPets
import SwiftUI

@MainActor
struct PetView: View {
    var source: ProviderID = .qoder
    var phase: SessionPhase? = nil
    var sourceApplication: SourceApplicationID? = nil
    var size: CGFloat = 20
    var requiresEnabledPet = false
    var applicationURL: URL? = nil
    @ObservedObject private var pets = PetAppearanceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    // The current Qoder pet reader belongs to the desktop app. The IDE has no
    // verified pet source, so keep its actual application icon instead.
    private var usesSourcePet: Bool {
        (source == .qoder || source == .codex)
            && (!requiresEnabledPet || pets.isPetEnabled(for: source))
            && (source != .qoder || sourceApplication == nil || sourceApplication == .qoderDesktop)
    }
    private var sourceName: String {
        if source == .qoder, sourceApplication == .qoderIDE { return "Qoder CN IDE" }
        if source == .qoder, sourceApplication == .qoderUnknown { return "Qoder CN（来源待识别）" }
        if sourceApplication == .codebuddyUnknown { return "CodeBuddy（来源待识别）" }
        if sourceApplication == .workbuddyUnknown { return "WorkBuddy（来源待识别）" }
        if sourceApplication == .workbuddyAI { return "WorkBuddy AI" }
        return source.displayName
    }
    private var state: PetAnimationState {
        switch phase {
        case .some(.running): return .running
        case .some(.waitingQuestion), .some(.waitingApproval): return .waiting
        case .some(.failed), .some(.interrupted): return .failed
        case .some(.completed), .some(.idle): return .review
        case .none: return .idle
        }
    }
    private var taskKey: String {
        "\(source.rawValue):\(sourceApplication?.rawValue ?? "default"):\(pets.appearance(for: source)?.revision ?? "missing"):\(state.rawValue):\(reducedMotion):\(usesSourcePet)"
    }
    private var label: String {
        if sourceApplication == .qoderUnknown || sourceApplication == .codebuddyUnknown || sourceApplication == .workbuddyUnknown { return sourceName }
        if usesSourcePet, let appearance = pets.appearance(for: source) { return "\(sourceName) 宠物：\(appearance.displayName)" }
        return "\(sourceName) 应用图标"
    }
    private var help: String {
        if usesSourcePet, let appearance = pets.appearance(for: source) { return "\(sourceName) · \(appearance.displayName)\n\(appearance.sourceDescription)" }
        if sourceApplication == .qoderUnknown || sourceApplication == .codebuddyUnknown || sourceApplication == .workbuddyUnknown { return "这条消息尚未识别具体来源应用。" }
        return "\(sourceName)：宠物未启用或素材不可用，显示来源应用图标。"
    }

    var body: some View {
        Group {
            if usesSourcePet, let animation = pets.animation(for: source, state: state, reducedMotion: reducedMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reducedMotion || animation.frames.count <= 1)) { timeline in
                    if let frame = animation.frame(at: timeline.date.timeIntervalSince1970) {
                        Image(nsImage: frame).resizable().interpolation(.high).scaledToFit()
                    }
                }
            } else if let icon = pets.applicationIcon(for: source, application: sourceApplication, applicationURL: applicationURL) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "sparkles").resizable().scaledToFit().padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(help)
        .task(id: taskKey) { if usesSourcePet { await pets.prepare(source: source, state: state, reducedMotion: reducedMotion) } }
    }
}
