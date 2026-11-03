import Foundation

@MainActor
private final class FakeUpdateEngine: AppUpdateEngine {
    var event: ((AppUpdateEvent) -> Void)?
    var sessionInProgress = false
    var probes = 0
    var presentations = 0
    func start() throws {}
    func probe() { probes += 1; sessionInProgress = true }
    func present() { presentations += 1; sessionInProgress = true }
    func finish(success: Bool) { sessionInProgress = false; event?(.finished(success: success)) }
}

@main
struct AppUpdateVerification {
    @MainActor static func main() async {
        let tests = AppUpdateVerification()
        tests.testBackgroundDiscoveryOnlyUpdatesIndicatorAndRespectsDailySchedule()
        tests.testNetworkFailureRetainsKnownUpdateAndRetriesAfterAnHour()
        await tests.testClickDuringProbeIsPresentedAfterCompletion()
        tests.testDismissRetainsDotSkipClearsItAndSuccessfulUpgradeClearsCache()
        await tests.testNoUpdateClearsIndicatorAndStopCancelsPendingPresentation()
        print("PASS: application updates — silent checks, scheduling, failure, click race, cache, skip and stop")
    }
    @MainActor
    private func fixture() -> (AppUpdateController, FakeUpdateEngine, UserDefaults, String) {
        let suite = "local.lingchongdao.update-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let engine = FakeUpdateEngine()
        return (AppUpdateController(engine: engine, defaults: defaults, currentBuild: "43"), engine, defaults, suite)
    }

    @MainActor
    func testBackgroundDiscoveryOnlyUpdatesIndicatorAndRespectsDailySchedule() {
        let (controller, engine, defaults, suite) = fixture()
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        controller.start()
        expectEqual(engine.probes, 1)
        engine.event?(.found("44"))
        engine.finish(success: true)
        expectTrue(controller.hasUpdate)
        expectEqual(engine.presentations, 0)
        controller.checkIfDue()
        expectEqual(engine.probes, 1)
        controller.checkIfDue(now: Date().addingTimeInterval(24 * 3600 + 1))
        expectEqual(engine.probes, 2)
    }

    @MainActor
    func testNetworkFailureRetainsKnownUpdateAndRetriesAfterAnHour() {
        let (controller, engine, defaults, suite) = fixture()
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        controller.start()
        engine.event?(.found("44"))
        engine.finish(success: false)
        expectTrue(controller.hasUpdate)
        expectEqual(engine.presentations, 0)
        controller.checkIfDue(now: Date().addingTimeInterval(3590))
        expectEqual(engine.probes, 1)
        controller.checkIfDue(now: Date().addingTimeInterval(3610))
        expectEqual(engine.probes, 2)
    }

    @MainActor
    func testClickDuringProbeIsPresentedAfterCompletion() async {
        let (controller, engine, defaults, suite) = fixture()
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        controller.start()
        controller.presentUpdate()
        controller.presentUpdate()
        expectEqual(engine.presentations, 0)
        engine.finish(success: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        expectEqual(engine.presentations, 1)
    }

    @MainActor
    func testDismissRetainsDotSkipClearsItAndSuccessfulUpgradeClearsCache() {
        let (controller, engine, defaults, suite) = fixture()
        defer { controller.stop(); defaults.removePersistentDomain(forName: suite) }
        controller.start()
        engine.event?(.found("44"))
        engine.finish(success: true) // A dismissed update is a normal completion.
        expectTrue(controller.hasUpdate)
        let relaunched = AppUpdateController(engine: FakeUpdateEngine(), defaults: defaults, currentBuild: "43")
        expectTrue(relaunched.hasUpdate)
        let upgraded = AppUpdateController(engine: FakeUpdateEngine(), defaults: defaults, currentBuild: "44")
        expectFalse(upgraded.hasUpdate)
        engine.event?(.found("45"))
        engine.event?(.skipped)
        expectFalse(controller.hasUpdate)
        let afterSkip = AppUpdateController(engine: FakeUpdateEngine(), defaults: defaults, currentBuild: "43")
        expectFalse(afterSkip.hasUpdate)
    }

    @MainActor
    func testNoUpdateClearsIndicatorAndStopCancelsPendingPresentation() async {
        let (controller, engine, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.start()
        engine.event?(.found("44"))
        engine.event?(.noUpdate)
        expectFalse(controller.hasUpdate)
        controller.presentUpdate()
        controller.stop()
        engine.finish(success: true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        expectEqual(engine.presentations, 0)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
