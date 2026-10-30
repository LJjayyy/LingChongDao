import Darwin
import Foundation
import IslandCore

enum ProviderDetector {
    static func detect(provider: ProviderID, environment: ConnectionEnvironment) async -> ProviderDetection {
        let names: [String]
        let expectedBundles: Set<String>?
        switch provider {
        case .qoder: names = ["Qoder CN.app", "Qoder CN IDE.app"]; expectedBundles = nil
        case .codex: names = ["Codex.app", "ChatGPT.app"]; expectedBundles = nil
        case .claude: names = ["Claude.app"]; expectedBundles = ["com.anthropic.claudefordesktop"]
        case .zcode: names = ["ZCode.app"]; expectedBundles = ["dev.zcode.app"]
        case .dsh: names = ["DeepSeek Harness.app"]; expectedBundles = ["com.deepseek.dsh"]
        case .codebuddy: names = ["CodeBuddy CN.app"]; expectedBundles = ["com.tencent.codebuddycn"]
        case .workbuddy: names = ["WorkBuddy.app"]; expectedBundles = ["com.tencent.workbuddy.mac"]
        case .generic: names = []; expectedBundles = []
        }
        let app = names.lazy.flatMap { name in environment.applicationDirectories.map { $0.appendingPathComponent(name, isDirectory: true) } }.first { app in
            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
            guard let expectedBundles else { return true }
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundle = plist["CFBundleIdentifier"] as? String else { return false }
            return expectedBundles.contains(bundle)
        }
        var appVersion: String?
        if let app, let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            appVersion = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
        }
        let cliNames = provider == .qoder ? ["qodercli", "qoder"] : provider == .codex ? ["codex"] : provider == .claude ? ["claude"] : provider == .zcode ? ["zcode"] : provider == .dsh ? ["dsh"] : []
        var candidates = environment.executableSearchDirectories.flatMap { directory in cliNames.map { directory.appendingPathComponent($0) } }
        if provider == .codex, let app {
            candidates = [app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"), app.appendingPathComponent("Contents/Resources/codex")] + candidates
        }
        if provider == .claude { candidates += ClaudePluginBridge.desktopCLIs(environment) }
        let cli = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        var result = ProviderDetection(appURL: app, appVersion: appVersion, cliURL: cli, cliVersion: nil, cliMessage: nil, configurationURL: environment.configurationURL(for: provider))
        if let cli, environment.detectCLIVersions {
            let version = await versionOutput(executable: cli)
            result.cliVersion = version.version
            result.cliMessage = version.message
        }
        return result
    }

    /// No shell, no profile scripts and no agent task. The child is bounded and only receives --version.
    private static func versionOutput(executable: URL) async -> (version: String?, message: String?) {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["--version"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            do { try process.run() } catch { return (nil, "无法读取 CLI 版本") }
            let deadline = Date().addingTimeInterval(2)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            repeat {
                let readCount = Darwin.read(descriptor, &buffer, buffer.count)
                if readCount > 0 && output.count < 16_384 { output.append(contentsOf: buffer.prefix(min(readCount, 16_384 - output.count))) }
                if !process.isRunning { break }
                usleep(20_000)
            } while Date() < deadline
            if process.isRunning {
                process.terminate()
                usleep(50_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return (nil, "CLI 版本检测超时")
            }
            while output.count < 16_384 {
                let readCount = Darwin.read(descriptor, &buffer, buffer.count)
                if readCount <= 0 { break }
                output.append(contentsOf: buffer.prefix(min(readCount, 16_384 - output.count)))
            }
            let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            let line = lines.first { $0.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil }
            guard process.terminationStatus == 0, let line else { return (nil, "未能解析 CLI 版本") }
            return (String(line.prefix(180)), nil)
        }.value
    }
}
