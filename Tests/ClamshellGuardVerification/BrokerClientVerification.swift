import Darwin
import Foundation

private struct BrokerClientFailure: Error {
    let message: String
}

func verifyKeepAwakeBrokerClient() async throws {
    func expect(_ result: Bool, _ message: String) throws {
        if !result { throw BrokerClientFailure(message: message) }
    }

    var fds = [Int32](repeating: -1, count: 2)
    try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "broker fixture socket pair")
    let client = fds[0], server = fds[1]
    defer { Darwin.close(server) }
    try expect(fcntl(client, F_SETFL, O_NONBLOCK) == 0, "nonblocking transport")
    let connection = KeepAwakeBrokerConnection(peer: client, launcher: .init(isRunning: { true }, errorText: { "" }))
    let directory = URL(fileURLWithPath: "/private/tmp/LingChongDao-Clamshell-" + UUID().uuidString)
    let command = ClamshellGuardCommand(appProcessID: getpid(), userID: getuid(), token: UUID().uuidString, directoryURL: directory)
    let next = ClamshellGuardCommand(appProcessID: getpid(), userID: getuid(), token: UUID().uuidString, directoryURL: directory)

    func readCommand(_ command: ClamshellGuardCommand) throws {
        var bytes = [UInt8](repeating: 0, count: 512)
        let n = recv(server, &bytes, bytes.count, MSG_DONTWAIT)
        try expect(n > 0, "broker received the request")
        try expect(String(decoding: bytes.prefix(n), as: UTF8.self) == "start \(command.token) \(directory.path)\n", "broker request contains only the session token and stop directory")
    }
    func reply(_ text: String) throws {
        let data = Array(text.utf8)
        try expect(data.withUnsafeBytes { send(server, $0.baseAddress, $0.count, 0) } == data.count, "fixture wrote broker reply")
    }

    let first = try connection.start(command)
    try readCommand(command)
    try reply("star")
    try expect(first.isRunning(), "partial status line leaves the watcher alive")
    try reply("ted \(command.token)\n")
    let second = try connection.start(next)
    try readCommand(next)
    try reply("ended \(command.token)\nstarted \(next.token)\n")
    try expect(!first.isRunning() && second.isRunning(), "old watcher exit does not stop the next session")
    try expect(shutdown(server, SHUT_RDWR) == 0, "simulate broker exit")
    try expect(!second.isRunning() && !connection.isConnected, "unexpected broker exit ends the session")

    let cancelled = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await KeepAwakeSessionBroker.shared.start(command, installation: .init(source: directory, digest: "fixture"))
    }
    do {
        _ = try await cancelled.value
        throw BrokerClientFailure(message: "cancelled start attempted to connect")
    } catch is CancellationError { }
}
