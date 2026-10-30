import Foundation
import Darwin

public enum BridgePaths {
    public static var defaultSocketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LingChongDao/run/bridge.sock").path
    }
}
public enum BridgeLimits { public static let maximumFrameBytes = 1_048_576; public static let maximumApprovalWait: TimeInterval = 110 }
public enum SocketBridgeError: LocalizedError {
    case system(String, Int32), invalidPath, unsafePath(String), alreadyRunning, frameTooLarge, timeout, disconnected, invalidFrame, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .invalidPath: return "Unix socket path is empty or too long."
        case .unsafePath(let path): return "Refusing unsafe socket path: \(path)."
        case .alreadyRunning: return "灵宠岛本地桥接已在运行。"
        case .frameTooLarge: return "Bridge frame exceeds 1 MiB."
        case .timeout: return "Bridge response timed out; return to normal approval."
        case .disconnected: return "Bridge disconnected; return to normal approval."
        case .invalidFrame: return "Bridge frame is invalid."
        case .unsupportedVersion: return "Unsupported bridge version."
        }
    }
}

/// Stateful newline framing accepts split writes and enforces the limit before allocation can grow indefinitely.
public struct NewlineFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public var bufferedByteCount: Int { buffer.count }
    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if byte == 10 { guard !buffer.isEmpty else { throw SocketBridgeError.invalidFrame }; frames.append(buffer); buffer.removeAll(keepingCapacity: true) }
            else { guard buffer.count < BridgeLimits.maximumFrameBytes else { throw SocketBridgeError.frameTooLarge }; buffer.append(byte) }
        }
        return frames
    }
}

private enum SocketIO {
    static func create() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketBridgeError.system("socket", errno) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard !path.isEmpty, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketBridgeError.invalidPath }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return address
    }
    static func connect(path: String, deadline: Date) throws -> Int32 {
        let fd = try create()
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw SocketBridgeError.system("connect", errno) }
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                var code: Int32 = 0; var size = socklen_t(MemoryLayout.size(ofValue: code))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else { throw SocketBridgeError.system("connect", code == 0 ? errno : code) }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketBridgeError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 200).rounded(.up)))
            if result < 0 { if errno == EINTR { continue }; throw SocketBridgeError.system("poll", errno) }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw SocketBridgeError.disconnected }
        }
    }
    static func readFrame(_ fd: Int32, deadline: Date) throws -> Data {
        var decoder = NewlineFrameDecoder(); var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count == 0 { throw SocketBridgeError.disconnected }
            if count < 0 { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }; throw SocketBridgeError.system("recv", errno) }
            let frames = try decoder.append(Data(bytes.prefix(count)))
            if let frame = frames.first { guard frames.count == 1, decoder.bufferedByteCount == 0 else { throw SocketBridgeError.invalidFrame }; return frame }
        }
    }
    static func writeFrame(_ data: Data, fd: Int32, deadline: Date) throws {
        guard data.count <= BridgeLimits.maximumFrameBytes else { throw SocketBridgeError.frameTooLarge }
        var framed = data; framed.append(10); var offset = 0
        try framed.withUnsafeBytes { buffer in
            while offset < buffer.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }; throw SocketBridgeError.system("send", errno) }
                guard count > 0 else { throw SocketBridgeError.disconnected }; offset += count
            }
        }
    }
    static func peerClosed(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }
}

public final class IslandSocketClient: @unchecked Sendable {
    public let socketPath: String
    public init(socketPath: String = BridgePaths.defaultSocketPath) { self.socketPath = socketPath }
    /// Blocking. Invoke on a background queue or a CLI process, never the main UI thread.
    public func send(_ envelope: BridgeEnvelope, timeout: TimeInterval = 2) throws -> BridgeReply {
        guard timeout.isFinite, timeout > 0 else { throw SocketBridgeError.timeout }
        let deadline = Date().addingTimeInterval(min(timeout, BridgeLimits.maximumApprovalWait + 2))
        let fd = try SocketIO.connect(path: socketPath, deadline: deadline); defer { Darwin.close(fd) }
        try SocketIO.writeFrame(JSONEncoder().encode(envelope), fd: fd, deadline: deadline)
        let response = try JSONDecoder().decode(BridgeReply.self, from: SocketIO.readFrame(fd, deadline: deadline))
        guard response.requestID == envelope.requestID else { throw SocketBridgeError.invalidFrame }
        return response
    }
}

private final class SocketConnection: @unchecked Sendable {
    let id = UUID(); let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var envelope: BridgeEnvelope?
    private var task: Task<Void, Never>?
    let onClosed: @Sendable (BridgeEnvelope, String) -> Void
    let onFinish: @Sendable (UUID) -> Void
    init(fd: Int32, onClosed: @escaping @Sendable (BridgeEnvelope, String) -> Void, onFinish: @escaping @Sendable (UUID) -> Void) { self.fd = fd; self.onClosed = onClosed; self.onFinish = onFinish }
    func assign(_ envelope: BridgeEnvelope) { lock.lock(); self.envelope = envelope; lock.unlock() }
    func assign(task: Task<Void, Never>) { lock.lock(); if finished { task.cancel() } else { self.task = task }; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish(_ reply: BridgeReply, reason: String? = nil, write: Bool = true) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; let request = envelope; let runningTask = task; task = nil; lock.unlock()
        if let reason, let request { onClosed(request, reason); runningTask?.cancel() }
        if write { var correlated = reply; correlated.requestID = request?.requestID; if let data = try? JSONEncoder().encode(correlated) { try? SocketIO.writeFrame(data, fd: fd, deadline: Date().addingTimeInterval(1)) } }
        _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); onFinish(id)
    }
}

