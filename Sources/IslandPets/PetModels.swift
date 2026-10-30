import Foundation
import IslandCore

public enum PetAnimationState: String, Sendable, CaseIterable { case idle, running, waiting, review, failed }

public struct PetSpriteLayout: Sendable {
    public var columns: Int
    public var rows: Int
    public var row: Int
    public var frameDurations: [TimeInterval]
    public init(columns: Int, rows: Int, row: Int, frameDurations: [TimeInterval]) {
        self.columns = columns; self.rows = rows; self.row = row; self.frameDurations = frameDurations
    }
}

public struct PetAnimationResource: Sendable {
    public var data: Data
    public var stillData: Data?
    public var spriteLayout: PetSpriteLayout?
    public init(data: Data, stillData: Data? = nil, spriteLayout: PetSpriteLayout? = nil) {
        self.data = data; self.stillData = stillData; self.spriteLayout = spriteLayout
    }
}

public struct ProviderPetAppearance: Sendable {
    public var selectionID: String
    public var displayName: String
    public var revision: String
    public var sourceDescription: String
    public var animations: [PetAnimationState: PetAnimationResource]
    public init(selectionID: String, displayName: String, revision: String, sourceDescription: String, animations: [PetAnimationState: PetAnimationResource]) {
        self.selectionID = selectionID; self.displayName = displayName; self.revision = revision
        self.sourceDescription = sourceDescription; self.animations = animations
    }
}

public struct PetSourceEnvironment: Sendable {
    public var homeURL: URL
    public var appDirectories: [URL]
    public var qoderDataURL: URL
    public var codexHomeURL: URL
    public init(homeURL: URL, appDirectories: [URL], qoderDataURL: URL? = nil, codexHomeURL: URL? = nil) {
        self.homeURL = homeURL
        self.appDirectories = appDirectories
        self.qoderDataURL = qoderDataURL ?? homeURL.appendingPathComponent("Library/Application Support/com.qodercn.app.stable", isDirectory: true)
        self.codexHomeURL = codexHomeURL ?? homeURL.appendingPathComponent(".codex", isDirectory: true)
    }
    public static func live() -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
        return .init(homeURL: home, appDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)], codexHomeURL: override)
    }
}

public enum PetSourceError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

extension PetSpriteLayout {
    static func sheet(_ state: PetAnimationState, version: Int) -> Self {
        let rows = version == 2 ? 11 : 9
        switch state {
        case .idle: return .init(columns: 8, rows: rows, row: 0, frameDurations: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320].map { $0 * 6 })
        case .running: return .init(columns: 8, rows: rows, row: 7, frameDurations: Array(repeating: 0.120, count: 5) + [0.220])
        case .waiting: return .init(columns: 8, rows: rows, row: 6, frameDurations: Array(repeating: 0.150, count: 5) + [0.260])
        case .review: return .init(columns: 8, rows: rows, row: 8, frameDurations: Array(repeating: 0.150, count: 5) + [0.280])
        case .failed: return .init(columns: 8, rows: rows, row: 5, frameDurations: Array(repeating: 0.140, count: 7) + [0.240])
        }
    }
}
