import AppKit
import Foundation
import IslandCore

private struct Failure: Error { let message: String }
private var checkCount = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(message: message) }
    checkCount += 1
    print("PASS \(message)")
}

@main
struct SourceAttentionVerification {
    @MainActor static func main() async throws {
        let suite = "local.lingchongdao.attention-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, defaults: defaults)
        let desktop = "com.qodercn.app"
        let ide = "com.aliyun.lingma.ide"
        let codex = "com.openai.codex"
        let chat = "com.openai.chat"
        func send(_ name: String, _ id: String, source: ProviderID = .qoder,
                  origin: SourceApplicationID? = .qoderDesktop, host: String = "localhost",
                  time: Date = Date(), eventID: String = UUID().uuidString,
                  turn: String? = nil, expired: Bool = false) async {
            var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(id),
                "event_id": .string(eventID), "timestamp": .number(time.timeIntervalSince1970),
                "host": .string(host), "title": .string("Synthetic reminder"), "status": .string("completed")]
            if let turn { raw["turn_id"] = .string(turn) }
            if name == "PermissionRequest" || name == "UserQuestion" {
                // No stable tool ID: status-only fixture, never opens a real waiting transport.
                raw["expires_at"] = .number(Date().addingTimeInterval(expired ? -60 : 600).timeIntervalSince1970)
            }
            _ = await model.handle(BridgeEnvelope(provider: source, raw: .object(raw), sourceApplication: origin))
        }
        func session(_ id: String) -> IslandSession { model.sessions.first { $0.sessionID == id }! }
        func waitForAcknowledgement(_ ids: String...) async throws {
            // Confirmation tasks may start late on a shared runner. Wait for
            // the actual transition; the assertions below still fail if it never happens.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(2)
            while ids.contains(where: { session($0).unread }) && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try check(settings.autoClearFinishedOnAppFocus, "App-level reminder sync defaults to enabled")
        await send("Stop", "desktop-stop")
        await send("TurnCompleted", "desktop-completed")
        await send("TurnFailed", "desktop-failed")
        await send("Interrupt", "desktop-interrupted")
        await send("Stop", "ide", origin: .qoderIDE)
        await send("Stop", "codex", source: .codex, origin: .codexDesktop)
        await send("Stop", "chat", source: .codex, origin: .codexChatGPT)
        await send("Stop", "cli", source: .codex, origin: nil)
        await send("Stop", "remote", host: "remote-host")
        await send("Stop", "unknown", origin: nil)
        await send("Stop", "generic", source: .generic, origin: nil)
        await send("SessionStart", "running")
        await send("UserQuestion", "question")
        await send("PermissionRequest", "approval")
        await send("PermissionRequest", "expired", expired: true)
        model.loadPreview("completed")
        let before = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: desktop))
        for id in ["desktop-stop", "desktop-completed", "desktop-failed", "desktop-interrupted"] {
            let value = session(id), previous = before[session(id).id]!
            try check(!value.unread && !model.visibleSessions.contains(where: { $0.id == value.id }), "\(id) leaves the island after entering its source app")
            try check(value.phase == previous.phase && value.detail == previous.detail && value.updatedAt == previous.updatedAt,
                      "\(id) keeps its result and history unchanged")
        }
        for id in ["ide", "codex", "chat", "cli", "remote", "unknown", "generic", "running", "question", "approval", "expired", "preview-main"] {
            try check(session(id) == before[session(id).id], "Source activation preserves \(id)")
        }
        model.endPreview()
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: ide))
        try check(!session("ide").unread && session("codex").unread, "IDE acknowledgement is scoped independently")
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: codex))
        try check(!session("codex").unread && session("chat").unread && session("cli").unread,
                  "Codex desktop does not consume ChatGPT-hosted or CLI reminders")
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: chat))
        try check(!session("chat").unread && session("cli").unread, "ChatGPT-hosted Codex stays distinct from CLI")

        // A delayed focus acknowledgement cannot consume a later event, even at
        // the same timestamp, or clear a replacement interaction/new turn.
        let sameTime = Date()
        await send("Stop", "race", time: sameTime, eventID: "race-old")
        let old = model.captureFinishedReminders(for: desktop)
        await send("Stop", "late-created")
        await send("Stop", "race", time: sameTime, eventID: "race-new")
        model.acknowledgeFinishedReminders(old)
        try check(session("race").unread && session("late-created").unread, "Stale focus snapshots preserve new events and newly completed tasks")
        let replacement = model.captureFinishedReminders(for: desktop)
        await send("UserQuestion", "race")
        model.acknowledgeFinishedReminders(replacement)
        try check(session("race").question != nil && session("race").unread, "A new question cannot be cleared by an earlier app visit")
        await send("Stop", "new-turn", turn: "old")
        let oldTurn = model.captureFinishedReminders(for: desktop)
        await send("UserPromptSubmit", "new-turn", turn: "new")
        model.acknowledgeFinishedReminders(oldTurn)
        try check(session("new-turn").phase == .running, "A new running turn survives a stale acknowledgement")
        await send("Stop", "migration", source: .codex, origin: .codexChatGPT)
        await send("Stop", "migration", source: .codex, origin: nil)
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: chat))
        try check(session("migration").sourceApplication == nil && session("migration").unread,
                  "A desktop session resumed without ownership does not inherit a stale app")
        await send("Stop", "legacy-metadata", source: .codex, origin: nil)
        await send("Stop", "legacy-metadata", source: .codex, origin: .codexChatGPT)
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: chat))
        try check(!session("legacy-metadata").unread, "A newly verified app enriches an existing Codex session")

        settings.autoClearFinishedOnAppFocus = false
        try check(AppSettings(defaults: defaults).autoClearFinishedOnAppFocus == false, "The sync preference persists")
        await send("Stop", "opt-out")
        try check(model.captureFinishedReminders(for: desktop).isEmpty, "Disabled sync does not capture reminders")
        settings.autoClearFinishedOnAppFocus = true
        let disabling = model.captureFinishedReminders(for: desktop)
        settings.autoClearFinishedOnAppFocus = false
        model.acknowledgeFinishedReminders(disabling)
        try check(session("opt-out").unread, "Disabling sync cancels a prepared acknowledgement")
        settings.autoClearFinishedOnAppFocus = true

        let center = NotificationCenter()
        var frontmost: String? = desktop
        let monitor = SourceAttentionMonitor(model: model, notificationCenter: center,
            confirmationDelay: 30_000_000, frontmostBundleIdentifier: { frontmost })
        monitor.start()
        monitor.start()
        monitor.applicationActivated(bundleIdentifier: desktop)
        frontmost = ide
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("opt-out").unread, "A short app switch does not clear reminders")
        frontmost = desktop
        monitor.applicationActivated(bundleIdentifier: desktop)
        monitor.applicationDeactivated(bundleIdentifier: desktop)
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("opt-out").unread, "Deactivation cancels a pending acknowledgement")
        monitor.applicationActivated(bundleIdentifier: desktop)
        monitor.applicationDeactivated(bundleIdentifier: ide)
        try await waitForAcknowledgement("opt-out")
        try check(!session("opt-out").unread, "A late deactivation from the previous app does not cancel the new app visit")
        await send("Stop", "opt-out")
        monitor.applicationActivated(bundleIdentifier: desktop)
        await send("Stop", "arrived-during-visit")
        try await waitForAcknowledgement("opt-out", "arrived-during-visit")
        try check(!session("opt-out").unread && !session("arrived-during-visit").unread,
                  "A sustained visit also clears completions that arrive during the visit")
        frontmost = ide
        await send("Stop", "away-arrival")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("away-arrival").unread, "An arrival while another app is frontmost is retained")
        frontmost = desktop
        await send("Stop", "lock-cancel")
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("lock-cancel").unread, "Locking the session cancels the visit")
        await send("Stop", "sleep-cancel")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("sleep-cancel").unread, "Sleep cancels the visit")
        monitor.stop()
        await send("Stop", "stopped-monitor")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("stopped-monitor").unread, "A stopped monitor cannot acknowledge")
        frontmost = ide
        monitor.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        frontmost = desktop
        monitor.applicationActivated(bundleIdentifier: desktop)
        settings.autoClearFinishedOnAppFocus = false
        settings.autoClearFinishedOnAppFocus = true
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(session("lock-cancel").unread, "Turning sync off cancels the old visit even after it is re-enabled")
        monitor.applicationActivated(bundleIdentifier: desktop)
        try await waitForAcknowledgement("lock-cancel")
        try check(!session("lock-cancel").unread, "A restarted monitor confirms a new foreground visit")
        monitor.stop()
        var opened: URL?
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { opened = $0 }
        model.navigate(to: session("chat"))
        try check(opened?.lastPathComponent == "com.openai.chat.app", "A verified ChatGPT-hosted session opens its exact application")
        model.navigate(to: session("codex"))
        try check(opened?.lastPathComponent == "com.openai.codex.app", "A verified Codex desktop session opens its exact application")
        print("\(checkCount) source attention checks passed. Only synthetic sessions and isolated preferences were used.")
    }
}
