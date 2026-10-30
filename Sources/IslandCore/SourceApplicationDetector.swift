import Darwin
import Foundation

/// Only process identity and its full executable location are needed for source routing.
/// Command arguments and foreign process environments are intentionally never read.
public struct SourceProcessRecord: Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let executablePath: String
    public init(pid: Int32, parentPID: Int32, executablePath: String) {
        self.pid = pid; self.parentPID = parentPID; self.executablePath = executablePath
    }
}

public enum SourceApplicationDetector {
    private static let maximumAncestors = 48
    private static let maximumInfoPlistBytes = 1024 * 1024

    /// Detects this hook's source only from its live process ancestry. Inherited
    /// environment PIDs cannot establish a same-source relationship and are not read.
    public static func detect(provider: ProviderID) -> SourceApplicationID? {
        guard provider != .generic else { return nil }
        return detect(provider: provider, currentPID: getpid(),
                      processLookup: lookupProcess, bundleIdentifierLookup: lookupBundleIdentifier)
    }

    /// Pure routing seam used by synthetic tests. `bundleIdentifierLookup` receives
    /// only the outer `.app` URL from the verified process's full executable path.
    public static func detect(
        provider: ProviderID,
        currentPID: Int32,
        hintedPIDs: [Int32] = [],
        processLookup: (Int32) -> SourceProcessRecord?,
        bundleIdentifierLookup: (URL) -> String?
    ) -> SourceApplicationID? {
        guard provider != .generic else { return nil }
        let unknown: SourceApplicationID?
        switch provider { case .qoder: unknown = .qoderUnknown; case .codebuddy: unknown = .codebuddyUnknown; case .workbuddy: unknown = .workbuddyUnknown; case .claude: unknown = .claudeUnknown; case .dsh, .zcode, .codex, .generic: unknown = nil }
        guard currentPID > 1 else { return unknown }
        func application(for process: SourceProcessRecord) -> SourceApplicationID? {
            guard let bundle = outerApplication(for: process.executablePath), let identifier = bundleIdentifierLookup(bundle) else { return nil }
            switch provider {
            case .qoder:
                switch identifier {
                case "com.qodercn.app": return .qoderDesktop
                case "com.aliyun.lingma.ide": return .qoderIDE
                default: return nil
                }
            case .codex:
                // A terminal can launch the CLI shipped inside a desktop app.
                // Its resource or nested bundle location alone is not host evidence.
                let executable = URL(fileURLWithPath: process.executablePath).standardizedFileURL
                guard executable.deletingLastPathComponent().path == bundle.appendingPathComponent("Contents/MacOS").path else { return nil }
                switch identifier {
                case "com.openai.codex": return .codexDesktop
                case "com.openai.chat": return .codexChatGPT
                default: return nil
                }
            case .claude:
                // The embedded CLI lives in a separate claude.app bundle. Only
                // a verified host ancestor proves Desktop/IDE/terminal ownership.
                switch identifier {
                case "com.anthropic.claudefordesktop": return .claudeDesktop
                case "com.microsoft.VSCode": return .claudeVSCode
                case "com.todesktop.230313mzl4w4u92": return .claudeCursor
                case "com.jetbrains.intellij": return .claudeIntelliJ
                case "com.jetbrains.pycharm": return .claudePyCharm
                case "com.jetbrains.WebStorm": return .claudeWebStorm
                case "com.jetbrains.goland": return .claudeGoLand
                case "com.apple.Terminal": return .claudeTerminal
                case "com.googlecode.iterm2": return .claudeITerm
                case "dev.warp.Warp-Stable": return .claudeWarp
                default: return nil
                }
            case .zcode:
                // ZCode is a single Electron desktop bundle; any helper process
                // inside it still reports the outer application identity.
                return identifier == "dev.zcode.app" ? .zcodeDesktop : nil
            case .dsh:
                // The desktop carrier spawns the bridge hooks; only the outer
                // bundle proves this is the app rather than a terminal CLI run.
                return identifier == "com.deepseek.dsh" ? .dshDesktop : nil
            case .codebuddy:
                guard URL(fileURLWithPath: process.executablePath).standardizedFileURL.deletingLastPathComponent().path == bundle.appendingPathComponent("Contents/MacOS").path else { return nil }
                return identifier == "com.tencent.codebuddycn" ? .codebuddyCNIDE : nil
            case .workbuddy:
                guard URL(fileURLWithPath: process.executablePath).standardizedFileURL.deletingLastPathComponent().path == bundle.appendingPathComponent("Contents/MacOS").path else { return nil }
                switch identifier { case "com.tencent.workbuddy.mac": return .workbuddyDesktop; case "com.workbuddy.workbuddy-ai": return .workbuddyAI; default: return nil }
            case .generic: return nil
            }
        }
        var visited: Set<Int32> = []
        var pid = currentPID
        for _ in 0..<maximumAncestors {
            guard pid > 1, visited.insert(pid).inserted,
                  let process = processLookup(pid), process.pid == pid else { break }
            if let origin = application(for: process) { return origin }
            guard process.parentPID > 1, process.parentPID != pid else { break }
            pid = process.parentPID
        }
        // Retain this seam for callers/tests with legacy hints, but never route from
        // a PID that is not in the observed ancestor chain. A still-running app may
        // be unrelated to this hook or inherited from a previous hosting application.
        _ = hintedPIDs
        return unknown
    }

