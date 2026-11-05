import AppKit
import Foundation
import IslandCore
import SQLite3

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
        await send("Stop", "dsh-A", source: .dsh, origin: .dshDesktop)
        await send("Stop", "dsh-B", source: .dsh, origin: .dshDesktop)
        let dshVisit = model.captureFinishedReminders(for: "com.deepseek.dsh")
        model.acknowledgeFinishedReminders(dshVisit)
        try check(dshVisit.isEmpty && session("dsh-A").unread && session("dsh-B").unread,
                  "DSH application focus preserves every reminder until an exact conversation is confirmed")
        let viewedSince = Date()
        try await Task.sleep(for: .milliseconds(1050))
        _ = await model.handle(BridgeEnvelope(provider: .dsh, raw: .object([
            "hook_event_name": .string("SessionViewed"), "session_id": .string("dsh-A"),
            "viewed_since": .number(viewedSince.timeIntervalSince1970),
            "timestamp": .number(Date().timeIntervalSince1970),
        ]), sourceApplication: .dshDesktop))
        try check(!session("dsh-A").unread && session("dsh-B").unread,
                  "Directly viewing DSH A removes its island reminder and preserves unopened DSH B")
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

        let workBuddyA = UUID().uuidString
        let workBuddyB = UUID().uuidString
        await send("Stop", workBuddyA, source: .workbuddy, origin: .workbuddyDesktop)
        await send("Stop", workBuddyB, source: .workbuddy, origin: .workbuddyDesktop)
        frontmost = SourceApplicationID.workbuddyDesktop.bundleIdentifier
        monitor.applicationActivated(bundleIdentifier: frontmost)
        try await Task.sleep(for: .milliseconds(80))
        try check(session(workBuddyA).unread && session(workBuddyB).unread,
                  "Activating WorkBuddy preserves both unopened conversation reminders")
        await send("Stop", "workbuddy-during-visit", source: .workbuddy, origin: .workbuddyDesktop)
        try await Task.sleep(for: .milliseconds(80))
        try check(session("workbuddy-during-visit").unread, "WorkBuddy focus does not consume a newly finished reminder")
        monitor.stop()
        var opened: URL?
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { opened = $0 }
        model.openDestination = { destination, _, completion in opened = destination; completion(true) }
        model.navigate(to: session(workBuddyA))
        try check(opened?.absoluteString == "workbuddy://chat/" + workBuddyA &&
                  !session(workBuddyA).unread && session(workBuddyB).unread && session("workbuddy-during-visit").unread,
                  "Delivering an island link to WorkBuddy A only consumes A's reminder")
        model.navigate(to: session("chat"))
        try check(opened?.lastPathComponent == "com.openai.chat.app", "A verified ChatGPT-hosted session opens its exact application")
        model.navigate(to: session("codex"))
        try check(opened?.lastPathComponent == "com.openai.codex.app", "A verified Codex desktop session opens its exact application")
        try await verifyWorkBuddyReadState()
        try await verifyDshViewBoundaries()
        print("\(checkCount) source attention checks passed. Only synthetic sessions and isolated preferences were used.")
    }

    @MainActor static func verifyWorkBuddyReadState() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("island-workbuddy-read-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workbuddy.db")
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else { throw Failure(message: "Open fixture database") }
        defer { sqlite3_close(connection) }
        func write(_ sql: String) throws {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "Write fixture database") }
        }
        let a = "00000000-0000-4000-8000-000000000001"
        let b = "00000000-0000-4000-8000-000000000002"
        try write("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE sessions(id TEXT PRIMARY KEY, transport TEXT NOT NULL, deleted_at INTEGER,
            status TEXT NOT NULL, unread INTEGER NOT NULL DEFAULT 0, updated_at INTEGER, last_activity_at INTEGER, user_id TEXT NOT NULL);
        INSERT INTO sessions VALUES ('\(a)', 'local', NULL, 'completed', 0, 1700000002000, 1700000001900, 'fixture'),
                                    ('\(b)', 'local', NULL, 'completed', 1, 1700000002000, 1700000001900, 'fixture');
        """)
        let suite = "local.lingchongdao.workbuddy-read." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        let reader = WorkBuddyReadStateReader(databaseURL: url)
        var tracker = WorkBuddyReadTracker()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        model.sourceAttentionDate = { now }
        func send(_ event: String, id: String, turn: String, threadID: String? = nil) async {
            var raw: [String: JSONValue] = [
                "hook_event_name": .string(event), "session_id": .string(id), "generation_id": .string(turn),
                "timestamp": .number(now.timeIntervalSince1970), "session_title": .string("Same test title")
            ]
            if event == "SessionStart" { raw["source"] = .string("resume") }
            if let threadID { raw["thread_id"] = .string(threadID) }
            _ = await model.handle(BridgeEnvelope(provider: .workbuddy, raw: .object(raw), sourceApplication: .workbuddyDesktop))
        }
        func readChanges() throws -> [WorkBuddyReminder] {
            let candidates = model.workBuddyFinishedReminders()
            let snapshot = try reader.read(sessionIDs: Set(candidates.map(\.sessionID)))
            return tracker.ingest(snapshot, reminders: candidates)
        }
        func inbox() -> Set<String> { Set(model.visibleSessions.map(\.sessionID)) }
        await send("UserPromptSubmit", id: a, turn: "first-a")
        await send("UserPromptSubmit", id: b, turn: "first-b")
        now = now.addingTimeInterval(1)
        await send("Stop", id: a, turn: "first-a")
        await send("Stop", id: b, turn: "first-b")
        let initial = try readChanges()
        try check(initial.isEmpty && inbox() == [a, b], "An initially read WorkBuddy row does not clear an island reminder")
        try write("UPDATE sessions SET unread=1 WHERE id='\(a)'")
        _ = try readChanges()
        await send("SessionEnd", id: a, turn: "first-a")
        await send("SessionStart", id: a, turn: "first-a")
        try write("UPDATE sessions SET unread=0 WHERE id='\(a)'")
        let oldA = try readChanges()
        model.acknowledgeWorkBuddyReminders(oldA)
        try check(oldA.count == 1 && inbox() == [b], "Viewing WorkBuddy A clears only A across same-turn end and resume hooks")
        now = now.addingTimeInterval(5)
        await send("UserPromptSubmit", id: a, turn: "second-a")
        now = now.addingTimeInterval(1)
        await send("Stop", id: a, turn: "second-a")
        try check(model.acknowledgeWorkBuddyReminders(oldA).isEmpty && inbox() == [a, b], "An earlier WorkBuddy confirmation cannot clear the next result")
        try write("UPDATE sessions SET unread=1 WHERE id='\(a)'")
        _ = try readChanges()
        try write("UPDATE sessions SET unread=0 WHERE id='\(a)'")
        let staleRow = try readChanges()
        try check(staleRow.isEmpty && inbox() == [a, b], "An earlier SQLite row cannot be used as the new WorkBuddy turn's baseline")
        try write("UPDATE sessions SET unread=1, updated_at=1700000008000, last_activity_at=1700000007900 WHERE id='\(a)'")
        _ = try readChanges()
        try write("UPDATE sessions SET unread=0, status='archived', updated_at=1700000008001 WHERE id='\(b)'")
        let archived = try readChanges()
        try check(archived.isEmpty && inbox() == [a, b], "Archiving an unread WorkBuddy conversation does not count as viewing")
        try write("UPDATE sessions SET unread=0 WHERE id='\(a)'")
        let nextA = try readChanges()
        model.acknowledgeWorkBuddyReminders(nextA)
        try check(nextA.count == 1 && inbox() == [b], "Viewing the new WorkBuddy result can independently clear it")

        // Exercise the app's real scheduling path with an unrelated frontmost
        // application. The WorkBuddy row, not workspace activation, is the signal.
        now = now.addingTimeInterval(5)
        await send("UserPromptSubmit", id: a, turn: "third-a")
        now = now.addingTimeInterval(1)
        await send("Stop", id: a, turn: "third-a")
        try write("UPDATE sessions SET unread=1, updated_at=1700000014000, last_activity_at=1700000013900 WHERE id='\(a)'")
        let workBuddy = WorkBuddyReadMonitor(model: model, reader: reader,
            instance: { .init(processIdentifier: 1, launchDate: Date(timeIntervalSince1970: 1_699_999_000)) })
        let monitor = SourceAttentionMonitor(model: model, notificationCenter: NotificationCenter(),
            frontmostBundleIdentifier: { "com.openai.codex" }, workBuddyReadMonitor: workBuddy)
        monitor.start()
        defer { monitor.stop() }
        let deadline = ContinuousClock.now + .seconds(3)
        while inbox().contains(a), ContinuousClock.now < deadline {
            try write("UPDATE sessions SET unread=1 WHERE id='\(a)'")
            monitor.finishedRemindersChanged()
            try await Task.sleep(for: .milliseconds(300))
            try write("UPDATE sessions SET unread=0 WHERE id='\(a)'")
            monitor.finishedRemindersChanged()
            try await Task.sleep(for: .milliseconds(300))
        }
        try check(inbox() == [b], "The source attention monitor observes WorkBuddy read state independently of app focus")

        monitor.stop()
        now = now.addingTimeInterval(5)
        await send("UserPromptSubmit", id: a, turn: "fourth-a")
        now = now.addingTimeInterval(1)
        await send("Stop", id: a, turn: "fourth-a")
        await send("UserPromptSubmit", id: a, turn: "other-thread", threadID: "fork")
        try write("UPDATE sessions SET unread=1, updated_at=1700000020000 WHERE id='\(a)'")
        _ = try readChanges()
        try write("UPDATE sessions SET unread=0 WHERE id='\(a)'")
        model.acknowledgeWorkBuddyReminders(try readChanges())
        try check(model.visibleSessions.contains { $0.sessionID == a && $0.threadID == nil && $0.unread },
                  "A shared WorkBuddy database ID cannot acknowledge one of multiple tracked threads")
    }

    @MainActor static func verifyDshViewBoundaries() async throws {
        let suite = "local.lingchongdao.dsh-attention-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, defaults: defaults)
        // Use exact Unix seconds so serializing the fixture cannot move it past the injected clock.
        var now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        model.sourceAttentionDate = { now }
        var activityCount = 0
        model.onProviderEvent = { _, _ in activityCount += 1 }
        func session(_ id: String, host: String = "localhost") -> IslandSession {
            model.sessions.first { $0.sessionID == id && $0.host == host }!
        }
        @discardableResult func send(_ name: String, _ id: String, time: Date? = nil,
                                     host: String = "localhost", origin: SourceApplicationID? = .dshDesktop) async -> BridgeReply {
            await model.handle(BridgeEnvelope(provider: .dsh, raw: .object([
                "hook_event_name": .string(name), "session_id": .string(id), "host": .string(host),
                "event_id": .string(UUID().uuidString), "timestamp": .number((time ?? now).timeIntervalSince1970),
                "status": .string("completed"),
            ]), sourceApplication: origin))
        }
        @discardableResult func view(_ id: String, since: Date?, at: Date? = nil, host: String = "localhost",
                                     origin: SourceApplicationID? = .dshDesktop, source: ProviderID = .dsh) async -> BridgeReply {
            var raw: [String: JSONValue] = ["hook_event_name": .string("SessionViewed"), "session_id": .string(id),
                "host": .string(host), "timestamp": .number((at ?? now).timeIntervalSince1970)]
            if let since { raw["viewed_since"] = .number(since.timeIntervalSince1970) }
            return await model.handle(BridgeEnvelope(provider: source, raw: .object(raw), sourceApplication: origin))
        }

        for (name, id) in [("Stop", "stopped"), ("TurnCompleted", "completed"), ("TurnFailed", "failed"), ("Interrupt", "interrupted")] {
            await send(name, id)
        }
        await send("Stop", "unopened")
        await send("SessionStart", "running")
        await send("UserQuestion", "question")
        await send("PermissionRequest", "approval")
        await send("Stop", "remote", host: "other-device")
        await send("Stop", "unknown", origin: nil)
        let before = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
        let visit = now.addingTimeInterval(0.01)
        now = now.addingTimeInterval(2)
        let originalActivityCount = activityCount
        for id in ["stopped", "completed", "failed", "interrupted"] {
            await view(id, since: visit)
            let value = session(id)
            var expected = before[value.id]!
            expected.unread = false
            try check(value == expected && !model.visibleSessions.contains { $0.id == value.id },
                      "Direct DSH view removes \(id) without changing its result or history")
        }
        for id in ["running", "question", "approval", "unknown"] {
            await view(id, since: visit)
            try check(session(id) == before[session(id).id], "DSH view preserves \(id) and any live request")
        }
        await view("remote", since: visit, host: "other-device")
        try check(session("remote", host: "other-device") == before[session("remote", host: "other-device").id],
                  "A local DSH visit cannot clear a remote task")
        try check(session("unopened").unread && activityCount == originalActivityCount,
                  "DSH viewing neither consumes other sessions nor reports model activity")
        let count = model.sessions.count
        await view("missing", since: visit)
        try check(model.sessions.count == count, "Viewing an unknown DSH conversation creates no island task")

        await view("unopened", since: nil)
        await view("unopened", since: now.addingTimeInterval(-0.5))
        await view("unopened", since: now.addingTimeInterval(-120))
        await view("unopened", since: visit, at: now.addingTimeInterval(5))
        await view("unopened", since: visit, origin: nil)
        let wrongSource = await view("unopened", since: visit, origin: .codexDesktop, source: .codex)
        try check(session("unopened").unread && wrongSource.disposition == .fallback,
                  "Missing, brief, stale, future and unverified DSH views preserve reminders")
        settings.autoClearFinishedOnAppFocus = false
        await view("unopened", since: visit)
        try check(session("unopened").unread, "Disabling reminder sync also disables direct DSH viewing sync")
        settings.autoClearFinishedOnAppFocus = true

        // Identical/backdated source timestamps must not bypass the arrival fence.
        let sourceTime = now
        await send("Stop", "race", time: sourceTime)
        let oldVisit = now.addingTimeInterval(0.01)
        now = now.addingTimeInterval(0.5)
        await send("Stop", "race", time: sourceTime)
        now = now.addingTimeInterval(1)
        await view("race", since: oldVisit)
        try check(session("race").unread, "A delayed DSH view cannot clear a later result with the same source timestamp")
        let freshVisit = now.addingTimeInterval(0.01)
        now = now.addingTimeInterval(2)
        await view("race", since: freshVisit)
        try check(!session("race").unread, "Continued DSH viewing can acknowledge the newer result on its next visit confirmation")
        await send("Stop", "new-turn")
        let previousVisit = now.addingTimeInterval(0.01)
        now = now.addingTimeInterval(0.5)
        await send("UserPromptSubmit", "new-turn")
        now = now.addingTimeInterval(1)
        await view("new-turn", since: previousVisit)
        try check(session("new-turn").phase == .running, "A DSH view confirmation never interrupts a new turn")
    }
}
