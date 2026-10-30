import Darwin
import Foundation
import IOKit.pwr_mgt

private enum VerificationFailure: Error { case failed(String) }

private final class FakePowerBackend {
    var creations: [KeepAwakeAssertionKind] = []
    var releases: [IOPMAssertionID] = []
    var responses: [Result<IOPMAssertionID, KeepAwakeBackendFailure>]
    var failuresRemaining: [IOPMAssertionID: Int] = [:]
    var active: Set<IOPMAssertionID> = [999] // An unrelated application's resource.
    init(_ responses: [Result<IOPMAssertionID, KeepAwakeBackendFailure>] = [.success(101), .success(102)]) { self.responses = responses }
    var backend: KeepAwakeBackend {
        KeepAwakeBackend(create: { [self] kind in
            creations.append(kind)
            guard !responses.isEmpty else { return .failure(.creationFailed) }
            let result = responses.removeFirst()
            if case .success(let id) = result { active.insert(id) }
            return result
        }, release: { [self] id in
            releases.append(id)
            if failuresRemaining[id, default: 0] > 0 { failuresRemaining[id, default: 0] -= 1; return false }
            active.remove(id)
            return true
        })
    }
}

@MainActor
private final class FakeClamshellGuard: ClamshellSleepGuardControlling {
    var isRunning = false
    var needsRecovery = false
    var startError: ClamshellSleepGuardError?
    var cleanupSucceeds = true
    var starts = 0
    var stops = 0
    func start() async throws {
        starts += 1
        if let startError { throw startError }
        isRunning = true
    }
    func stop() async -> Bool { stops += 1; if cleanupSucceeds { isRunning = false; needsRecovery = false }; return cleanupSucceeds }
    func requestStop() { if cleanupSucceeds { isRunning = false } }
}

@MainActor
private final class PendingAuthorizationGuard: ClamshellSleepGuardControlling {
    var isRunning = false
    var starts = 0
    var stops = 0
    func start() async throws {
        starts += 1
        try await Task.sleep(for: .seconds(3600))
        isRunning = true
    }
    func stop() async -> Bool { stops += 1; isRunning = false; return true }
    func requestStop() { isRunning = false }
}

