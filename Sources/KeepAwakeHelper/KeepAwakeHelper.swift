import Darwin
import Foundation

/// A one-app authorization session. It only receives requests on the connected
/// socket authenticated at startup and exits when that connection closes.
struct KeepAwakeHelper {
    let uid: uid_t
    let pid: pid_t
    let directory: URL

    init?(arguments: [String]) {
        guard arguments.count == 4, arguments[0] == "broker",
              let uid = uid_t(arguments[1]), uid != 0, String(uid) == arguments[1],
              let pid = pid_t(arguments[2]), pid > 1, String(pid) == arguments[2],
              Self.ownsProcess(pid, uid: uid),
              let directory = Self.privateDirectory(arguments[3], prefix: "LingChongDao-Broker-", uid: uid) else { return nil }
        self.uid = uid
        self.pid = pid
        self.directory = directory
    }

    static func main() {
        guard getuid() == 0, geteuid() == 0,
              let broker = Self(arguments: Array(CommandLine.arguments.dropFirst())) else { exit(EX_USAGE) }
        guard let fd = broker.connect() else { exit(EX_NOPERM) }
        defer { Darwin.close(fd) }
        broker.serve(fd, launch: Self.launch)
    }

    func connect() -> Int32? {
        let bytes = Array(directory.appendingPathComponent("control").path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            return nil
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard connected == 0, getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID == pid else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    func command(token: String, stopDirectory: String) -> ClamshellGuardCommand? {
        guard let id = UUID(uuidString: token), id.uuidString == token,
              let directory = Self.privateDirectory(stopDirectory, prefix: "LingChongDao-Clamshell-", uid: uid)
        else { return nil }
        return ClamshellGuardCommand(appProcessID: pid, userID: uid, token: token, directoryURL: directory)
    }

    func serve(_ fd: Int32, launch: (ClamshellGuardCommand) throws -> Process) {
        var active: (token: String, process: Process)?
        var queued: (command: ClamshellGuardCommand, deadline: TimeInterval)?
        var line: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        defer {
            if let child = active?.process, child.isRunning {
                // The watcher's TERM trap restores the previous sleep state.
                child.terminate()
                child.waitUntilExit()
            }
        }
        func reply(_ status: String, _ token: String) -> Bool {
            let bytes = Array("\(status) \(token)\n".utf8)
            return bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) == $0.count }
        }
        func start(_ command: ClamshellGuardCommand) -> Bool {
            do {
                active = (command.token, try launch(command))
                return reply("started", command.token)
            } catch {
                return reply("ended", command.token)
            }
        }
        while Self.ownsProcess(pid, uid: uid) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, active == nil ? 1000 : 100)
            if result < 0 { if errno == EINTR { continue }; return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
            if let child = active, !child.process.isRunning {
                active = nil
                guard reply("ended", child.token) else { return }
            }
            if let next = queued {
                if active == nil {
                    queued = nil
                    guard start(next.command) else { return }
                } else if ProcessInfo.processInfo.systemUptime >= next.deadline {
                    queued = nil
                    guard reply("ended", next.command.token) else { return }
                }
            }
            guard result > 0 else { continue }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return }
            for byte in buffer.prefix(count) {
                if byte != 10 {
                    guard byte >= 32, byte <= 126, line.count < 256 else { return }
                    line.append(byte)
                    continue
                }
                let parts = String(decoding: line, as: UTF8.self).components(separatedBy: " ")
                line.removeAll(keepingCapacity: true)
                guard parts.count == 3, parts[0] == "start",
                      let id = UUID(uuidString: parts[1]), id.uuidString == parts[1] else { return }
                let token = parts[1]
                guard let next = command(token: token, stopDirectory: parts[2]) else {
                    guard reply("ended", token) else { return }
                    continue
                }
                if active == nil {
                    guard start(next) else { return }
                } else if queued == nil {
                    // Restoration is observable before the previous watcher
                    // finishes its brief cleanup grace period.
                    queued = (next, ProcessInfo.processInfo.systemUptime + 3)
                } else if !reply("ended", token) {
                    return
                }
            }
        }
    }

    private static func launch(_ command: ClamshellGuardCommand) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.watcherCommand]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func privateDirectory(_ path: String, prefix: String, uid: uid_t) -> URL? {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
              name == prefix + uuid.uuidString, path == root.appendingPathComponent(name).path else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700, info.st_uid == uid else { return nil }
        return url
    }

    private static func ownsProcess(_ pid: Int32, uid: uid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size &&
            info.pbi_pid == UInt32(pid) && info.pbi_ruid == uid && info.pbi_uid == uid
    }
}
