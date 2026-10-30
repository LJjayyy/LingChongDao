import Foundation
import Darwin
import IslandCore

func diagnostic(_ message: String) { FileHandle.standardError.write(Data("lingchongdao-hook: \(message)\n".utf8)) }
func emit(_ value: JSONValue) { let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
func limitedRead(_ handle: FileHandle) throws -> Data {
    var data = Data()
    while true { let chunk = handle.readData(ofLength: 8192); if chunk.isEmpty { break }; guard data.count + chunk.count <= BridgeLimits.maximumFrameBytes else { throw SocketBridgeError.frameTooLarge }; data.append(chunk) }
    return data
}

struct Arguments {
    var provider: ProviderID = .generic
    var socketPath = BridgePaths.defaultSocketPath
    var timeout: TimeInterval = 45
    var operation: BridgeOperation = .event
    var fixture: String?
    var help = false
    var diagnoseOrigin = false
    init(_ args: [String]) throws {
        var index = 0
        while index < args.count {
            let argument = args[index]
            func next() throws -> String { guard index + 1 < args.count else { throw CLIError.argument("Missing value for \(argument)") }; index += 1; return args[index] }
            switch argument {
            case "--provider": let value = try next(); guard let parsed = ProviderID(rawValue: value) else { throw CLIError.argument("Unknown provider \(value)") }; provider = parsed
            case "--socket": socketPath = try next()
            case "--timeout": let value = try next(); guard let parsed = Double(value), parsed.isFinite, parsed > 0, parsed <= BridgeLimits.maximumApprovalWait else { throw CLIError.argument("Timeout must be 0 < seconds <= 110") }; timeout = parsed
            case "--ping": operation = .ping
            case "--status": operation = .status
            case "--send-fixture": fixture = try next()
            case "--diagnose-origin": diagnoseOrigin = true
            case "--help", "-h": help = true
            default: throw CLIError.argument("Unknown argument \(argument)")
            }
            index += 1
        }
    }
}
enum CLIError: LocalizedError { case argument(String); var errorDescription: String? { switch self { case .argument(let text): return text } } }

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    if arguments.help {
        FileHandle.standardOutput.write(Data("lingchongdao-hook --provider qoder|codex|claude|zcode|dsh|codebuddy|workbuddy|generic [--socket PATH] [--timeout SECONDS]\nReads hook JSON from stdin. --ping / --status / --send-fixture FILE are diagnostics.\n--diagnose-origin reports verified origin without stdin or a bridge connection.\n".utf8)); exit(0)
    }
    if arguments.diagnoseOrigin {
        let origin = SourceApplicationDetector.detect(provider: arguments.provider)
        emit(.object(["origin": origin.map { .string($0.rawValue) } ?? .null,
                      "bundleIdentifier": origin?.bundleIdentifier.map { .string($0) } ?? .null]))
        exit(0)
    }
    let client = IslandSocketClient(socketPath: arguments.socketPath)
    if arguments.operation != .event {
        let reply = try client.send(BridgeEnvelope(provider: arguments.provider, operation: arguments.operation), timeout: 2)
        emit(.object(["ok": .bool(reply.disposition == .status || reply.disposition == .acknowledged), "message": .string(reply.message ?? reply.disposition.rawValue)])); exit(0)
    }
    let input: Data
    if let file = arguments.fixture {
        guard let handle = FileHandle(forReadingAtPath: file) else { throw CLIError.argument("Cannot open fixture") }; defer { try? handle.close() }; input = try limitedRead(handle)
    } else { input = try limitedRead(FileHandle.standardInput) }
    var raw = try JSONDecoder().decode(JSONValue.self, from: input)
    let transportID = UUID().uuidString
    if arguments.provider == .claude {
        raw = ClaudePermissionBridge.correlatedInput(raw, transportID: transportID)
    } else if arguments.provider == .codex {
        raw = CodexPermissionBridge.correlatedInput(raw, transportID: transportID)
    } else if arguments.provider == .qoder {
        raw = QoderPermissionBridge.correlatedInput(raw, transportID: transportID)
    }
    let normalizedInput = try JSONEncoder().encode(raw)
    // Fixtures use their explicit provider only; running the CLI from a host app
    // must not pretend a synthetic event came from that application's real session.
    let origin = arguments.fixture == nil ? SourceApplicationDetector.detect(provider: arguments.provider) : nil
    var event = try HookNormalizer.normalize(rawJSON: normalizedInput, provider: arguments.provider, sourceApplication: origin)
    let interactive = [ProviderID.codex, .zcode, .claude].contains(arguments.provider) && event.kind == .approvalRequested && (event.approval?.canApprove == true || event.approval?.canDeny == true)
    let wait = interactive ? arguments.timeout : min(arguments.timeout, 2)
    let deadline = min(event.approval?.expiresAt ?? .distantFuture, Date().addingTimeInterval(wait))
    if interactive { event.approval?.expiresAt = deadline }
    let envelope = BridgeEnvelope(provider: arguments.provider, raw: raw, requestID: transportID, deadline: deadline, sourceApplication: origin)
    let reply = try client.send(envelope, timeout: wait + 1)
    if reply.disposition == .fallback { diagnostic(reply.message ?? "Returned to normal source approval.") }
    emit(HookOutput.response(for: reply, event: event))
} catch {
    diagnostic(error.localizedDescription)
    // A broken bridge must never turn into allow or deny. Empty success returns normal source handling.
    emit(.object([:]))
}