public final class IslandSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var generation = UUID()
    private var socketInode: UInt64?
    private var connections: [UUID: SocketConnection] = [:]
    public init(socketPath: String = BridgePaths.defaultSocketPath) { self.socketPath = socketPath }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener >= 0 }
    public func start(handler: @escaping @Sendable (BridgeEnvelope) async -> BridgeReply, onConnectionClosed: @escaping @Sendable (BridgeEnvelope, String) -> Void = { _, _ in }) throws {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { throw SocketBridgeError.alreadyRunning }
        try prepareDirectory()
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else { throw SocketBridgeError.unsafePath(socketPath) }
            do { let fd = try SocketIO.connect(path: socketPath, deadline: Date().addingTimeInterval(0.25)); Darwin.close(fd); throw SocketBridgeError.alreadyRunning }
            catch SocketBridgeError.system(_, let code) where code == ECONNREFUSED || code == ENOENT { guard unlink(socketPath) == 0 || errno == ENOENT else { throw SocketBridgeError.system("unlink stale socket", errno) } }
        }
        let fd = try SocketIO.create()
        do {
            var address = try SocketIO.address(socketPath)
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw SocketBridgeError.system("bind", errno) }
            guard chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 32) == 0 else { throw SocketBridgeError.system("listen", errno) }
            var info = stat(); guard lstat(socketPath, &info) == 0 else { throw SocketBridgeError.system("lstat", errno) }
            socketInode = UInt64(info.st_ino); listener = fd; generation = UUID(); let currentGeneration = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd: fd, generation: currentGeneration, handler: handler, onClosed: onConnectionClosed) }
        } catch { Darwin.close(fd); throw error }
    }
    private func prepareDirectory() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat(); guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw SocketBridgeError.unsafePath(directory) }
        guard chmod(directory, 0o700) == 0 else { throw SocketBridgeError.system("chmod directory", errno) }
    }
    private func acceptLoop(fd: Int32, generation: UUID, handler: @escaping @Sendable (BridgeEnvelope) async -> BridgeReply, onClosed: @escaping @Sendable (BridgeEnvelope, String) -> Void) {
        while isCurrentListener(fd, generation: generation) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 200) > 0 else { continue }
            let peer = Darwin.accept(fd, nil, nil)
            if peer < 0 { if errno == EAGAIN || errno == EINTR { continue }; break }
            var noSigPipe: Int32 = 1; _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK); _ = fcntl(peer, F_SETFD, FD_CLOEXEC)
            let connection = SocketConnection(fd: peer, onClosed: onClosed) { [weak self] id in self?.removeConnection(id) }
            lock.lock(); let canAccept = listener == fd && self.generation == generation && connections.count < 128; if canAccept { connections[connection.id] = connection }; lock.unlock()
            guard canAccept else { connection.finish(.fallback("Bridge busy or stopping."), write: false); continue }
            DispatchQueue.global(qos: .utility).async { self.serve(connection, handler: handler) }
        }
    }
    private func isCurrentListener(_ fd: Int32, generation: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return listener == fd && self.generation == generation }
    private func removeConnection(_ id: UUID) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
    private func serve(_ connection: SocketConnection, handler: @escaping @Sendable (BridgeEnvelope) async -> BridgeReply) {
        do {
            let frame = try SocketIO.readFrame(connection.fd, deadline: Date().addingTimeInterval(2))
            let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: frame)
            connection.assign(envelope)
            guard envelope.version == 1 else { connection.finish(.fallback("Unsupported bridge version.")); return }
            if envelope.operation == .ping { connection.finish(BridgeReply(disposition: .status, message: "灵宠岛 bridge v1 ready")); return }
            let now = Date(); let defaultWait: TimeInterval = envelope.operation == .status ? 2 : 3
            let deadline = min(envelope.deadline ?? now.addingTimeInterval(defaultWait), now.addingTimeInterval(BridgeLimits.maximumApprovalWait))
            guard deadline > now else { connection.finish(.fallback("Request already expired."), reason: "timeout"); return }
            let task = Task {
                let reply = await handler(envelope)
                guard !Task.isCancelled else { return }
                connection.finish(reply)
            }
            connection.assign(task: task)
            // Runs on the worker queue while the asynchronous UI handler is suspended.
            while !connection.isFinished {
                if Date() >= deadline { connection.finish(.fallback("Approval timed out; use the original tool."), reason: "timeout"); break }
                if SocketIO.peerClosed(connection.fd) { connection.finish(.fallback("Client disconnected."), reason: "disconnected", write: false); break }
                usleep(50_000)
            }
        } catch { connection.finish(.fallback(error.localizedDescription), reason: "transport", write: false) }
    }
    public func stop() {
        lock.lock(); let fd = listener; listener = -1; generation = UUID(); let active = Array(connections.values); connections.removeAll(); let inode = socketInode; socketInode = nil; lock.unlock()
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        active.forEach { $0.finish(.fallback("Bridge stopped."), reason: "stopped") }
        if let inode { var info = stat(); if lstat(socketPath, &info) == 0, UInt64(info.st_ino) == inode, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK { _ = unlink(socketPath) } }
    }
    deinit { stop() }
}
