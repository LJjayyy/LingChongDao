import Darwin
import Foundation
import IslandCore

private enum VerificationFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
private struct NavigationVerification {
    private static var checks = 0

    static func main() {
        do {
            try verifyCodexRoutes()
            try verifyQoderRoutes()
            try verifyZCodeRoutes()
            try verifyWorkBuddyRoutes()
            try verifyScopeAndAppSelection()
            print("PASS: \(checks) navigation checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verifyCodexRoutes() throws {
        let thread = "A1234567-B89C-4DEF-8123-456789ABCDEF"
        let session = IslandSession(source: .codex, sessionID: "not-a-uuid", threadID: thread, title: "task")
        let url = try requiredURL(session, bundle: "com.openai.codex")
        try expect(url.absoluteString == "codex://threads/a1234567-b89c-4def-8123-456789abcdef", "thread UUID should win and normalize to lowercase")

        let fallback = IslandSession(source: .codex, sessionID: "12345678-1234-ABCD-9876-1234567890AB", title: "task")
        let fallbackURL = try requiredURL(fallback, bundle: "com.openai.codex")
        try expect(fallbackURL.absoluteString == "codex://threads/12345678-1234-abcd-9876-1234567890ab", "valid session UUID should be used when thread ID is absent")

        for bad in ["", "12345678", "12345678-1234-1234-1234-12345678901/", "12345678-1234-1234-1234-12345678901?x=y", "12345678-1234-1234-1234-12345678901%2F", "12345678-1234-1234-1234-123456789012345678901234567890"] {
            let invalid = IslandSession(source: .codex, sessionID: bad, title: "task")
            try expect(SessionNavigation.conversationURL(for: invalid, applicationBundleIdentifier: "com.openai.codex") == nil, "malformed Codex UUID accepted: \(bad)")
        }
        let badThread = IslandSession(source: .codex, sessionID: "12345678-1234-1234-1234-123456789012", threadID: "bad", title: "task")
        try expect(SessionNavigation.conversationURL(for: badThread, applicationBundleIdentifier: "com.openai.codex") == nil, "malformed present thread ID must not fall back")
    }

    private static func verifyQoderRoutes() throws {
        let session = IslandSession(source: .qoder, sessionID: "session_A-9", threadID: "thread-is-not-the-desktop-key", title: "task", sourceApplication: .qoderDesktop)
        let url = try requiredURL(session, bundle: "com.qodercn.app")
        try expect(url.scheme == "qoder-cn" && url.host == "chat" && url.path == "/open", "Qoder URL route mismatch")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        try expect(components?.queryItems?.first(where: { $0.name == "sessionId" })?.value == "session_A-9", "Qoder must use sessionID, not threadID")

        let maxID = String(repeating: "a", count: 128)
        let maxSession = IslandSession(source: .qoder, sessionID: maxID, title: "task", sourceApplication: .qoderDesktop)
        try expect(SessionNavigation.conversationURL(for: maxSession, applicationBundleIdentifier: "com.qodercn.app") != nil, "128-character Qoder ID should pass")
        let tooLong = IslandSession(source: .qoder, sessionID: maxID + "a", title: "task", sourceApplication: .qoderDesktop)
        try expect(SessionNavigation.conversationURL(for: tooLong, applicationBundleIdentifier: "com.qodercn.app") == nil, "129-character Qoder ID should fail")
        for bad in ["", "has/slash", "has?query", "has%2Fescape", "has space", "trailing\n", "trailing\r", String(repeating: "x", count: 129)] {
            let invalid = IslandSession(source: .qoder, sessionID: bad, title: "task", sourceApplication: .qoderDesktop)
            try expect(SessionNavigation.conversationURL(for: invalid, applicationBundleIdentifier: "com.qodercn.app") == nil, "malformed Qoder session ID accepted: \(bad)")
        }

        // Agent tasks (scheduled jobs, quests, headless runs) are not chats: the
        // desktop rejects chat/open for their task-run IDs with an error toast.
        // Their workspace cwd shape is the only separating evidence.
        for taskCwd in ["/Users/u/Documents/Qoder/2026-10-21/da2b4285",
                        "/Users/u/Documents/Qoder/2026-10-21/da2b4285/src",
                        "/Volumes/x/work/Documents/Qoder/2025-01-02/abcdef12"] {
            let task = IslandSession(source: .qoder, sessionID: "a0f35d06-8f23-4ff0-84a0-e43182c49db6", title: "task", cwd: taskCwd, sourceApplication: .qoderDesktop)
            try expect(SessionNavigation.conversationURL(for: task, applicationBundleIdentifier: "com.qodercn.app") == nil, "agent task workspace must not deep link: \(taskCwd)")
        }
        for chatCwd in ["", "/Users/u/Documents/mac自研小工具/灵宠岛", "/Users/u",
                        "/Users/u/Documents/Qoder", "/Users/u/Documents/Qoder/notes/da2b4285",
                        "/Users/u/Documents/Qoder/2026-10-21/zzzzzzzz", "/Users/u/Documents/Qoder/2026-1-2/da2b4285"] {
            let chat = IslandSession(source: .qoder, sessionID: "session_A-9", title: "task", cwd: chatCwd, sourceApplication: .qoderDesktop)
            try expect(SessionNavigation.conversationURL(for: chat, applicationBundleIdentifier: "com.qodercn.app") != nil, "chat workspace must still deep link: \(chatCwd)")
        }
    }

    private static func verifyZCodeRoutes() throws {
        // ZCode's only session-adjacent route (zcode://workspace/open) shows
        // ZCode's own confirmation dialog on every click, which is worse UX
        // than activating the app. No cwd or origin may produce a deep link.
        for cwd in ["/private/tmp", "", "/nonexistent", "/"] {
            let session = IslandSession(source: .zcode, sessionID: "sess_abc123", title: "task", cwd: cwd, sourceApplication: .zcodeDesktop)
            try expect(SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: "dev.zcode.app") == nil, "ZCode must not deep link (cwd: \(cwd.prefix(24)))")
        }
        let remote = IslandSession(source: .zcode, host: "remote", sessionID: "sess_abc123", title: "task", cwd: "/private/tmp", sourceApplication: .zcodeDesktop)
        try expect(SessionNavigation.conversationURL(for: remote, applicationBundleIdentifier: "dev.zcode.app") == nil, "remote ZCode session must not route locally")
        try expect(SessionNavigation.conversationURL(for: IslandSession(source: .qoder, sessionID: "s", title: "task", cwd: "/private/tmp", sourceApplication: .qoderDesktop), applicationBundleIdentifier: "dev.zcode.app") == nil, "workspace route must stay source-scoped")
    }

    private static func verifyWorkBuddyRoutes() throws {
        let id = "A1234567-B89C-4DEF-8123-456789ABCDEF"
        let session = IslandSession(source: .workbuddy, sessionID: id, threadID: "unrelated-thread", turnID: "unrelated-turn", title: "task", sourceApplication: .workbuddyDesktop)
        let url = try requiredURL(session, bundle: "com.tencent.workbuddy.mac")
        try expect(url.absoluteString == "workbuddy://chat/A1234567-B89C-4DEF-8123-456789ABCDEF", "WorkBuddy must use the GUI Hook session ID")
        try expect(url.query == nil && url.fragment == nil, "WorkBuddy route must not include query or fragment")
        for invalid in ["", "token", id + "\n", id + "?x=y", id + "#fragment", id + "/other", "%2F" + id] {
            let bad = IslandSession(source: .workbuddy, sessionID: invalid, threadID: id, title: "task", sourceApplication: .workbuddyDesktop)
            try expect(SessionNavigation.conversationURL(for: bad, applicationBundleIdentifier: "com.tencent.workbuddy.mac") == nil, "WorkBuddy invalid session must not fall back to thread")
        }
        for origin in [SourceApplicationID.workbuddyAI, .workbuddyUnknown] {
            let other = IslandSession(source: .workbuddy, sessionID: id, title: "task", sourceApplication: origin)
            try expect(SessionNavigation.conversationURL(for: other, applicationBundleIdentifier: "com.tencent.workbuddy.mac") == nil, "Unverified WorkBuddy origins must not use desktop route")
        }
        let unknown = IslandSession(source: .workbuddy, sessionID: id, title: "task")
        try expect(SessionNavigation.conversationURL(for: unknown, applicationBundleIdentifier: "com.tencent.workbuddy.mac") == nil, "Missing WorkBuddy origin must not route")
        try expect(SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: "com.workbuddy.workbuddy-ai") == nil, "WorkBuddy desktop route must require exact bundle")
        let remote = IslandSession(source: .workbuddy, host: "remote", sessionID: id, title: "task", sourceApplication: .workbuddyDesktop)
        try expect(SessionNavigation.conversationURL(for: remote, applicationBundleIdentifier: "com.tencent.workbuddy.mac") == nil, "Remote WorkBuddy must not route locally")
    }

