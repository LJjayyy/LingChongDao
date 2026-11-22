import Darwin
import Foundation
import LocalAuthentication

/// Selects a privileged launcher. Authentication itself happens in macOS.
enum KeepAwakeAuthorization {
    static func launch(_ command: ClamshellGuardCommand) async throws -> ClamshellGuardProcess {
        let context = LAContext()
        guard command.recoveryNames == nil, isCurrentUserAdministrator(),
              let installation = KeepAwakeHelperInstallation.bundled() else {
            return try launchWithPassword(command)
        }

        let broker = await KeepAwakeSessionBroker.shared
        if await broker.isConnected {
            // Let macOS present fingerprint and password in a single prompt.
            context.localizedFallbackTitle = "使用密码"
            do {
                let approved = try await withTaskCancellationHandler {
                    try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                     localizedReason: "开启保持唤醒（含合盖）")
                } onCancel: {
                    context.invalidate()
                }
                guard approved else { throw ClamshellSleepGuardError.authorizationDenied }
            } catch let error as LAError {
                try Task.checkCancellation()
                switch error.code {
                case .userCancel, .appCancel, .systemCancel:
                    throw ClamshellSleepGuardError.authorizationCancelled
                case .userFallback:
                    return try launchWithPassword(command)
                default:
                    throw ClamshellSleepGuardError.authorizationDenied
                }
            }
        } else if !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
                    || context.biometryType != .touchID {
            return try launchWithPassword(command)
        }
        // The first session authorization comes from the administrator dialog.
        try Task.checkCancellation()
        return try await broker.start(command, installation: installation)
    }

    static func launchWithPassword(_ command: ClamshellGuardCommand) throws -> ClamshellGuardProcess {
        try run("/usr/bin/osascript", ["-e", command.appleScript])
    }

    private static func isCurrentUserAdministrator() -> Bool {
        guard let adminGroup = getgrnam("admin")?.pointee.gr_gid else { return false }
        let count = getgroups(0, nil)
        guard count > 0 else { return false }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let actualCount = getgroups(count, &groups)
        return actualCount > 0 && groups.prefix(Int(actualCount)).contains(adminGroup)
    }

    static func administratorScript(_ shell: String, prompt: String) -> String {
        func literal(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return "with timeout of 2147483647 seconds\n do shell script \"\(literal(shell))\" with administrator privileges with prompt \"\(literal(prompt))\"\nend timeout"
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> ClamshellGuardProcess {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        try process.run()
        return ClamshellGuardProcess(isRunning: { process.isRunning }, errorText: {
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while data.count < 16_384 {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, 16_384 - data.count))
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            _ = pipe
            return String(decoding: data, as: UTF8.self)
        })
    }
}
