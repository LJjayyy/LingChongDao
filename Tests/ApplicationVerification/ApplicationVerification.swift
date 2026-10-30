import Foundation
import Darwin
import IslandCore

private struct CheckFailure: Error { let message: String }
@MainActor private var checkCount = 0
@MainActor
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
    checkCount += 1
    print("PASS \(message)")
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(message: message) }
    return value
}

@MainActor
private func waitUntil(_ predicate: () -> Bool, _ message: String) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CheckFailure(message: "Timed out: " + message)
}

@main
struct ApplicationVerification {
    @MainActor static func main() async {
        do {
            try await verify()
            print("\(checkCount) application checks passed. No real provider configuration changed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL application verification: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func verify() async throws {
        let suite = "local.lingchongdao.tests.\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "Cannot create isolated preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let review = try CodexReviewFixture()
        defer { review.cleanup() }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        defer { model.stopBridge() }
        try await verifySourceRouting()
        try await verifyConversationNavigation()
        try await verifyBuddyApplications()
        try await verifyWorkbenchMessages()
        if CommandLine.arguments.contains("--routing-only") { return }
        func event(_ name: String, session: String = "real", turn: String = "current", timestamp: Date = Date(), request: String? = nil, expires: Date? = nil, reviewer: String? = "user") throws -> BridgeEnvelope {
            var raw: [String: JSONValue] = ["hook_event_name": .string(name), "session_id": .string(session), "turn_id": .string(turn), "timestamp": .number(timestamp.timeIntervalSince1970), "title": .string("真实验证任务")]
            if let request {
                raw["tool_use_id"] = .string(request); raw["tool_name"] = .string("Bash")
                raw["tool_input"] = .object(["command": .string("pwd")])
                if name == "PermissionRequest", let reviewer {
                    raw.merge(try review.metadata(sessionID: session, turnID: turn, reviewer: reviewer)) { _, value in value }
                }
            }
            if let expires { raw["expires_at"] = .number(expires.timeIntervalSince1970) }
            return BridgeEnvelope(provider: .codex, raw: .object(raw), deadline: Date().addingTimeInterval(40))
        }
        _ = await model.handle(try event("SessionStart"))
        for (session, reviewer) in [("unverified", nil as String?), ("automatic", "auto_review")] {
            let reply = await model.handle(try event("PermissionRequest", session: session, request: "request", reviewer: reviewer))
            try check(reply.disposition == .fallback && !model.sessions.contains { $0.sessionID == session },
                      "Non-user review stays with Codex without an approval card: " + session)
        }
        model.loadPreview("question")
        try check(model.sessions.contains { $0.sessionID == "real" }, "Preview preserves an existing real task")
        model.endPreview()
        try check(model.sessions.count == 1 && model.sessions.first?.sessionID == "real", "Ending preview removes only preview tasks")
        model.loadPreview("question")
        let approvalTime = Date()
        let pendingEvent = try event("PermissionRequest", timestamp: approvalTime, request: "live")
        let pending = Task { await model.handle(pendingEvent) }
        try await waitUntil({ model.sessions.contains { $0.sessionID == "real" && $0.approval?.id == "live" } }, "Live user approval arrived")
        try check(model.visibleSessions.first?.approval?.id == "live", "Real approval takes priority over a preview question")
        model.endPreview()
        try check(model.sessions.first?.approval?.id == "live", "Approval received during preview survives ending preview")
        _ = await model.handle(try event("Stop", turn: "old", timestamp: approvalTime.addingTimeInterval(-1)))
        try check(model.sessions.first?.approval?.isExpired() == false, "Old timestamp cannot invalidate a live approval")
        _ = await model.handle(try event("Stop", turn: "old", timestamp: Date()))
        try check(model.sessions.first?.approval?.isExpired() == false, "Old turn cannot invalidate a live approval")
        _ = await model.handle(try event("PreToolUse", timestamp: Date(), request: "live"))
        try check(model.sessions.first?.approval?.id == "live", "PreToolUse retains the actual pending approval")
        model.respond(to: try unwrap(model.sessions.first { $0.sessionID == "real" }, "Expected the live approval session"), decision: .allow)
        let allowed = await pending.value
        try check(allowed.disposition == .allow, "Matching valid approval returns allow to its waiting transport")
        let expired = await model.handle(try event("PermissionRequest", request: "expired", expires: Date().addingTimeInterval(-10)))
        try check(expired.disposition == .fallback && model.sessions.first?.approval?.isExpired() == true, "Source-expired request never becomes actionable")
        let sourceExpiry = Date().addingTimeInterval(5)
        let shortEvent = try event("PermissionRequest", request: "short", expires: sourceExpiry)
        let short = Task { await model.handle(shortEvent) }
        try await waitUntil({ model.sessions.first { $0.sessionID == "real" }?.approval?.id == "short" }, "Short approval arrived")
        // Hook deadlines are epoch seconds on the wire; Date's reference-epoch
        // conversion can round the in-memory source by one floating-point ULP.
        let wireSourceExpiry = Date(timeIntervalSince1970: sourceExpiry.timeIntervalSince1970)
        try check((model.sessions.first?.approval?.expiresAt ?? .distantFuture) <= wireSourceExpiry, "Source deadline is not extended by transport deadline")
        let duplicate = await model.handle(try event("PermissionRequest", timestamp: Date().addingTimeInterval(-1), request: "old"))
        try check(duplicate.disposition == .fallback && model.sessions.first?.approval?.id == "short", "Delayed replacement leaves the current request attached")
        model.respond(to: try unwrap(model.sessions.first { $0.sessionID == "real" }, "Expected the short approval session"), decision: .deny)
        let denied = await short.value
        try check(denied.disposition == .deny, "Denial reaches only its matching waiting transport")
        let replacementEvent = try event("PermissionRequest", request: "replaced")
        let replaced = Task { await model.handle(replacementEvent) }
        try await waitUntil({ model.sessions.first { $0.sessionID == "real" }?.approval?.id == "replaced" }, "Replacement approval arrived")
        _ = await model.handle(try event("PostToolUse", request: "replaced"))
        let fallback = await replaced.value
        try check(fallback.disposition == .fallback && model.sessions.first?.approval == nil, "Source tool completion cancels the pending hook safely")
    }
    @MainActor static func verifyWorkbenchMessages() async throws {
        let suite = "local.lingchongdao.workbench." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { _ in }; model.openWorkbench = {}
        var deliveries: [@MainActor (Bool) -> Void] = []
        model.openDestination = { _, _, completion in deliveries.append(completion) }
        func send(_ id: String, _ name: String, extra: [String: JSONValue] = [:]) async -> IslandSession {
            var raw: [String: JSONValue] = ["session_id": .string(id), "hook_event_name": .string(name),
                "event_id": .string(UUID().uuidString), "title": .string("Workbench inbox fixture")]
            raw.merge(extra) { _, value in value }
            _ = await model.handle(.init(provider: .qoder, raw: .object(raw), sourceApplication: .qoderDesktop))
            return model.sessions.first { $0.sessionID == id }!
        }
        func shown(_ session: IslandSession) -> Bool { model.workbenchSessions.contains { $0.id == session.id } }
        let viewed = await send("inbox-viewed", "Stop")
        try check(shown(viewed), "An unread finished reminder is visible in the workbench")
        model.navigate(to: viewed)
        try check(shown(viewed), "A finished reminder remains while navigation delivery is pending")
        deliveries.removeFirst()(true)
        try check(!shown(viewed) && model.sessions.contains { $0.id == viewed.id }, "Opening a finished reminder removes its row while retaining source metadata")
        let failed = await send("inbox-failed", "Stop")
        model.navigate(to: failed); deliveries.removeFirst()(false)
        try check(shown(failed) && model.actionError != nil, "Failed navigation keeps the reminder available for retry")
        let race = await send("inbox-race", "Stop")
        model.navigate(to: race); _ = await send("inbox-race", "Stop"); deliveries.removeFirst()(true)
        try check(shown(race), "A newer result arriving during navigation stays in the workbench")
        let running = await send("inbox-running", "SessionStart")
        model.navigate(to: running); deliveries.removeFirst()(true)
        try check(shown(running), "Opening running work never removes its progress row")
        let question = await send("inbox-question", "UserQuestion", extra: ["request_id": .string("question"), "question": .string("Choose a source option")])
        model.navigate(to: question); deliveries.removeFirst()(true)
        try check(shown(question) && model.sessions.first { $0.id == question.id }?.unread == false, "A valid pending question stays visible even after viewing")
        let approval = await send("inbox-approval", "PermissionRequest")
        model.navigate(to: approval); deliveries.removeFirst()(true)
        try check(shown(approval) && model.sessions.first { $0.id == approval.id }?.unread == false, "A valid pending approval stays visible even after viewing")
        // Qoder observations expire from their source event time, not the raw expires_at field.
        let expiredApproval = await send("inbox-expired-approval", "PermissionRequest", extra: ["timestamp": .number(Date().addingTimeInterval(-120).timeIntervalSince1970)])
        try check(!shown(expiredApproval) && model.sessions.contains { $0.id == expiredApproval.id }, "Expired approval history does not occupy a workbench row")
        let expiredQuestion = await send("inbox-expired-question", "UserQuestion", extra: ["expires_at": .number(Date().addingTimeInterval(-10).timeIntervalSince1970)])
        try check(!shown(expiredQuestion) && model.sessions.contains { $0.id == expiredQuestion.id }, "Expired question history does not occupy a workbench row")
        let synced = await send("inbox-synced", "Stop")
        model.acknowledgeFinishedReminders(model.captureFinishedReminders(for: "com.qodercn.app"))
        try check(!shown(synced), "Returning to the source application also removes acknowledged workbench rows")
        let cleared = await send("inbox-cleared", "Stop"); model.dismiss(cleared)
        try check(!shown(cleared), "Manually clearing a finished reminder removes its row")
        let restarted = await send("inbox-viewed", "SessionStart")
        try check(shown(restarted), "A new task in a previously viewed conversation reappears")
        let newResult = await send("inbox-cleared", "Stop")
        try check(shown(newResult), "A new result in a cleared conversation reappears")
        let ended = await send("inbox-ended", "SessionEnd")
        try check(!shown(ended), "Closed source sessions do not leave empty workbench history")
        print("15 workbench inbox checks passed. Source metadata was retained and application opens were intercepted.")
    }
    @MainActor static func verifyBuddyApplications() async throws {
        let suite = "local.lingchongdao.buddy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, defaults: defaults)
        var opened: [String] = []
        var workbenchCount = 0
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { opened.append($0.lastPathComponent) }
        model.openDestination = { _, application, completion in opened.append(application.lastPathComponent); completion(true) }
        model.openWorkbench = { workbenchCount += 1 }
        func envelope(_ event: String, origin: SourceApplicationID) -> BridgeEnvelope {
            BridgeEnvelope(provider: origin.provider, raw: .object([
                "session_id": .string("same-session"), "hook_event_name": .string(event),
                "event_id": .string(UUID().uuidString), "prompt": .string("核对接入任务"),
                "tool_name": .string("execute_command"), "tool_use_id": .string("request"),
                "tool_input": .object(["command": .string("pwd")])
            ]), sourceApplication: origin)
        }
        let origins: [SourceApplicationID] = [.codebuddyCNIDE, .workbuddyDesktop, .workbuddyAI]
        for origin in origins { _ = await model.handle(envelope("UserPromptSubmit", origin: origin)) }
        try check(model.sessions.count == 3, "Buddy applications with identical session IDs remain separate")
        try check(model.sessions.allSatisfy { $0.displayTitle == "核对接入任务" }, "Buddy prompt titles reach the workbench")
        for origin in origins {
            let session = model.sessions.first { $0.sourceApplication == origin }!
            model.navigate(to: session)
            try check(opened.last == origin.bundleIdentifier! + ".app", "Buddy navigation opens the exact originating application: " + origin.rawValue)
        }
        settings.showCodeBuddy = false
        try check(!model.visibleSessions.contains { $0.source == .codebuddy } && model.visibleSessions.filter { $0.source == .workbuddy }.count == 2, "Buddy source visibility switches are independent")
        settings.showCodeBuddy = true
        for origin in origins { _ = await model.handle(envelope("Stop", origin: origin)) }
        let snapshot = model.captureFinishedReminders(for: SourceApplicationID.workbuddyDesktop.bundleIdentifier!)
        model.acknowledgeFinishedReminders(snapshot)
        try check(model.sessions.first { $0.sourceApplication == .workbuddyDesktop }?.unread == false && model.sessions.filter { $0.sourceApplication != .workbuddyDesktop }.allSatisfy(\.unread), "Returning to WorkBuddy never consumes CodeBuddy or WorkBuddy AI reminders")
        for origin in [SourceApplicationID.codebuddyUnknown, .workbuddyUnknown] {
            _ = await model.handle(envelope("SessionStart", origin: origin))
            let session = model.sessions.first { $0.sourceApplication == origin }!
            let count = opened.count
            model.navigate(to: session)
            try check(opened.count == count && model.actionError != nil, "Unknown Buddy origin never guesses a desktop application: " + origin.rawValue)
        }
        try check(workbenchCount == 2, "Unknown Buddy origin provides actionable workbench feedback")
        for origin in origins {
            let reply = await model.handle(envelope("PermissionRequest", origin: origin))
            let session = model.sessions.first { $0.sourceApplication == origin }!
            try check(reply.disposition == .acknowledged && session.approval?.canApprove == false && session.approval?.canDeny == false, "Buddy permissions remain status-only without blocking source approval: " + origin.rawValue)
        }
        print("13 Buddy application checks passed. All application opens were intercepted.")
    }
    @MainActor static func verifyConversationNavigation() async throws {
        let suite = "local.lingchongdao.navigation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        var applications: [URL] = []
        var destinations: [(URL, URL)] = []
        var completions: [@MainActor (Bool) -> Void] = []
        var workbenchCount = 0
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { applications.append($0) }
        model.openWorkbench = { workbenchCount += 1 }
        model.openDestination = { destination, app, completion in
            destinations.append((destination, app)); completions.append(completion)
        }
        model.isProjectDirectory = { $0.path == "/Projects/real-project" }
        func send(_ id: String, source: ProviderID = .qoder, origin: SourceApplicationID? = .qoderDesktop,
                  host: String = "localhost", thread: String? = nil, cwd: String? = nil) async -> IslandSession {
            var raw: [String: JSONValue] = ["hook_event_name": .string("Stop"), "session_id": .string(id),
                "event_id": .string(UUID().uuidString), "host": .string(host), "title": .string("Navigation fixture")]
            if let thread { raw["thread_id"] = .string(thread) }
            if let cwd { raw["cwd"] = .string(cwd) }
            _ = await model.handle(.init(provider: source, raw: .object(raw), sourceApplication: origin))
            return model.sessions.first { $0.sessionID == id && $0.source == source && $0.host == host }!
        }
        let desktop = await send("desktop-A")
        try check(model.navigationLabel(for: desktop) == "打开会话", "Qoder desktop advertises actual conversation navigation")
        model.navigate(to: desktop)
        try check(destinations.last?.0.absoluteString == "qoder-cn://chat/open?sessionId=desktop-A", "A Qoder notification targets its exact session ID")
        try check(destinations.last?.1.lastPathComponent == "com.qodercn.app.app" && applications.isEmpty,
                  "The shared Qoder scheme is explicitly delivered to desktop instead of the IDE")
        try check(model.sessions.first { $0.id == desktop.id }?.unread == true, "A result stays unread until URL delivery completes")
        completions.removeFirst()(true)
        try check(model.sessions.first { $0.id == desktop.id }?.unread == false, "Successful conversation URL delivery acknowledges the selected result")
        let codex = await send("12345678-1234-1234-1234-123456789012", source: .codex, origin: .codexDesktop,
                               thread: "abcdef01-1234-1234-1234-1234567890ab")
        model.navigate(to: codex)
        try check(destinations.last?.0.absoluteString == "codex://threads/abcdef01-1234-1234-1234-1234567890ab" && destinations.last?.1.lastPathComponent == "com.openai.codex.app",
                  "Codex navigation targets the thread in its verified desktop host")
        completions.removeFirst()(false)
        try check(applications.last?.lastPathComponent == "com.openai.codex.app" && model.actionError != nil,
                  "Failed conversation delivery falls back to its own app with visible feedback")
        try check(model.sessions.first { $0.id == codex.id }?.unread == true, "Failed delivery cannot consume the unread result")
        let race = await send("desktop-race")
        model.navigate(to: race)
        _ = await send("desktop-race")
        completions.removeFirst()(true)
        try check(model.sessions.first { $0.id == race.id }?.unread == true, "A new result received during navigation stays unread")
        model.navigate(to: race)
        let oldFailure = completions.removeFirst()
        model.navigate(to: desktop)
        let openCount = applications.count
        oldFailure(false)
        try check(applications.count == openCount && model.actionError == nil, "An older navigation callback cannot interrupt the current destination")
        completions.removeFirst()(true)
        let ide = await send("ide-A", origin: .qoderIDE, cwd: "/Projects/real-project")
        try check(model.navigationLabel(for: ide) == "打开项目", "IDE fallback is accurately labelled as project navigation")
        model.navigate(to: ide)
        try check(destinations.last?.0.isFileURL == true && destinations.last?.0.path == "/Projects/real-project" && destinations.last?.1.lastPathComponent == "com.aliyun.lingma.ide.app",
                  "An IDE result opens its existing project directory in the correct IDE")
        completions.removeFirst()(true)
        try check(model.sessions.first { $0.id == ide.id }?.unread == true, "Project-only navigation does not claim the specific conversation was read")
        let missingProject = await send("ide-missing", origin: .qoderIDE, cwd: "/Projects/missing")
        let beforeMissing = destinations.count
        model.navigate(to: missingProject)
        try check(model.navigationLabel(for: missingProject) == "打开应用" && destinations.count == beforeMissing && applications.last?.lastPathComponent == "com.aliyun.lingma.ide.app",
                  "Missing IDE projects fall back to the IDE without opening fabricated paths")
        let remote = await send("remote-task", host: "remote-server")
        model.navigate(to: remote)
        try check(model.navigationLabel(for: remote) == "打开应用" && destinations.count == beforeMissing,
                  "An unknown remote host never routes to a same-named local conversation")
        let knownChat = await send("87654321-1234-1234-1234-123456789012", source: .codex, origin: .codexChatGPT)
        model.navigate(to: knownChat)
        try check(applications.last?.lastPathComponent == "com.openai.chat.app" && destinations.count == beforeMissing,
                  "A ChatGPT-hosted message is not given an unsupported Codex deep link")
        model.loadPreview("completed")
        let preview = model.sessions.first { $0.sessionID == "preview-main" }!
        model.navigate(to: preview)
        try check(destinations.count == beforeMissing && model.sessions.first { $0.id == preview.id }?.unread == false,
                  "Synthetic previews keep local feedback without opening fake conversations")
        model.endPreview()
        model.isProjectDirectory = { _ in true }
        for path in ["/Users/example/work/..", "/Users/example/.", "/Projects/work/../../"] {
            let home = await send("ide-dot-" + UUID().uuidString, origin: .qoderIDE, cwd: path)
            try check(model.navigationLabel(for: home) == "打开应用", "A normalized home/root path is never advertised as a project")
        }
        model.resolveApplicationURL = { _ in nil }
        model.navigate(to: desktop)
        try check(workbenchCount == 2 && model.actionError != nil && destinations.count == beforeMissing,
                  "A missing source app returns to contextual workbench feedback")
        print("21 conversation delivery checks passed. All application opens were intercepted.")
    }

    @MainActor static func verifySourceRouting() async throws {
        let suite = "local.lingchongdao.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), defaults: defaults)
        defer { model.stopBridge() }
        var opened: URL?
        var fallbackCount = 0
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        model.openApplication = { opened = $0 }
        model.openDestination = { _, application, completion in opened = application; completion(true) }
        model.openWorkbench = { fallbackCount += 1 }
        func envelope(_ origin: String?, name: String = "UserPromptSubmit", session: String = "same", approval: Bool = false) throws -> BridgeEnvelope {
            var raw: [String: Any] = ["hook_event_name": name, "session_id": session, "prompt": "Origin routing regression"]
            if approval { raw["tool_use_id"] = "same-request"; raw["tool_name"] = "Bash"; raw["tool_input"] = ["command": "pwd"] }
            var value: [String: Any] = ["version": 1, "requestID": UUID().uuidString, "provider": "qoder", "operation": "event", "raw": raw]
            if let origin { value["sourceApplication"] = origin }
            // Decode the actual wire format, then exercise handle -> reducer -> navigate.
            return try JSONDecoder().decode(BridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: value))
        }
        _ = await model.handle(try envelope("qoder-cn-ide"))
        let ide = model.sessions.first!
        model.navigate(to: ide)
        try check(opened?.lastPathComponent == "com.aliyun.lingma.ide.app", "A Qoder CN IDE message opens the IDE instead of desktop (actual: \(opened?.lastPathComponent ?? "none"))")
        try check(ide.sourceDisplayName == "Qoder CN IDE" && ide.petSourceApplication == .qoderIDE, "IDE keeps its distinct label and application icon source")
        _ = await model.handle(try envelope("qoder-cn-desktop"))
        let desktop = model.sessions.first { $0.sourceApplication == .qoderDesktop }!
        try check(model.sessions.count == 2 && desktop.id != ide.id, "Identical desktop and IDE session IDs remain separate")
        model.navigate(to: desktop)
        try check(opened?.lastPathComponent == "com.qodercn.app.app", "Desktop messages continue opening Qoder CN desktop")
        try check(desktop.sourceDisplayName == "Qoder CN" && desktop.petSourceApplication == .qoderDesktop, "Desktop retains its current-pet presentation")
        for origin in [String?("qoder-unknown"), nil] {
            _ = await model.handle(try envelope(origin, name: "Stop", session: origin == nil ? "legacy" : "unknown"))
            let session = model.sessions.first { $0.sessionID == (origin == nil ? "legacy" : "unknown") }!
            opened = nil
            model.navigate(to: session)
            try check(model.sessions.first(where: { $0.id == session.id })?.unread == true, "Failed origin navigation retains the unread result on the island")
            try check(opened == nil && model.actionError != nil && session.sourceDisplayName.contains("来源待识别"), "Unknown or legacy origin returns to workbench without opening desktop")
        }
        try check(fallbackCount == 2, "Unknown-origin navigation presents contextual workbench feedback")
        model.navigate(to: ide)
        try check(model.actionError == nil, "Valid navigation clears prior origin feedback")
        model.resolveApplicationURL = { $0 == "com.aliyun.lingma.ide" ? nil : URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        opened = nil
        model.navigate(to: ide)
        try check(opened == nil && model.actionError != nil, "Missing IDE never opens the desktop app as a substitute")
        model.resolveApplicationURL = { URL(fileURLWithPath: "/Applications/" + $0 + ".app") }
        let desktopEvent = try envelope("qoder-cn-desktop", name: "PermissionRequest", session: "approval", approval: true)
        let ideEvent = try envelope("qoder-cn-ide", name: "PermissionRequest", session: "approval", approval: true)
        let first = Task { await model.handle(desktopEvent) }
        let second = Task { await model.handle(ideEvent) }
        try await waitUntil({ model.sessions.filter { $0.approval != nil }.count == 2 }, "Both Qoder observations arrived")
        let approvals = model.sessions.filter { $0.approval != nil }
        try check(approvals.count == 2 && Set(approvals.map(\.id)).count == 2,
                  "Matching permission and session IDs remain isolated between Qoder desktop and IDE")
        try check(approvals.allSatisfy { $0.hasPendingApproval && $0.approval?.canApprove == false && $0.approval?.canDeny == false },
                  "Both Qoder hosts display source-owned waiting state without island decision controls")
        let desktopReply = await first.value
        let ideReply = await second.value
        try check(desktopReply.disposition == .acknowledged && ideReply.disposition == .acknowledged,
                  "Qoder permission observations return without waiting for an island decision")
        let ideApproval = try unwrap(approvals.first { $0.sourceApplication == .qoderIDE }, "Expected an IDE permission observation")
        model.respond(to: ideApproval, decision: .deny)
        try check(model.actionError != nil && model.sessions.filter(\.hasPendingApproval).count == 2,
                  "A stale IDE denial cannot decide either source-owned Qoder request")
        let desktopApproval = try unwrap(approvals.first { $0.sourceApplication == .qoderDesktop }, "Expected a desktop permission observation")
        model.respond(to: desktopApproval, decision: .allow)
        try check(model.actionError != nil && model.sessions.filter(\.hasPendingApproval).count == 2,
                  "A stale desktop approval cannot decide either source-owned Qoder request")
        _ = await model.handle(try envelope("qoder-cn-ide", name: "PostToolUse", session: "approval", approval: true))
        try check(model.sessions.first { $0.id == ideApproval.id }?.hasPendingApproval == false &&
                  model.sessions.first { $0.id == desktopApproval.id }?.hasPendingApproval == true,
                  "IDE source progress clears only its own observation while desktop remains pending")
        _ = await model.handle(try envelope("qoder-cn-desktop", name: "PostToolUse", session: "approval", approval: true))
        try check(model.sessions.first { $0.id == desktopApproval.id }?.hasPendingApproval == false,
                  "Desktop source progress clears its own permission observation")
        let zcodeWire: [String: Any] = ["version": 1, "requestID": UUID().uuidString, "provider": "zcode", "operation": "event",
                                        "raw": ["hook_event_name": "UserPromptSubmit", "session_id": "zcode-session", "prompt": "ZCode routing regression"],
                                        "sourceApplication": "zcode-desktop"]
        _ = await model.handle(try JSONDecoder().decode(BridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: zcodeWire)))
        let zcode = model.sessions.first { $0.source == .zcode }!
        try check(zcode.sourceDisplayName == "ZCode" && zcode.petSourceApplication == nil, "ZCode keeps its own label and application icon source")
        opened = nil
        model.navigate(to: zcode)
        try check(opened?.lastPathComponent == "dev.zcode.app.app", "ZCode opens its own desktop app without inventing a session link")
        model.settings.showZCode = false
        try check(!model.visibleSessions.contains { $0.source == .zcode }, "Disabling ZCode removes its tasks from the island")
        model.settings.showZCode = true
        let dshWire: [String: Any] = ["version": 1, "requestID": UUID().uuidString, "provider": "dsh", "operation": "event",
                                      "raw": ["hook_event_name": "UserPromptSubmit", "session_id": "dsh-session", "prompt": "DeepSeek Harness routing regression"],
                                      "sourceApplication": "dsh-desktop"]
        _ = await model.handle(try JSONDecoder().decode(BridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: dshWire)))
        let dsh = model.sessions.first { $0.source == .dsh }!
        try check(dsh.sourceDisplayName == "DeepSeek Harness" && dsh.petSourceApplication == nil, "DeepSeek Harness keeps its own label and application icon source")
        opened = nil
        model.navigate(to: dsh)
        try check(opened?.lastPathComponent == "com.deepseek.dsh.app", "DeepSeek Harness opens its own desktop app without inventing a session link")
        model.settings.showDSH = false
        try check(!model.visibleSessions.contains { $0.source == .dsh }, "Disabling DeepSeek Harness removes its tasks from the island")
        model.settings.showDSH = true
        print("Source routing verification passed. Application launches were intercepted; no source settings changed.")
    }

}