    private static func verifyScopeAndAppSelection() throws {
        let codexID = "12345678-1234-1234-1234-123456789012"
        let codex = IslandSession(source: .codex, sessionID: codexID, title: "task")
        try expect(SessionNavigation.conversationURL(for: codex, applicationBundleIdentifier: "com.qodercn.app") == nil, "Codex route must require the Codex app bundle")
        try expect(SessionNavigation.conversationURL(for: codex, applicationBundleIdentifier: "com.openai.chat") == nil, "ChatGPT bundle is outside the Codex desktop route")
        try expect(SessionNavigation.conversationURL(for: IslandSession(source: .codex, host: "remote", sessionID: codexID, title: "task"), applicationBundleIdentifier: "com.openai.codex") == nil, "remote Codex session must not route locally")

        let chatOrigin = IslandSession(source: .codex, sessionID: codexID, title: "task", sourceApplication: .codexChatGPT)
        try expect(SessionNavigation.conversationURL(for: chatOrigin, applicationBundleIdentifier: "com.openai.codex") == nil, "An explicitly different Codex host cannot be redirected to the Codex app")
        let qoder = IslandSession(source: .qoder, sessionID: "valid-token", title: "task", sourceApplication: .qoderDesktop)
        try expect(SessionNavigation.conversationURL(for: qoder, applicationBundleIdentifier: "com.openai.codex") == nil, "Qoder route must require Qoder bundle even when schemes overlap")
        try expect(SessionNavigation.conversationURL(for: qoder, applicationBundleIdentifier: "com.qodercn.app") != nil, "Qoder scheme registration must not be decided by system default handler")
        try expect(SessionNavigation.conversationURL(for: IslandSession(source: .qoder, sessionID: "valid-token", title: "task", sourceApplication: .qoderIDE), applicationBundleIdentifier: "com.qodercn.app") == nil, "Qoder IDE origin must not use desktop route")
        try expect(SessionNavigation.conversationURL(for: IslandSession(source: .qoder, sessionID: "valid-token", title: "task", sourceApplication: .qoderUnknown), applicationBundleIdentifier: "com.qodercn.app") == nil, "unknown Qoder origin must not use desktop route")
        try expect(SessionNavigation.conversationURL(for: IslandSession(source: .generic, sessionID: "valid", title: "task"), applicationBundleIdentifier: "com.qodercn.app") == nil, "generic source must not route")
    }

    private static func requiredURL(_ session: IslandSession, bundle: String) throws -> URL {
        guard let url = SessionNavigation.conversationURL(for: session, applicationBundleIdentifier: bundle) else {
            throw VerificationFailure.failed("expected a URL for \(session.source.rawValue)")
        }
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw VerificationFailure.failed(message) }
    }
}
