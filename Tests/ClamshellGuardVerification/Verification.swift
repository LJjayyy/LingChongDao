import Darwin
import Foundation

private enum Failure: Error { case failed(String) }
private var launchedFakeProcesses: [Process] = []

@MainActor
private final class FakeLauncher {
    var alive = true
    var error = ""
    var time: TimeInterval = 0
    var lastCommand: ClamshellGuardCommand?
    var readyAtLaunch = false
    var cleanupOnSleep = false
    var launchCount = 0
    var preparationAtLaunch = false
    var recoveryAlive = true
    var recoveryCompletesAt: TimeInterval?
    var completeRecoveryImmediately = false
    let root: URL
    let records: URL
    init(root: URL) {
        self.root = root
        self.records = root.appendingPathComponent("records-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: records, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }
    var backend: ClamshellGuardBackend {
        ClamshellGuardBackend(temporaryDirectory: root, persistentRootURL: records, securityPolicy: .fixture(owner: getuid(), group: getgid()), appProcessID: 123, userID: getuid(),
            pmsetExecutable: root.appendingPathComponent("fake-pmset").path,
            processIsAliveExecutable: root.appendingPathComponent("fake-alive").path,
            sleepExecutable: "/bin/sleep", launch: { [self] command in
                launchCount += 1; lastCommand = command
                if let names = command.recoveryNames {
                    if completeRecoveryImmediately {
                        for name in names { try? FileManager.default.removeItem(at: records.appendingPathComponent(name)) }
                        recoveryAlive = false
                    }
                    return .init(isRunning: { [self] in recoveryAlive }, errorText: { [self] in error })
                }
                if preparationAtLaunch || readyAtLaunch {
                    try FileManager.default.createDirectory(at: command.recordURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
                }
                if readyAtLaunch {
                    for name in ["ready", "original-0", "changed-intent"] { try Data().write(to: command.recordURL.appendingPathComponent(name)) }
                }
                return .init(isRunning: { [self] in alive }, errorText: { [self] in error })
            }, now: { [self] in time }, sleepHook: { [self] delay in
                time += delay
                if let command = lastCommand, let names = command.recoveryNames, let completion = recoveryCompletesAt, time >= completion {
                    for name in names { try? FileManager.default.removeItem(at: records.appendingPathComponent(name)) }
                    recoveryAlive = false
                }
                if cleanupOnSleep, let command = lastCommand, FileManager.default.fileExists(atPath: command.stopFileURL.path) {
                    if FileManager.default.fileExists(atPath: command.recordURL.path) { try? Data().write(to: command.doneFileURL) }
                    alive = false
                }
                await Task.yield()
            })
    }
}

private final class FakeShellPower {
    let root: URL
    let state: URL
    let writes: URL
    let alive: URL
    let readFailure: URL
    let writeFailure: URL
    let pmset: URL
    let liveness: URL
    let sleeper: URL
    let bootLookup: URL
    let startLookup: URL
    let command: ClamshellGuardCommand
    var launches = 0

    init(root: URL, original: String) throws {
        self.root = root
        state = root.appendingPathComponent("state")
        writes = root.appendingPathComponent("writes")
        alive = root.appendingPathComponent("alive")
        readFailure = root.appendingPathComponent("read-failure")
        writeFailure = root.appendingPathComponent("write-failure")
        pmset = root.appendingPathComponent("fake pm'set")
        liveness = root.appendingPathComponent("fake alive")
        sleeper = root.appendingPathComponent("fake sleep")
        bootLookup = root.appendingPathComponent("fake boot")
        startLookup = root.appendingPathComponent("fake start")
        let dir = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        command = ClamshellGuardCommand(appProcessID: ProcessInfo.processInfo.processIdentifier, userID: getuid(), token: UUID().uuidString,
            directoryURL: dir, persistentRootURL: root.appendingPathComponent("records"), securityPolicy: .fixture(owner: getuid(), group: getgid()),
            pmsetExecutable: pmset.path, processIsAliveExecutable: liveness.path, sleepExecutable: sleeper.path,
            bootSessionExecutable: bootLookup.path, processStartExecutable: startLookup.path)
        try Data((original + "\n").utf8).write(to: state)
        try Data().write(to: alive)
        let q = ClamshellGuardCommand.quote
        let script = """
        #!/bin/sh
        if [ "$1" = -g ]; then
            [ -e \(q(readFailure.path)) ] && exit 1
            printf 'SleepDisabled %s\\n' "$(/bin/cat \(q(state.path)))"
            exit 0
        fi
        if [ "$1" = -a ] && [ "$2" = disablesleep ]; then
            printf '%s\\n' "$3" >> \(q(writes.path))
            [ -e \(q(writeFailure.path)) ] && exit 1
            printf '%s\\n' "$3" > \(q(state.path))
            exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: pmset)
        try Data("#!/bin/sh\n[ -f \(q(alive.path)) ]\n".utf8).write(to: liveness)
        try Data("#!/bin/sh\n/bin/sleep 0.02\n".utf8).write(to: sleeper)
        try Data("#!/bin/sh\nprintf 'boot-A\\n'\n".utf8).write(to: bootLookup)
        try Data("#!/bin/sh\nprintf 'start-A\\n'\n".utf8).write(to: startLookup)
        for url in [pmset, liveness, sleeper, bootLookup, startLookup] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    func run(syntaxOnly: Bool = false, override: ClamshellGuardCommand? = nil) throws -> Process {
        let command = override ?? self.command
        // This runner never launches osascript and all power/liveness paths are fakes.
        guard !command.watcherCommand.contains("/usr/bin/pmset"), command.pmsetExecutable == pmset.path else { throw Failure.failed("real power executable forbidden") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = syntaxOnly ? ["-n", "-c", command.watcherCommand] : ["-c", command.watcherCommand]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        launchedFakeProcesses.append(process)
        return process
    }
    func makeRecord(original: String = "0", intent: Bool = true, ownerPID: Int32? = nil, boot: String = "boot-A", start: String = "start-A", partial: Bool = false) throws -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: command.persistentRootURL.path) {
            try manager.createDirectory(at: command.persistentRootURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        try manager.createDirectory(at: command.recordURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        if !partial {
            for (name, value) in [("uid", String(command.userID)), ("token", command.token), ("owner-pid", String(ownerPID ?? command.appProcessID)), ("boot-id", boot), ("owner-start", start)] {
                try Data((value + "\n").utf8).write(to: command.recordURL.appendingPathComponent(name))
            }
            try Data().write(to: command.recordURL.appendingPathComponent("original-" + original))
        }
        if intent { try Data().write(to: command.recordURL.appendingPathComponent("changed-intent")) }
        return command.recordURL
    }
    var backend: ClamshellGuardBackend {
        ClamshellGuardBackend(temporaryDirectory: root, persistentRootURL: command.persistentRootURL,
            securityPolicy: command.securityPolicy, appProcessID: command.appProcessID, userID: command.userID,
            pmsetExecutable: pmset.path, processIsAliveExecutable: liveness.path, sleepExecutable: sleeper.path,
            bootSessionExecutable: bootLookup.path, processStartExecutable: startLookup.path,
            launch: { [self] next in
                launches += 1
                let process = try run(override: next)
                return .init(isRunning: { process.isRunning }, errorText: { "fake launcher failed" })
            }, now: { ProcessInfo.processInfo.systemUptime }, sleepHook: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            })
    }
    var writeValues: [String] { ((try? String(contentsOf: writes, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init) }
    var stateValue: String { ((try? String(contentsOf: state, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

@main
private struct Verification {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard value() else { throw Failure.failed(message) }
    }
    @MainActor static func waitFor(_ test: () -> Bool, fileLine: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !test() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.failed("fake shell wait timed out near line \(fileLine)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func shellFixture(_ base: URL, _ name: String, _ original: String) throws -> FakeShellPower {
        let root = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return try FakeShellPower(root: root, original: original)
    }
    @MainActor static func main() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ClamshellFake-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            defer {
                for process in launchedFakeProcesses where process.isRunning { kill(process.processIdentifier, SIGKILL) }
                try? FileManager.default.removeItem(at: base)
            }
            let originalOne = try shellFixture(base, "original one", "1")
            let syntax = try originalOne.run(syntaxOnly: true)
            try await waitFor { !syntax.isRunning }
            try expect(syntax.terminationStatus == 0, "watcher shell syntax is valid with spaces and quotes")
            try expect(originalOne.command.appleScript.contains("with administrator privileges"), "production authorization uses explicit administrator AppleScript")
            let compiler = Process(), input = Pipe()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            compiler.arguments = ["-o", base.appendingPathComponent("offline-guard.scpt").path, "-"]
            compiler.standardInput = input
            compiler.standardOutput = FileHandle.nullDevice
            compiler.standardError = FileHandle.nullDevice
            try compiler.run()
            launchedFakeProcesses.append(compiler)
            input.fileHandleForWriting.write(Data(originalOne.command.appleScript.utf8))
            try input.fileHandleForWriting.close()
            try await waitFor { !compiler.isRunning }
            try expect(compiler.terminationStatus == 0, "administrator AppleScript compiles offline without executing or authorizing")
            try expect(originalOne.command.appleScript.contains("\\\\''"), "shell and AppleScript layers escape quoted paths")
            let one = try originalOne.run()
            try await waitFor { FileManager.default.fileExists(atPath: originalOne.command.readyFileURL.path) }
            try Data().write(to: originalOne.command.stopFileURL)
            try await waitFor { !one.isRunning }
            try expect(originalOne.writeValues.isEmpty && originalOne.stateValue == "1", "original one never writes or restores another tool's choice")

            let zero = try shellFixture(base, "original zero", "0")
            let zeroProcess = try zero.run()
            try await waitFor { FileManager.default.fileExists(atPath: zero.command.readyFileURL.path) }
            try expect(zero.writeValues == ["1"] && zero.stateValue == "1", "original zero enables exactly once")
            try Data().write(to: zero.command.stopFileURL)
            try await waitFor { !zeroProcess.isRunning }
            try expect(zero.writeValues == ["1", "0"] && zero.stateValue == "0", "stop restores captured zero")
            try expect(!FileManager.default.fileExists(atPath: zero.command.recordURL.path), "root watcher removes its confirmed-restored evidence after observation grace")

            let death = try shellFixture(base, "app death", "0")
            let deathProcess = try death.run()
            try await waitFor { FileManager.default.fileExists(atPath: death.command.readyFileURL.path) }
            try FileManager.default.removeItem(at: death.alive)
            try await waitFor { !deathProcess.isRunning }
            try expect(death.writeValues == ["1", "0"], "parent death restores zero")

            let external = try shellFixture(base, "external off", "0")
            let externalProcess = try external.run()
            try await waitFor { FileManager.default.fileExists(atPath: external.command.readyFileURL.path) }
            try Data("0\n".utf8).write(to: external.state)
            try await waitFor { !externalProcess.isRunning }
            try expect(external.writeValues == ["1"] && external.stateValue == "0", "external off exits without re-enabling or redundant restore")

            let readFailure = try shellFixture(base, "unknown original", "0")
            try Data().write(to: readFailure.readFailure)
            let unreadable = try readFailure.run()
            try await waitFor { !unreadable.isRunning }
            try expect(readFailure.writeValues.isEmpty, "unknown original never writes")
            try expect(!FileManager.default.fileExists(atPath: readFailure.command.readyFileURL.path), "failed initial read never signals ready")

            let failedStart = try shellFixture(base, "failed enable", "0")
            try Data().write(to: failedStart.writeFailure)
            let failedStartProcess = try failedStart.run()
            try await waitFor { !failedStartProcess.isRunning }
            try expect(!FileManager.default.fileExists(atPath: failedStart.command.readyFileURL.path), "failed enable never signals ready")
            try FileManager.default.removeItem(at: failedStart.writeFailure)
            try await waitFor { !failedStartProcess.isRunning }
            try expect(failedStart.stateValue == "0" && failedStart.writeValues.first == "1", "partial enable failure restores only captured zero")

            let runtimeRead = try shellFixture(base, "runtime read failure", "0")
            let runtimeReadProcess = try runtimeRead.run()
            try await waitFor { FileManager.default.fileExists(atPath: runtimeRead.command.readyFileURL.path) }
            try Data().write(to: runtimeRead.readFailure)
            try await waitFor { FileManager.default.fileExists(atPath: runtimeRead.command.failedFileURL.path) }
            try expect(runtimeRead.stateValue == "0" && runtimeRead.writeValues.filter { $0 == "1" }.count == 1, "runtime read failure restores zero without forcing enable")
            try FileManager.default.removeItem(at: runtimeRead.readFailure)
            try await waitFor { !runtimeReadProcess.isRunning }

            let canceled = try shellFixture(base, "late authorization", "0")
            try Data().write(to: canceled.command.stopFileURL)
            let late = try canceled.run()
            try await waitFor { !late.isRunning }
            try expect(canceled.writeValues.isEmpty, "stop before delayed authorization cannot enable later")

            let failedRestore = try shellFixture(base, "restore retry", "0")
            let retryProcess = try failedRestore.run()
            try await waitFor { FileManager.default.fileExists(atPath: failedRestore.command.readyFileURL.path) }
            try Data().write(to: failedRestore.writeFailure)
            try Data().write(to: failedRestore.command.stopFileURL)
            try await waitFor { FileManager.default.fileExists(atPath: failedRestore.command.failedFileURL.path) }
            try expect(retryProcess.isRunning && !FileManager.default.fileExists(atPath: failedRestore.command.doneFileURL.path), "restore failure keeps watcher and no false done")
            try FileManager.default.removeItem(at: failedRestore.writeFailure)
            try await waitFor { !retryProcess.isRunning }
            try expect(failedRestore.stateValue == "0", "watcher retries restoration after failure")

            let symlink = try shellFixture(base, "symlink", "0")
            let target = symlink.root.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: symlink.command.persistentRootURL, withDestinationURL: target)
            let symlinkProcess = try symlink.run()
            try await waitFor { !symlinkProcess.isRunning }
            try expect((try? FileManager.default.contentsOfDirectory(atPath: target.path)) == [] && symlink.writeValues.isEmpty, "root state tree never follows a substituted parent symlink")

            let launched = FakeLauncher(root: base)
            launched.readyAtLaunch = true; launched.cleanupOnSleep = true
            let guardController = ClamshellSleepGuard(backend: launched.backend, startupTimeout: 0.3, stopTimeout: 0.3)
            try expect(!guardController.isRunning && launched.launchCount == 0, "default construction performs no authorization")
            try await guardController.start()
            try expect(guardController.isRunning, "ready guard reports active")
            let privateDirectory = launched.lastCommand!.directoryURL
            let permissions = try FileManager.default.attributesOfItem(atPath: privateDirectory.path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o700, "session directory is private")
            try await guardController.start()
            try expect(launched.launchCount == 1, "ready start does not duplicate watcher")
            let stopped = await guardController.stop()
            try expect(stopped && !guardController.isRunning && !FileManager.default.fileExists(atPath: privateDirectory.path), "confirmed stop discards private session")

            let denied = FakeLauncher(root: base)
            denied.alive = false; denied.error = "execution error: User canceled. (-128)"
            let deniedGuard = ClamshellSleepGuard(backend: denied.backend)
            do { try await deniedGuard.start(); throw Failure.failed("cancelled authorization unexpectedly succeeded") }
            catch ClamshellSleepGuardError.authorizationCancelled { }
            try expect(!deniedGuard.isRunning && !FileManager.default.fileExists(atPath: denied.lastCommand!.directoryURL.path), "cancelled authorization is distinguished and safely discarded before mutation")
            try expect(ClamshellSleepGuardError.authorizationError("not authorized (-60005)") == .authorizationDenied, "denied authorization is distinguished")

            let timeout = FakeLauncher(root: base)
            let timeoutGuard = ClamshellSleepGuard(backend: timeout.backend, startupTimeout: 0.2, stopTimeout: 0.2)
            do { try await timeoutGuard.start(); throw Failure.failed("pending authorization unexpectedly succeeded") }
            catch ClamshellSleepGuardError.startupTimedOut { }
            let pendingCommand = timeout.lastCommand!
            try expect(!timeoutGuard.isRunning && FileManager.default.fileExists(atPath: pendingCommand.stopFileURL.path), "pending authorization is not active and retains its cancellation marker")
            let timedOutStop = await timeoutGuard.stop()
            try expect(!timedOutStop && !timeoutGuard.isRunning, "bounded stop cannot falsely confirm a pending launcher")
            timeout.cleanupOnSleep = true
            let retried = await timeoutGuard.stop()
            try expect(retried && !timeoutGuard.isRunning, "stop can retry after launcher confirms cleanup")
            let cancellation = FakeLauncher(root: base)
            var pause: CheckedContinuation<Void, Never>?
            var cancelBackend = cancellation.backend
            cancelBackend.sleepHook = { _ in await withCheckedContinuation { pause = $0 } }
            let cancelGuard = ClamshellSleepGuard(backend: cancelBackend)
            let starting = Task { try await cancelGuard.start() }
            while pause == nil { await Task.yield() }
            starting.cancel()
            pause?.resume()
            do { try await starting.value; throw Failure.failed("cancelled start unexpectedly succeeded") }
            catch is CancellationError { }
            try expect(FileManager.default.fileExists(atPath: cancellation.lastCommand!.stopFileURL.path), "task cancellation preserves stop marker against late authorization")
            cancellation.alive = false
            let canceledStopped = await cancelGuard.stop()
            try expect(canceledStopped, "cancelled launch is discarded only after process exits without mutation")
            try expect(ClamshellSleepGuardError.launchFailed.userMessage?.contains("pmset") == false, "errors never expose raw commands")
            let stoppedPreparation = FakeLauncher(root: base)
            stoppedPreparation.preparationAtLaunch = true
            stoppedPreparation.alive = false
            let preparationGuard = ClamshellSleepGuard(backend: stoppedPreparation.backend, stopTimeout: 0.2)
            do { try await preparationGuard.start(); throw Failure.failed("dead preparation unexpectedly started") } catch ClamshellSleepGuardError.launchFailed { }
            let preparationInput = stoppedPreparation.lastCommand!.directoryURL
            let preparationStopped = await preparationGuard.stop()
            try expect(preparationStopped && !preparationGuard.needsRecovery && !preparationGuard.isRunning, "dead current no-intent preparation does not trap pendingClient forever")
            try expect(FileManager.default.fileExists(atPath: preparationInput.appendingPathComponent("stop").path), "dead preparation preserves stop against late broker execution")

            let noIntent = try shellFixture(base, "partial journal", "1")
            _ = try noIntent.makeRecord(intent: false, partial: true)
            let noIntentGuard = ClamshellSleepGuard(backend: noIntent.backend)
            try expect(!noIntentGuard.needsRecovery, "interrupted metadata without write intent never blocks startup or owns global power")
            let noIntentStop = await noIntentGuard.stop()
            try expect(noIntentStop && noIntent.launches == 0 && noIntent.writeValues.isEmpty, "no-intent journal causes no authorization and no reset")

            let stale = try shellFixture(base, "cross startup", "1")
            _ = try stale.makeRecord(ownerPID: stale.command.appProcessID + 1, boot: "previous-boot")
            let staleGuard = ClamshellSleepGuard(backend: stale.backend)
            try expect(staleGuard.needsRecovery && !staleGuard.isRunning && stale.launches == 0 && stale.writeValues.isEmpty, "fresh process only inspects trusted stale write intent")
            do { try await staleGuard.start(); throw Failure.failed("stale power unexpectedly enabled") } catch ClamshellSleepGuardError.cleanupRequired { }
            let restoredStale = await staleGuard.stop()
            try expect(restoredStale && !staleGuard.needsRecovery && stale.stateValue == "0", "explicit cross-startup restoration tolerates reused PID from older boot")
            try expect(stale.writeValues == ["0"], "stale restore never enables power first")

            let invalidIntent = try shellFixture(base, "incomplete intent metadata", "1")
            _ = try invalidIntent.makeRecord(intent: true, partial: true)
            let invalidIntentGuard = ClamshellSleepGuard(backend: invalidIntent.backend)
            let invalidStopped = await invalidIntentGuard.stop()
            try expect(!invalidStopped && invalidIntentGuard.needsRecovery && invalidIntent.writeValues.isEmpty, "intent without trusted complete metadata retains recovery instead of guessing a global reset")

            let reusedPID = try shellFixture(base, "same boot reused PID", "1")
            _ = try reusedPID.makeRecord(ownerPID: reusedPID.command.appProcessID + 1, start: "old-start")
            var reusedCommand = reusedPID.command
            reusedCommand.recoveryNames = [reusedCommand.sessionName]
            let reusedProcess = try reusedPID.run(override: reusedCommand)
            try await waitFor { !reusedProcess.isRunning }
            try expect(reusedProcess.terminationStatus == 0 && reusedPID.stateValue == "0", "same-boot PID reuse is distinguished by process start identity")

            let foreign = try shellFixture(base, "foreign active", "1")
            _ = try foreign.makeRecord(ownerPID: foreign.command.appProcessID + 1)
            var foreignCommand = foreign.command
            foreignCommand.recoveryNames = [foreignCommand.sessionName]
            let foreignProcess = try foreign.run(override: foreignCommand)
            try await waitFor { !foreignProcess.isRunning }
            try expect(foreignProcess.terminationStatus != 0 && foreign.writeValues.isEmpty && foreign.stateValue == "1", "another still-running instance on same boot is never reset")

            let priorOne = try shellFixture(base, "stale original one", "1")
            _ = try priorOne.makeRecord(original: "1", intent: false)
            let priorOneGuard = ClamshellSleepGuard(backend: priorOne.backend)
            let priorOneStopped = await priorOneGuard.stop()
            try expect(priorOneStopped && !priorOneGuard.needsRecovery && priorOne.launches == 0 && priorOne.writeValues.isEmpty && priorOne.stateValue == "1", "pre-existing original one is not claimed or reset across launches")

            let untrusted = try shellFixture(base, "untrusted record", "1")
            let untrustedRecord = try untrusted.makeRecord()
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: untrustedRecord.path)
            let untrustedGuard = ClamshellSleepGuard(backend: untrusted.backend)
            try expect(!untrustedGuard.needsRecovery && untrusted.writeValues.isEmpty, "user-writable record is not trusted as power ownership evidence")
            let wrongUID = try shellFixture(base, "wrong uid", "1")
            _ = try wrongUID.makeRecord()
            let renamed = wrongUID.command.persistentRootURL.appendingPathComponent("u\(getuid() + 1)-\(wrongUID.command.token)")
            try FileManager.default.moveItem(at: wrongUID.command.recordURL, to: renamed)
            let wrongUIDGuard = ClamshellSleepGuard(backend: wrongUID.backend)
            try expect(!wrongUIDGuard.needsRecovery, "another uid journal cannot be selected for recovery")

            let immediateRecovery = FakeLauncher(root: base)
            immediateRecovery.readyAtLaunch = true
            let immediateGuard = ClamshellSleepGuard(backend: immediateRecovery.backend)
            try await immediateGuard.start()
            immediateRecovery.alive = false
            immediateRecovery.completeRecoveryImmediately = true
            let immediateStopped = await immediateGuard.stop()
            try expect(immediateStopped && !immediateGuard.needsRecovery, "immediate recovery reconciles current stale session before reporting success")

            let delayedRecovery = FakeLauncher(root: base)
            delayedRecovery.readyAtLaunch = true
            let delayedGuard = ClamshellSleepGuard(backend: delayedRecovery.backend, startupTimeout: 20, stopTimeout: 0.2)
            try await delayedGuard.start()
            delayedRecovery.alive = false
            delayedRecovery.recoveryCompletesAt = 1
            let delayedStopped = await delayedGuard.stop()
            try expect(delayedStopped && delayedRecovery.time >= 1, "recovery authorization has startup timeout rather than short stop deadline")
            print("PASS: \(checks) clamshell guard checks; fake shell power and fake authorization only")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
