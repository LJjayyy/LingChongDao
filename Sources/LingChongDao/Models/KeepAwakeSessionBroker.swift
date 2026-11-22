import Darwin
import Foundation

/// The listener exists only during the initial administrator grant. Subsequent
/// requests use the already authenticated connection to this app instance.
@MainActor
final class KeepAwakeSessionBroker {
    static let shared = KeepAwakeSessionBroker()
    private var connection: KeepAwakeBrokerConnection?
    private var connecting = false

    var isConnected: Bool { connection?.isConnected == true }

    func start(_ command: ClamshellGuardCommand, installation: KeepAwakeHelperInstallation) async throws -> ClamshellGuardProcess {
        try Task.checkCancellation()
        if !isConnected {
            guard !connecting else { throw ClamshellSleepGuardError.launchFailed }
            connecting = true
            defer { connecting = false }
            connection = try await connect(installation: installation)
        }
        try Task.checkCancellation()
        guard let connection else { throw ClamshellSleepGuardError.launchFailed }
        // Return the handle before the next suspension so shutdown can signal
        // this exact watcher even if cancellation races with sending the start.
        return try connection.start(command)
    }

    private func connect(installation: KeepAwakeHelperInstallation) async throws -> KeepAwakeBrokerConnection {
        let directory = URL(fileURLWithPath: "/private/tmp/LingChongDao-Broker-\(UUID().uuidString)", isDirectory: true)
        let path = directory.appendingPathComponent("control").path
        guard mkdir(directory.path, 0o700) == 0 else { throw ClamshellSleepGuardError.launchFailed }
        defer { _ = unlink(path); _ = rmdir(directory.path) }

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ClamshellSleepGuardError.launchFailed }
        defer { Darwin.close(listener) }
        try Self.configure(listener)
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ClamshellSleepGuardError.launchFailed }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw ClamshellSleepGuardError.launchFailed }

        let shell = installation.brokerCommand(directory: directory, appPID: getpid(), uid: getuid())
        let script = KeepAwakeAuthorization.administratorScript(shell, prompt: "灵宠岛要为本次运行开启合盖防休眠。之后可以使用触控 ID 或密码验证。")
        let launcher = try KeepAwakeAuthorization.run("/usr/bin/osascript", ["-e", script])
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let peer = accept(listener, nil, nil)
            if peer >= 0 {
                do {
                    var uid: uid_t = .max, gid: gid_t = .max
                    guard getpeereid(peer, &uid, &gid) == 0, uid == 0 else {
                        throw ClamshellSleepGuardError.authorizationDenied
                    }
                    try Self.configure(peer)
                    return KeepAwakeBrokerConnection(peer: peer, launcher: launcher)
                } catch {
                    Darwin.close(peer)
                    throw error
                }
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw ClamshellSleepGuardError.launchFailed }
            guard launcher.isRunning() else { throw ClamshellSleepGuardError.authorizationError(launcher.errorText()) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ClamshellSleepGuardError.startupTimedOut
    }

    private static func configure(_ fd: Int32) throws {
        var on: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ClamshellSleepGuardError.launchFailed
        }
    }
}

/// Process handles can be polled independently, including while the previous
/// watcher finishes restoring power. Each handle follows its own session token.
final class KeepAwakeBrokerConnection {
    private let lock = NSLock()
    private var peer: Int32
    private let launcher: ClamshellGuardProcess
    private var line: [UInt8] = []
    private var live = Set<String>()

    init(peer: Int32, launcher: ClamshellGuardProcess) {
        self.peer = peer
        self.launcher = launcher
    }

    deinit { if peer >= 0 { Darwin.close(peer) } }

    var isConnected: Bool {
        lock.withLock {
            readStatus()
            return peer >= 0
        }
    }

    func start(_ command: ClamshellGuardCommand) throws -> ClamshellGuardProcess {
        let token = command.token
        try lock.withLock {
            readStatus()
            guard peer >= 0, !live.contains(token) else { throw ClamshellSleepGuardError.launchFailed }
            let bytes = Array("start \(token) \(command.directoryURL.path)\n".utf8)
            guard bytes.withUnsafeBytes({ Darwin.send(peer, $0.baseAddress, $0.count, 0) }) == bytes.count else {
                disconnect()
                throw ClamshellSleepGuardError.launchFailed
            }
            live.insert(token)
        }
        return ClamshellGuardProcess(isRunning: { [self] in
            lock.withLock {
                readStatus()
                return live.contains(token)
            }
        }, errorText: { "合盖防休眠辅助程序已停止。" })
    }

    /// Called only under lock. Limit work and line length on every poll.
    private func readStatus() {
        guard peer >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 512)
        for _ in 0..<8 {
            let count = Darwin.recv(peer, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { disconnect(); return }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    let fields = String(decoding: line, as: UTF8.self).split(separator: " ")
                    guard fields.count == 2, live.contains(String(fields[1])) else { disconnect(); return }
                    switch fields[0] {
                    case "started": break
                    case "ended": live.remove(String(fields[1]))
                    default: disconnect(); return
                    }
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard byte >= 32, byte <= 126, line.count < 64 else { disconnect(); return }
                    line.append(byte)
                }
            }
        }
    }

    private func disconnect() {
        if peer >= 0 { Darwin.close(peer); peer = -1 }
        live.removeAll()
    }
}