    private static func outerApplication(for executablePath: String) -> URL? {
        guard executablePath.hasPrefix("/"), !executablePath.utf8.contains(0), executablePath.utf8.count <= 4096 else { return nil }
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        let components = url.pathComponents
        guard let index = components.indices.first(where: { URL(fileURLWithPath: components[$0]).pathExtension.lowercased() == "app" }) else { return nil }
        // An app-looking folder elsewhere in a path is not sufficient evidence.
        guard index + 2 < components.count, components[index + 1] == "Contents" else { return nil }
        let path = NSString.path(withComponents: Array(components[...index]))
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func lookupBundleIdentifier(_ bundleURL: URL) -> String? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumInfoPlistBytes,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumInfoPlistBytes + 1), data.count <= maximumInfoPlistBytes,
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String, identifier.utf8.count <= 256 else { return nil }
        return identifier
    }

    private static func lookupProcess(_ pid: Int32) -> SourceProcessRecord? {
        guard pid > 1 else { return nil }
        var before = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, size) == size, before.pbi_pid == UInt32(pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let read = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard read > 0, read < Int32(buffer.count),
              let path = String(bytes: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8), path.hasPrefix("/") else { return nil }
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              before.pbi_pid == after.pbi_pid, before.pbi_ppid == after.pbi_ppid,
              before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
              let parentPID = Int32(exactly: after.pbi_ppid) else { return nil }
        return SourceProcessRecord(pid: pid, parentPID: parentPID, executablePath: path)
    }
}

/// Compatibility facade: this API deliberately remains Qoder-only.
public enum QoderSourceApplicationDetector {
    public static func detect(provider: ProviderID) -> SourceApplicationID? {
        guard provider == .qoder else { return nil }
        return SourceApplicationDetector.detect(provider: provider)
    }

    public static func detect(
        provider: ProviderID,
        currentPID: Int32,
        hintedPIDs: [Int32] = [],
        processLookup: (Int32) -> SourceProcessRecord?,
        bundleIdentifierLookup: (URL) -> String?
    ) -> SourceApplicationID? {
        guard provider == .qoder else { return nil }
        return SourceApplicationDetector.detect(provider: provider, currentPID: currentPID, hintedPIDs: hintedPIDs,
                                                processLookup: processLookup, bundleIdentifierLookup: bundleIdentifierLookup)
    }
}
