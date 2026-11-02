import Darwin
import Foundation
import IslandCore

private struct Failure: Error { let message: String }

@main
struct DshNavigationVerification {
    static func main() async throws {
        try await exchange(.opened)
        print("PASS exact DSH correlation and split response frame")
        for mode in [Mode.wrongRequest, .wrongSession, .wrongVersion, .unknownStatus, .malformed, .oversize, .rejected, .timeout] {
            do {
                try await exchange(mode)
                throw Failure(message: "Accepted invalid DSH response: \(mode)")
            } catch is Failure { throw Failure(message: "Accepted invalid DSH response: \(mode)") }
            catch { print("PASS rejects DSH response \(mode)") }
        }
        let start = ContinuousClock.now
        let task = Task {
            try await DshNavigationClient(socketPath: "/private/tmp/dsh-missing-\(UUID().uuidString).sock")
                .open(sessionID: "cancel", timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { try await task.value; throw Failure(message: "Cancellation succeeded") }
        catch is CancellationError {}
        try require(start.duration(to: .now) < .seconds(1), "Cancellation waited for the full timeout")
        print("PASS cancellation stops a cold-start wait promptly")
        print("10 DSH socket transport checks passed. No source application was opened.")
    }

    enum Mode: CaseIterable {
        case opened, wrongRequest, wrongSession, wrongVersion, unknownStatus, malformed, oversize, rejected, timeout
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func exchange(_ mode: Mode) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/dsh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("n.sock").path
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try require(listener >= 0, "Cannot create fixture listener")
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8CString).map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try require(bound == 0 && Darwin.listen(listener, 1) == 0, "Cannot bind fixture listener")
        let server = Task.detached {
            let peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer) }
            var noSigPipe: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(peer, &bytes, bytes.count, 0)
            guard count > 0,
                  let request = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
                  request["version"] as? Int == 1, request["sessionId"] as? String == "session-A" else { return }
            if mode == .timeout { usleep(200_000); return }
            var reply: [String: Any] = ["version": mode == .wrongVersion ? 2 : 1,
                "requestId": mode == .wrongRequest ? "other" : request["requestId"]!,
                "sessionId": mode == .wrongSession ? "session-B" : "session-A",
                "status": mode == .unknownStatus ? "queued" : mode == .rejected ? "failed" : "opened"]
            if mode == .rejected { reply["reason"] = "missing session" }
            let data: Data
            if mode == .malformed { data = Data("not-json\n".utf8) }
            else if mode == .oversize { data = Data(repeating: 65, count: 16_385) }
            else { data = (try! JSONSerialization.data(withJSONObject: reply)) + Data([10]) }
            // Exercise framing across writes, not only a single recv packet.
            data.withUnsafeBytes { buffer in
                let half = buffer.count / 2
                _ = Darwin.send(peer, buffer.baseAddress!, half, 0)
                usleep(5_000)
                _ = Darwin.send(peer, buffer.baseAddress!.advanced(by: half), buffer.count - half, 0)
            }
        }
        do {
            try await DshNavigationClient(socketPath: path).open(sessionID: "session-A", requestID: "request-A", timeout: mode == .timeout ? 0.05 : 1)
            await server.value
        } catch {
            await server.value
            throw error
        }
    }
}
