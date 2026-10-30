import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "island.enabled") } }
    @Published var idleVisible: Bool { didSet { defaults.set(idleVisible, forKey: "island.idleVisible") } }
    @Published var additionalDisplays: Bool { didSet { defaults.set(additionalDisplays, forKey: "island.additionalDisplays") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "island.haptics") } }
    @Published var autoClearFinishedOnAppFocus: Bool { didSet { defaults.set(autoClearFinishedOnAppFocus, forKey: "island.autoClearFinishedOnAppFocus") } }
    @Published var autoRevealOnFinish: Bool { didSet { defaults.set(autoRevealOnFinish, forKey: "island.autoRevealOnFinish") } }
    @Published var widthPercent: Double { didSet { defaults.set(widthPercent, forKey: "island.widthPercent") } }
    @Published var heightPercent: Double { didSet { defaults.set(heightPercent, forKey: "island.heightPercent") } }
    @Published var showQoder: Bool { didSet { defaults.set(showQoder, forKey: "sources.qoder") } }
    @Published var showClaude: Bool { didSet { defaults.set(showClaude, forKey: "sources.claude") } }
    @Published var showCodex: Bool { didSet { defaults.set(showCodex, forKey: "sources.codex") } }
    @Published var showZCode: Bool { didSet { defaults.set(showZCode, forKey: "sources.zcode") } }
    @Published var showDSH: Bool { didSet { defaults.set(showDSH, forKey: "sources.dsh") } }
    @Published var showCodeBuddy: Bool { didSet { defaults.set(showCodeBuddy, forKey: "sources.codebuddy") } }
    @Published var showWorkBuddy: Bool { didSet { defaults.set(showWorkBuddy, forKey: "sources.workbuddy") } }
    @Published var showGeneric: Bool { didSet { defaults.set(showGeneric, forKey: "sources.generic") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "island.enabled": true, "island.idleVisible": true,
            "island.additionalDisplays": false, "island.haptics": true,
            "island.autoClearFinishedOnAppFocus": true,
            "island.autoRevealOnFinish": true,
            "island.widthPercent": 100.0, "island.heightPercent": 100.0,
            "sources.claude": true, "sources.qoder": true, "sources.codex": true, "sources.zcode": true, "sources.dsh": true, "sources.codebuddy": true, "sources.workbuddy": true, "sources.generic": true
        ])
        enabled = defaults.bool(forKey: "island.enabled")
        idleVisible = defaults.bool(forKey: "island.idleVisible")
        additionalDisplays = defaults.bool(forKey: "island.additionalDisplays")
        haptics = defaults.bool(forKey: "island.haptics")
        autoClearFinishedOnAppFocus = defaults.bool(forKey: "island.autoClearFinishedOnAppFocus")
        autoRevealOnFinish = defaults.bool(forKey: "island.autoRevealOnFinish")
        widthPercent = min(130, max(100, defaults.double(forKey: "island.widthPercent")))
        heightPercent = min(125, max(75, defaults.double(forKey: "island.heightPercent")))
        showQoder = defaults.bool(forKey: "sources.qoder")
        showClaude = defaults.bool(forKey: "sources.claude")
        showCodex = defaults.bool(forKey: "sources.codex")
        showZCode = defaults.bool(forKey: "sources.zcode")
        showDSH = defaults.bool(forKey: "sources.dsh")
        showCodeBuddy = defaults.bool(forKey: "sources.codebuddy")
        showWorkBuddy = defaults.bool(forKey: "sources.workbuddy")
        showGeneric = defaults.bool(forKey: "sources.generic")
    }

    func resetSize() { widthPercent = 100; heightPercent = 100 }
}
