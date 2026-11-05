import AppKit
import Foundation

/// Reads WorkBuddy's local attention metadata only for reminders we still show.
@MainActor
final class WorkBuddyReadMonitor {
    struct Instance: Equatable {
        let processIdentifier: pid_t
        let launchDate: Date
    }

    private static let bundleIdentifier = "com.tencent.workbuddy.mac"
    private let model: AppModel
    private let reader: WorkBuddyReadStateReader
    private let instance: () -> Instance?
    private var tracker = WorkBuddyReadTracker()
    private var observedInstance: Instance?
    private var pending: Task<Void, Never>?
    private var refreshAfterPending = false
    private var lastReminders: Set<WorkBuddyReminder>?
    private var lastSampleTime: ContinuousClock.Instant?

    init(model: AppModel,
         reader: WorkBuddyReadStateReader = .init(databaseURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db")),
         instance: (() -> Instance?)? = nil) {
        self.model = model
        self.reader = reader
        self.instance = instance ?? Self.desktopInstance
    }

    func refresh() {
        let reminders = Set(model.workBuddyFinishedReminders())
        guard !reminders.isEmpty, let current = instance() else { reset(); return }
        if current != observedInstance {
            reset()
            observedInstance = current
        }
        guard pending == nil else { refreshAfterPending = true; return }
        let now = ContinuousClock.now
        if reminders == lastReminders, let lastSampleTime, now - lastSampleTime < .milliseconds(250) { return }
        lastReminders = reminders
        lastSampleTime = now
        let ids = Set(reminders.map(\.sessionID))
        pending = Task { [weak self, reader] in
            let sample = await Task.detached(priority: .utility) { try reader.read(sessionIDs: ids) }.result
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            guard self.instance() == current else { self.reset(); return }
            switch sample {
            case .success(let snapshot):
                let eligible = Set(self.model.workBuddyFinishedReminders())
                let currentReminders = reminders.intersection(eligible)
                let viewed = self.tracker.ingest(snapshot, reminders: Array(currentReminders))
                self.model.acknowledgeWorkBuddyReminders(viewed)
            case .failure:
                self.tracker.reset()
            }
            if self.refreshAfterPending {
                self.refreshAfterPending = false
                self.refresh()
            }
        }
    }

    func reset() {
        pending?.cancel(); pending = nil
        refreshAfterPending = false
        observedInstance = nil
        lastReminders = nil; lastSampleTime = nil
        tracker.reset()
    }

    private static func desktopInstance() -> Instance? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        guard running.count == 1, let app = running.first,
              let launchDate = app.launchDate, let url = app.bundleURL,
              let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "5.9.3",
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "5.9.3" else { return nil }
        return Instance(processIdentifier: app.processIdentifier, launchDate: launchDate)
    }

    deinit { pending?.cancel() }
}