@main
private struct KeepAwakeVerification {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw VerificationFailure.failed(message) }
    }
    @MainActor static func main() async {
        do {
            let ordinary = FakePowerBackend()
            let controller = KeepAwakeController(backend: ordinary.backend, clamshellGuard: FakeClamshellGuard())
            try expect(controller.state == .off && !controller.isEnabled && !controller.isFullyEnabled, "default off")
            try expect(ordinary.creations.isEmpty && ordinary.releases.isEmpty, "initialization must not touch power assertions")
            controller.setEnabled(true)
            await controller.waitForTransition()
            try expect(controller.state == .on && controller.isEnabled && controller.isFullyEnabled, "two successes enable fully")
            try expect(ordinary.creations == [.system, .display], "create system and display exactly once")
            controller.setEnabled(true)
            await controller.waitForTransition()
            try expect(ordinary.creations.count == 2, "repeated enable creates no duplicates")
            controller.stop()
            await controller.waitForTransition()
            try expect(controller.state == .off && !controller.isEnabled, "stop disables")
            try expect(Set(ordinary.releases) == [101, 102] && ordinary.releases.count == 2, "release each owned assertion once")
            try expect(ordinary.active == [999], "external assertion stays untouched")
            controller.stop()
            await controller.waitForTransition()
            try expect(ordinary.releases.count == 2, "repeated stop is idempotent")

            let firstFailure = FakePowerBackend([.failure(.creationFailed)])
            let noSystem = KeepAwakeController(backend: firstFailure.backend, clamshellGuard: FakeClamshellGuard())
            noSystem.setEnabled(true)
            await noSystem.waitForTransition()
            try expect(noSystem.state == .off && noSystem.errorMessage != nil, "system create failure stays off with error")
            try expect(firstFailure.creations == [.system] && firstFailure.releases.isEmpty, "first failure never creates display or releases foreign resources")
            noSystem.clearError()
            try expect(noSystem.errorMessage == nil && noSystem.state == .off, "clear error has no power effects")

            let secondFailure = FakePowerBackend([.success(201), .failure(.creationFailed)])
            let noDisplay = KeepAwakeController(backend: secondFailure.backend, clamshellGuard: FakeClamshellGuard())
            noDisplay.setEnabled(true)
            await noDisplay.waitForTransition()
            try expect(noDisplay.state == .off && !noDisplay.isEnabled && noDisplay.errorMessage != nil, "display failure rolls back system")
            try expect(secondFailure.releases == [201] && secondFailure.active == [999], "successful rollback releases only owned system ID")

            let rollbackFailure = FakePowerBackend([.success(301), .failure(.creationFailed)])
            rollbackFailure.failuresRemaining[301] = 1
            let partial = KeepAwakeController(backend: rollbackFailure.backend, clamshellGuard: FakeClamshellGuard())
            partial.setEnabled(true)
            await partial.waitForTransition()
            try expect(partial.state == .partial && partial.isEnabled && !partial.isFullyEnabled, "rollback failure retains partial ownership")
            try expect(partial.errorMessage != nil && rollbackFailure.active == [301, 999], "partial failure is visible")
            partial.setEnabled(true)
            await partial.waitForTransition()
            try expect(rollbackFailure.creations.count == 2, "partial enable does not duplicate assertions")
            partial.toggle()
            await partial.waitForTransition()
            try expect(partial.state == .off && partial.errorMessage == nil && rollbackFailure.releases == [301, 301], "toggle in partial retries close")

            let releaseFailure = FakePowerBackend()
            releaseFailure.failuresRemaining[102] = 1
            let closeRetry = KeepAwakeController(backend: releaseFailure.backend, clamshellGuard: FakeClamshellGuard())
            closeRetry.toggle()
            await closeRetry.waitForTransition()
            closeRetry.setEnabled(false)
            await closeRetry.waitForTransition()
            try expect(closeRetry.state == .partial && closeRetry.isEnabled && !closeRetry.isFullyEnabled, "one release failure must not report off")
            try expect(releaseFailure.releases == [102, 101], "failed display release must not skip system cleanup")
            closeRetry.stop()
            await closeRetry.waitForTransition()
            try expect(closeRetry.state == .off && releaseFailure.releases == [102, 101, 102], "stop retries only failed release")
            try expect(releaseFailure.active == [999], "close retry does not touch external resources")

            let death = FakePowerBackend()
            var scoped: KeepAwakeController? = KeepAwakeController(backend: death.backend, clamshellGuard: FakeClamshellGuard())
            scoped?.setEnabled(true)
            await scoped?.waitForTransition()
            scoped = nil
            try expect(Set(death.releases) == [101, 102] && death.active == [999], "deinit best effort releases owned resources")
            let nextRun = FakePowerBackend()
            let fresh = KeepAwakeController(backend: nextRun.backend, clamshellGuard: FakeClamshellGuard())
            try expect(fresh.state == .off && nextRun.creations.isEmpty, "fresh controller never restores a persistent enabled state")
            let cancelledGuard = FakeClamshellGuard()
            cancelledGuard.startError = .authorizationCancelled
            let cancelledBackend = FakePowerBackend()
            let cancelled = KeepAwakeController(backend: cancelledBackend.backend, clamshellGuard: cancelledGuard)
            cancelled.toggle()
            try expect(cancelled.isChanging && !cancelled.isFullyEnabled, "authorization pending never reports fully enabled")
            await cancelled.waitForTransition()
            try expect(cancelled.state == .off && cancelled.errorMessage == nil && !cancelled.isChanging, "cancelled authorization quietly returns off")
            try expect(cancelledBackend.creations.isEmpty, "authorization cancellation never creates idle assertions")

            let deniedGuard = FakeClamshellGuard()
            deniedGuard.startError = .authorizationDenied
            let deniedBackend = FakePowerBackend()
            let denied = KeepAwakeController(backend: deniedBackend.backend, clamshellGuard: deniedGuard)
            denied.toggle(); await denied.waitForTransition()
            try expect(denied.state == .off && denied.errorMessage != nil && deniedBackend.creations.isEmpty, "denied authorization stays off and visible")

            let retainedGuard = FakeClamshellGuard()
            let retained = KeepAwakeController(backend: FakePowerBackend().backend, clamshellGuard: retainedGuard)
            retained.toggle(); await retained.waitForTransition()
            try expect(retained.isFullyEnabled && retainedGuard.starts == 1, "success includes privileged guard")
            retainedGuard.cleanupSucceeds = false
            retained.stop(); await retained.waitForTransition()
            try expect(retained.state == .partial && retained.errorMessage != nil, "failed global restoration retains ownership")
            let failedTermination = await retained.stopBeforeTermination()
            try expect(!failedTermination, "termination is deferred when restoration fails")
            retainedGuard.cleanupSucceeds = true
            let passedTermination = await retained.stopBeforeTermination()
            try expect(passedTermination, "termination retry restores and permits exit")
            try expect(retained.state == .off, "termination success clears ownership")
            let staleGuard = FakeClamshellGuard()
            staleGuard.needsRecovery = true
            let staleBackend = FakePowerBackend()
            let stale = KeepAwakeController(backend: staleBackend.backend, clamshellGuard: staleGuard)
            try expect(stale.state == .partial && !stale.isFullyEnabled && stale.errorMessage != nil, "stale trusted ownership requires explicit restoration")
            try expect(staleGuard.starts == 0 && staleGuard.stops == 0 && staleBackend.creations.isEmpty, "startup recovery inspection never asks for authorization or changes power")
            stale.toggle(); await stale.waitForTransition()
            try expect(stale.state == .off && !staleGuard.needsRecovery && staleGuard.starts == 0, "explicit restore clears stale state without enabling")

            let pendingGuard = PendingAuthorizationGuard()
            let pendingBackend = FakePowerBackend()
            let pending = KeepAwakeController(backend: pendingBackend.backend, clamshellGuard: pendingGuard)
            pending.toggle()
            await Task.yield()
            pending.toggle()
            try expect(pending.isChanging && !pending.isFullyEnabled && pendingBackend.creations.isEmpty, "pending authorization cannot create assertions or accept duplicate toggles")
            let cancelledExit = await pending.stopBeforeTermination()
            try expect(cancelledExit && pending.state == .off && pendingGuard.starts <= 1, "quit cancels pending authorization before restoring and exiting")
            try expect(pendingBackend.creations.isEmpty, "late cancelled authorization never enables idle assertions")

            let lostGuard = FakeClamshellGuard()
            let lostBackend = FakePowerBackend()
            let lost = KeepAwakeController(backend: lostBackend.backend, clamshellGuard: lostGuard)
            lost.toggle(); await lost.waitForTransition()
            lostGuard.isRunning = false
            let deadline = ContinuousClock.now + .seconds(4)
            while lost.state == .on && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await lost.waitForTransition()
            try expect(lost.state == .off && lost.errorMessage != nil, "dead privileged guard cannot keep reporting fully enabled")
            try expect(lostBackend.active == [999], "dead guard releases only this instance's idle assertions")
            let crashedGuard = FakeClamshellGuard()
            let crashedBackend = FakePowerBackend()
            let crashed = KeepAwakeController(backend: crashedBackend.backend, clamshellGuard: crashedGuard)
            crashed.toggle(); await crashed.waitForTransition()
            crashedGuard.isRunning = false
            crashedGuard.needsRecovery = true
            let crashDeadline = ContinuousClock.now + .seconds(4)
            while crashed.state == .on && ContinuousClock.now < crashDeadline { try? await Task.sleep(for: .milliseconds(50)) }
            try expect(crashed.state == .partial && crashed.errorMessage != nil && crashedGuard.stops == 0, "crashed watcher requires explicit recovery without automatic administrator prompt")
            try expect(crashedBackend.active == [999], "crashed watcher releases idle assertions while retaining cleanup ownership")
            crashed.stop(); await crashed.waitForTransition()
            try expect(crashed.state == .off && crashedGuard.stops == 1, "explicit recovery restores crashed guard state")
            print("PASS: \(checks) keep awake checks; fake backends only, no real power changes")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
