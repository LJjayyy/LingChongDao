import Darwin
import Foundation

enum ClamshellSleepGuardError: Error, Equatable {
    case authorizationCancelled, authorizationDenied, launchFailed, startupTimedOut, stateVerificationFailed, cleanupRequired
    var userMessage: String? {
        switch self {
        case .authorizationCancelled: return nil
        case .authorizationDenied: return "管理员权限被拒绝，请重新授权。"
        case .launchFailed: return "合盖防休眠辅助程序无法启动，请重试。"
        case .startupTimedOut: return "等待授权或启动超时，已请求关闭，请先确认关闭状态。"
        case .stateVerificationFailed: return "未能确认合盖防休眠已开启，请重试。"
        case .cleanupRequired: return "上次合盖防休眠尚未确认恢复，请先重试关闭。"
        }
    }
    static func authorizationError(_ message: String) -> Self {
        if message.contains("(-128)") || message.localizedCaseInsensitiveContains("user canceled") { return .authorizationCancelled }
        if message.contains("(-60005)") || message.localizedCaseInsensitiveContains("not authorized") { return .authorizationDenied }
        return .launchFailed
    }
}

@MainActor
protocol ClamshellSleepGuardControlling: AnyObject {
    var isRunning: Bool { get }
    var needsRecovery: Bool { get }
    func start() async throws
    func stop() async -> Bool
    func requestStop()
}
extension ClamshellSleepGuardControlling { var needsRecovery: Bool { false } }

struct ClamshellGuardProcess { var isRunning: () -> Bool; var errorText: () -> String }
struct ClamshellGuardBackend {
    var temporaryDirectory: URL
    var persistentRootURL: URL
    var securityPolicy: ClamshellGuardSecurityPolicy
    var appProcessID: Int32
    var userID: uid_t
    var pmsetExecutable: String
    var processIsAliveExecutable: String
    var sleepExecutable: String
    var bootSessionExecutable: String = "/usr/sbin/sysctl"
    var processStartExecutable: String = "/bin/ps"
    var launch: (ClamshellGuardCommand) async throws -> ClamshellGuardProcess
    var now: () -> TimeInterval
    var sleepHook: (TimeInterval) async -> Void
    static var live: Self {
        Self(temporaryDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
             persistentRootURL: ClamshellGuardCommand.productionRoot, securityPolicy: .production,
             appProcessID: ProcessInfo.processInfo.processIdentifier, userID: getuid(),
             pmsetExecutable: "/usr/bin/pmset", processIsAliveExecutable: "/bin/kill", sleepExecutable: "/bin/sleep",
             launch: KeepAwakeAuthorization.launch, now: { ProcessInfo.processInfo.systemUptime }, sleepHook: { seconds in
                 try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
             })
    }
}

