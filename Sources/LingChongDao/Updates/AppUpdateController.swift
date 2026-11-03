import AppKit
import Combine
import Sparkle

@MainActor
protocol AppUpdateEngine: AnyObject {
    var event: ((AppUpdateEvent) -> Void)? { get set }
    var sessionInProgress: Bool { get }
    func start() throws
    func probe()
    func present()
}

enum AppUpdateEvent {
    case found(String)
    case noUpdate
    case skipped
    case finished(success: Bool)
    case installing
}

/// Only information probes are scheduled. Sparkle's UI is entered by a click.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let releasesURL = URL(string: "https://github.com/LJjayyy/LingChongDao/releases")!
    @Published private(set) var hasUpdate = false
    private(set) var isInstalling = false
    private var engine: AppUpdateEngine?
    private let defaults: UserDefaults
    private let currentBuild: String
    private var timer: Timer?
    private var pendingPresentation = false
    private var started = false
    private var probing = false
    private var nextCheck = Date.distantPast
    private static let cachedVersionKey = "appUpdate.availableBuild"
    private static let nextCheckKey = "appUpdate.nextCheck"

    convenience init() {
        let bundle = Bundle.main
        let args = CommandLine.arguments
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let enabled = bundle.bundleURL.pathExtension == "app"
            && bundle.object(forInfoDictionaryKey: "LingChongDaoBuildConfiguration") as? String == "release"
            && !args.contains("--isolated") && !args.contains("--preview")
            && bundle.object(forInfoDictionaryKey: "LingChongDaoUpdateTesting") as? Bool != true
            && Data(base64Encoded: key)?.count == 32
            && feed == "https://github.com/LJjayyy/LingChongDao/releases/latest/download/appcast.xml"
        self.init(engine: enabled ? SparkleUpdateEngine(bundle: bundle) : nil,
                  defaults: .standard,
                  currentBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
        if args.contains("--isolated") && args.contains("--preview-update") { hasUpdate = true }
    }

    init(engine: AppUpdateEngine?, defaults: UserDefaults, currentBuild: String) {
        self.engine = engine
        self.defaults = defaults
        self.currentBuild = currentBuild
        if engine != nil, let cached = defaults.string(forKey: Self.cachedVersionKey) {
            hasUpdate = SUStandardVersionComparator.default.compareVersion(cached, toVersion: currentBuild) == .orderedDescending
            if !hasUpdate { defaults.removeObject(forKey: Self.cachedVersionKey) }
        }
        nextCheck = defaults.object(forKey: Self.nextCheckKey) as? Date ?? .distantPast
        // Avoid a clock adjustment postponing checks indefinitely.
        if nextCheck.timeIntervalSinceNow > 24 * 3600 { nextCheck = .distantPast }
        engine?.event = { [weak self] event in self?.receive(event) }
    }

    func start() {
        guard !started, let engine else { return }
        do { try engine.start() } catch { return } // Background configuration errors stay silent.
        started = true
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer?.tolerance = 60
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingPresentation = false
        started = false
    }

    func checkIfDue(now: Date = Date()) {
        guard started, let engine, !engine.sessionInProgress, !pendingPresentation, now >= nextCheck else { return }
        probing = true
        engine.probe()
    }

    func presentUpdate() {
        guard let engine, started else {
            let alert = NSAlert()
            alert.messageText = "此构建未启用应用内更新"
            alert.informativeText = "可以前往 GitHub 查看并下载最新版本。"
            alert.addButton(withTitle: "打开 GitHub")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
            return
        }
        if probing {
            pendingPresentation = true
            return
        }
        engine.present()
    }

    private func receive(_ event: AppUpdateEvent) {
        switch event {
        case .found(let version):
            hasUpdate = SUStandardVersionComparator.default.compareVersion(version, toVersion: currentBuild) == .orderedDescending
            if hasUpdate { defaults.set(version, forKey: Self.cachedVersionKey) }
            else { defaults.removeObject(forKey: Self.cachedVersionKey) }
        case .noUpdate, .skipped:
            hasUpdate = false
            defaults.removeObject(forKey: Self.cachedVersionKey)
        case .installing:
            isInstalling = true
        case .finished(let success):
            probing = false
            if !success { isInstalling = false }
            nextCheck = Date().addingTimeInterval(success ? 24 * 3600 : 3600)
            defaults.set(nextCheck, forKey: Self.nextCheckKey)
            if pendingPresentation {
                pendingPresentation = false
                // Sparkle releases its current driver after the delegate callback.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.started else { return }
                    self.engine?.present()
                }
            }
        }
    }
}

@MainActor
private final class SparkleUpdateEngine: NSObject, AppUpdateEngine, SPUUpdaterDelegate {
    var event: ((AppUpdateEvent) -> Void)?
    private let bundle: Bundle
    private var updater: SPUUpdater!
    private var userInitiated = false

    init(bundle: Bundle) {
        self.bundle = bundle
        super.init()
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
    }

    var sessionInProgress: Bool { updater.sessionInProgress }

    func start() throws {
        // Product invariants: never resume a previously enabled scheduler or auto-install preference.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        try updater.start()
    }

    func probe() { updater.checkForUpdateInformation() }

    func present() {
        // Repeated clicks can bring Sparkle's existing window back to the front.
        userInitiated = true
        updater.checkForUpdates()
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // No scheduled installation-capable checks, even if preferences were modified externally.
        guard updateCheck == .updateInformation || (updateCheck == .updates && userInitiated) else {
            throw NSError(domain: "LingChongDao.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "更新需要由用户主动打开。"])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { event?(.found(item.versionString)) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { event?(.noUpdate) }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { event?(.skipped) }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { event?(.installing) }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        userInitiated = false
        let nsError = error as NSError?
        let noUpdate = nsError?.domain == SUSparkleErrorDomain && nsError?.code == Int(SUError.noUpdateError.rawValue)
        event?(.finished(success: error == nil || noUpdate))
    }
}
