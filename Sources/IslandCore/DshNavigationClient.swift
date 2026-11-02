import Darwin
import Foundation

/// A request is acknowledged only after the DSH client selected and loaded the
/// requested conversation. Merely activating the application is not success.
public struct DshNavigationClient: Sendable {
    public static var defaultSocketPath: String {
        URL(fileURLWithPath: BridgePaths.defaultSocketPath).deletingLastPathComponent()
            .appendingPathComponent("dsh-navigation.sock").path
    }

    public let socketPath: String
    public init(socketPath: String = Self.defaultSocketPath) { self.socketPath = socketPath }

    public func open(sessionID: String, requestID: String = UUID().uuidString,
                     timeout: TimeInterval = 5) async throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 4096,
              !requestID.isEmpty, requestID.utf8.count <= 128,
              timeout.isFinite, timeout > 0 else { throw SocketBridgeError.invalidFrame }
        let path = socketPath
        let worker = Task.detached(priority: .userInitiated) {
            try Self.exchange(path: path, sessionID: sessionID, requestID: requestID, timeout: min(timeout, 10))
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private struct Request: Encodable {
        let version = 1
        let requestId: String
        let sessionId: String
    }
    private struct Reply: Decodable {
        let version: Int
        let requestId: String
        let sessionId: String
        let status: String
        let reason: String?
    }

    public struct Rejected: LocalizedError, Sendable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    private static func exchange(path: String, sessionID: String, requestID: String, timeout: TimeInterval) throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        let fd = try connect(path: path, deadline: deadline)
        defer { Darwin.close(fd) }
        var request = try JSONEncoder().encode(Request(requestId: requestID, sessionId: sessionID))
        request.append(10)
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                guard count > 0 else { throw SocketBridgeError.disconnected }
                offset += count
            }
        }
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard count > 0 else { throw SocketBridgeError.disconnected }
            response.append(contentsOf: bytes.prefix(count))
            guard response.count <= 16_384 else { throw SocketBridgeError.frameTooLarge }
            if let newline = response.firstIndex(of: 10) {
                guard newline == response.index(before: response.endIndex) else { throw SocketBridgeError.invalidFrame }
                let reply = try JSONDecoder().decode(Reply.self, from: response.prefix(upTo: newline))
                guard reply.version == 1, reply.requestId == requestID, reply.sessionId == sessionID else {
                    throw SocketBridgeError.invalidFrame
                }
                try Task.checkCancellation()
                guard reply.status == "opened" else {
                    guard reply.status == "failed" else { throw SocketBridgeError.invalidFrame }
                    throw Rejected(reason: String((reply.reason ?? "DSH 未能打开目标会话").prefix(300)))
                }
                return
            }
        }
    }

    private static func connect(path: String, deadline: ContinuousClock.Instant) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard !path.isEmpty, bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketBridgeError.invalidPath }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SocketBridgeError.timeout }
            var info = stat()
            let exists = lstat(path, &info) == 0
            if exists {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw SocketBridgeError.unsafePath(path) }
            } else if errno != ENOENT { throw SocketBridgeError.system("lstat", errno) }
            if exists {
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw SocketBridgeError.system("socket", errno) }
                var noSigPipe: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                do {
                    let result = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                    }
                    if result != 0 {
                        let code = errno
                        guard code == EINPROGRESS || code == EAGAIN else { throw SocketBridgeError.system("connect", code) }
                        try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                        var error: Int32 = 0
                        var size = socklen_t(MemoryLayout.size(ofValue: error))
                        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                            throw SocketBridgeError.system("connect", error == 0 ? errno : error)
                        }
                    }
                    var uid: uid_t = 0; var gid: gid_t = 0
                    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw SocketBridgeError.unsafePath(path) }
                    return fd
                } catch {
                    Darwin.close(fd)
                    if case SocketBridgeError.system(_, let code) = error, code == ENOENT || code == ECONNREFUSED {
                        // A cold Desktop launch has not mounted the plugin yet.
                    } else { throw error }
                }
            }
            // No request has been sent yet, so retrying cannot replay navigation.
            usleep(50_000)
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SocketBridgeError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, 50)
            if result < 0 {
                if errno == EINTR { continue }
                throw SocketBridgeError.system("poll", errno)
            }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw SocketBridgeError.disconnected }
        }
    }
}