@MainActor
final class ClamshellSleepGuard: ClamshellSleepGuardControlling {
    private struct Session { let command: ClamshellGuardCommand; let process: ClamshellGuardProcess }
    private let backend: ClamshellGuardBackend
    private let startupTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private var session: Session?
    private var recovery: ClamshellGuardProcess?
    init(backend: ClamshellGuardBackend = .live, startupTimeout: TimeInterval = 90, stopTimeout: TimeInterval = 8) {
        self.backend = backend; self.startupTimeout = startupTimeout; self.stopTimeout = stopTimeout
    }
    var isRunning: Bool {
        guard let current = session else { return false }
        return current.process.isRunning() && trustedMarker("ready", in: current.command.recordURL)
            && !exists(current.command.stopFileURL) && !trustedMarker("done", in: current.command.recordURL)
    }
    var needsRecovery: Bool { !recoveryNames().isEmpty }
    func inspectRecovery() { _ = recoveryNames() } // Inspection only, never authorizes.
    func start() async throws {
        try Task.checkCancellation()
        if isRunning { return }
        if needsRecovery { throw ClamshellSleepGuardError.cleanupRequired }
        if session != nil { guard await stop() else { throw ClamshellSleepGuardError.cleanupRequired } }
        guard backend.appProcessID > 1 else { throw ClamshellSleepGuardError.launchFailed }
        let directory = backend.temporaryDirectory.appendingPathComponent("LingChongDao-Clamshell-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw ClamshellSleepGuardError.launchFailed }
        let command = makeCommand(client: directory)
        let process: ClamshellGuardProcess
        do { process = try await backend.launch(command) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError { throw CancellationError() }
            throw (error as? ClamshellSleepGuardError) ?? .launchFailed
        }
        session = .init(command: command, process: process)
        let deadline = backend.now() + startupTimeout
        while true {
            if Task.isCancelled { requestStop(); throw CancellationError() }
            guard session?.command.directoryURL == directory else { throw CancellationError() }
            if trustedMarker("done", in: command.recordURL) { discardClient(); throw ClamshellSleepGuardError.stateVerificationFailed }
            if exists(command.stopFileURL) { throw CancellationError() }
            if isRunning { return }
            if !process.isRunning() {
                let error = ClamshellSleepGuardError.authorizationError(process.errorText())
                requestStop()
                if !exists(command.recordURL) {
                    discardClient(preservingCancellation: error != .authorizationCancelled && error != .authorizationDenied)
                }
                throw error
            }
            if backend.now() >= deadline { requestStop(); throw ClamshellSleepGuardError.startupTimedOut }
            await backend.sleepHook(0.1)
        }
    }
    func requestStop() { if let current = session { _ = Self.createStopMarker(current.command.stopFileURL) } }
    func stop() async -> Bool {
        requestStop()
        let stopDeadline = backend.now() + stopTimeout
        var recoveryDeadline: TimeInterval? = recovery == nil ? nil : backend.now() + startupTimeout
        while true {
            reconcileStoppedSession()
            let pendingClient = session != nil
            let names = recoveryNames()
            if !pendingClient && names.isEmpty { recovery = nil; return true }
            if recovery == nil, !names.isEmpty, session?.process.isRunning() != true {
                var command = makeCommand(client: backend.temporaryDirectory)
                command.recoveryNames = names
                do {
                    recovery = try await backend.launch(command)
                    recoveryDeadline = backend.now() + startupTimeout
                } catch { return false }
            }
            if let recovery, !recovery.isRunning() {
                self.recovery = nil
                reconcileStoppedSession()
                return recoveryNames().isEmpty && session == nil
            }
            // Credentials may take longer than the bounded power restoration.
            if Task.isCancelled || backend.now() >= (recoveryDeadline ?? stopDeadline) { return false }
            await backend.sleepHook(0.1)
        }
    }
    private func makeCommand(client: URL) -> ClamshellGuardCommand {
        ClamshellGuardCommand(appProcessID: backend.appProcessID, userID: backend.userID, token: UUID().uuidString,
            directoryURL: client, persistentRootURL: backend.persistentRootURL, securityPolicy: backend.securityPolicy,
            pmsetExecutable: backend.pmsetExecutable, processIsAliveExecutable: backend.processIsAliveExecutable, sleepExecutable: backend.sleepExecutable,
            bootSessionExecutable: backend.bootSessionExecutable, processStartExecutable: backend.processStartExecutable)
    }
    private func recoveryNames() -> [String] {
        guard trustedRoot(), let names = try? FileManager.default.contentsOfDirectory(atPath: backend.persistentRootURL.path) else { return [] }
        return names.filter { name in
            guard ClamshellGuardCommand.validSessionName(name, userID: backend.userID) else { return false }
            let record = backend.persistentRootURL.appendingPathComponent(name, isDirectory: true)
            guard trustedDirectory(record, exact755: true), !trustedMarker("done", in: record),
                  trustedMarker("changed-intent", in: record) else { return false }
            // All metadata precedes changed-intent, which precedes pmset. An
            // interrupted preparation cannot have changed global sleep state.
            if let current = session, current.command.recordURL == record, isRunning { return false }
            return true
        }.sorted()
    }
    private func trustedRoot() -> Bool {
        switch backend.securityPolicy {
        case .production:
            guard backend.persistentRootURL.path == ClamshellGuardCommand.productionRoot.path else { return false }
            for path in ["/private", "/private/var", "/private/var/db"] { if !trustedDirectory(URL(fileURLWithPath: path)) { return false } }
        case .fixture: break
        }
        return trustedDirectory(backend.persistentRootURL, exact755: true)
    }
    private func trustedDirectory(_ url: URL, exact755: Bool = false) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == backend.securityPolicy.owner, info.st_gid == backend.securityPolicy.group,
              (info.st_mode & 0o022) == 0 else { return false }
        return !exact755 || (info.st_mode & 0o777) == 0o755
    }
    private func trustedMarker(_ name: String, in record: URL) -> Bool {
        guard trustedRoot(), trustedDirectory(record, exact755: true) else { return false }
        var info = stat()
        return lstat(record.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == backend.securityPolicy.owner && info.st_gid == backend.securityPolicy.group
            && (info.st_mode & 0o022) == 0 && info.st_nlink == 1
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func reconcileStoppedSession() {
        guard let current = session else { return }
        if trustedMarker("done", in: current.command.recordURL) { discardClient() }
        else if !current.process.isRunning() {
            let record = current.command.recordURL
            let intent = record.appendingPathComponent("changed-intent")
            var intentInfo = stat()
            let hasAnyIntentEntry = lstat(intent.path, &intentInfo) == 0
            let trustedPreparation = trustedRoot() && trustedDirectory(record, exact755: true) && !hasAnyIntentEntry
            if !exists(record) || trustedPreparation {
                // A no-intent preparation cannot have changed power. Keep stop
                // because a dead launcher does not rule out a late broker request.
                discardClient(preservingCancellation: true)
            }
        }
    }
    private func discardClient(preservingCancellation: Bool = false) {
        guard let current = session else { return }
        if !preservingCancellation { try? FileManager.default.removeItem(at: current.command.directoryURL) }
        session = nil // Never delete root evidence from an unprivileged client.
    }
    nonisolated private static func createStopMarker(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd >= 0 { Darwin.close(fd); return true }
        if errno == EEXIST {
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
        }
        return false
    }
    deinit { if let session { _ = Self.createStopMarker(session.command.stopFileURL) } }
}
