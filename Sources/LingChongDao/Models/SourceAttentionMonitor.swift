import AppKit
import Combine
import Foundation

/// A short foreground visit acknowledges reminders that existed on entry and
/// those that arrive while the visit continues. No Accessibility access,
/// chat-history reads, or source-side writes are needed.
@MainActor
final class SourceAttentionMonitor {
    private let model: AppModel
    private let notificationCenter: NotificationCenter
    private let frontmostBundleIdentifier: () -> String?
    private let confirmationDelay: UInt64
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var sessionsObservation: AnyCancellable?
    private var generation = UUID()
    private var pendingBundleIdentifier: String?
    private var pendingRevisions: [String: UInt64]?
    private var isRunning = false

    init(model: AppModel, notificationCenter: NotificationCenter? = nil,
         confirmationDelay: UInt64 = 1_000_000_000,
         frontmostBundleIdentifier: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.model = model
        self.notificationCenter = notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.confirmationDelay = confirmationDelay
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        settingsObservation = model.settings.$autoClearFinishedOnAppFocus.sink { [weak self] enabled in
            if !enabled { self?.cancelPending() }
        }
        // A reminder that arrives while its source app is already frontmost has
        // no activation event of its own; it needs the same dwell confirmation.
        sessionsObservation = model.$sessions.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishedRemindersChanged() }
        }
        observers.append(notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in self?.applicationActivated(bundleIdentifier: bundleIdentifier) }
        })
        observers.append(notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in self?.applicationDeactivated(bundleIdentifier: bundleIdentifier) }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelPending() }
            })
        }
    }

    func stop() {
        isRunning = false
        settingsObservation?.cancel(); settingsObservation = nil
        sessionsObservation?.cancel(); sessionsObservation = nil
        cancelPending()
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func applicationActivated(bundleIdentifier: String?) {
        cancelPending()
        guard isRunning, let bundleIdentifier else { return }
        let snapshot = model.captureFinishedReminders(for: bundleIdentifier)
        guard !snapshot.isEmpty else { return }
        scheduleAcknowledgement(snapshot, bundleIdentifier: bundleIdentifier)
    }

    /// Called whenever published sessions change, including when a finished
    /// reminder lands while the user never left the source application.
    func finishedRemindersChanged() {
        guard isRunning, model.settings.autoClearFinishedOnAppFocus else { return }
        guard let bundleIdentifier = frontmostBundleIdentifier() else { return }
        if let pendingBundle = pendingBundleIdentifier, pendingBundle != bundleIdentifier { return }
        let snapshot = model.captureFinishedReminders(for: bundleIdentifier)
        guard !snapshot.isEmpty, snapshot.revisions != pendingRevisions else { return }
        scheduleAcknowledgement(snapshot, bundleIdentifier: bundleIdentifier)
    }

    func applicationDeactivated(bundleIdentifier: String?) {
        // A delayed deactivation from the previous app must not cancel the new
        // app's foreground visit. Workspace notifications can arrive in either order.
        guard let bundleIdentifier, bundleIdentifier == pendingBundleIdentifier else { return }
        cancelPending()
    }

    private func scheduleAcknowledgement(_ snapshot: AppModel.SourceAttentionSnapshot, bundleIdentifier: String) {
        pending?.cancel()
        pendingBundleIdentifier = bundleIdentifier
        pendingRevisions = snapshot.revisions
        let expectedGeneration = generation
        pending = Task { [weak self, confirmationDelay] in
            do { try await Task.sleep(nanoseconds: confirmationDelay) }
            catch { return }
            guard !Task.isCancelled, let self, self.isRunning,
                  self.generation == expectedGeneration,
                  self.frontmostBundleIdentifier() == bundleIdentifier else { return }
            self.model.acknowledgeFinishedReminders(snapshot)
            self.pending = nil
            self.pendingBundleIdentifier = nil
            self.pendingRevisions = nil
        }
    }

    private func cancelPending() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        pendingBundleIdentifier = nil
        pendingRevisions = nil
    }

    deinit {
        pending?.cancel()
        observers.forEach { notificationCenter.removeObserver($0) }
    }
}
