import Foundation

/// Builds a narrowly scoped deep link to the originating conversation.
/// The caller supplies the detected target app bundle so a shared URL scheme
/// cannot redirect navigation to another installed application.
public enum SessionNavigation {
    public static func conversationURL(for session: IslandSession, applicationBundleIdentifier: String) -> URL? {
        guard session.host == "localhost" else { return nil }

        switch session.source {
        case .codex:
            guard applicationBundleIdentifier == "com.openai.codex",
                  session.sourceApplication == nil || session.sourceApplication == .codexDesktop else { return nil }
            // Codex desktop identifies a thread by UUID. If a thread ID is present,
            // validate it strictly instead of silently targeting a different session.
            let candidate = session.threadID ?? session.sessionID
            guard let uuid = strictUUID(candidate) else { return nil }
            var components = URLComponents()
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/\(uuid.uuidString.lowercased())"
            return components.url

        case .qoder:
            guard session.sourceApplication == .qoderDesktop,
                  applicationBundleIdentifier == "com.qodercn.app",
                  isQoderSessionID(session.sessionID),
                  !isQoderAgentTaskWorkspace(session.cwd) else { return nil }
            var components = URLComponents()
            components.scheme = "qoder-cn"
            components.host = "chat"
            components.path = "/open"
            components.queryItems = [URLQueryItem(name: "sessionId", value: session.sessionID)]
            return components.url

        case .workbuddy:
            guard session.sourceApplication == .workbuddyDesktop,
                  applicationBundleIdentifier == "com.tencent.workbuddy.mac",
                  strictUUID(session.sessionID) != nil else { return nil }
            // WorkBuddy's GUI conversation ID is the Hook session ID. Thread and
            // turn IDs identify other scopes and must never replace it here.
            var components = URLComponents()
            components.scheme = "workbuddy"
            components.host = "chat"
            components.path = "/\(session.sessionID)"
            return components.url

        case .claude, .codebuddy, .dsh, .generic, .zcode:
            // ZCode's only session-adjacent route is zcode://workspace/open,
            // which shows ZCode's own confirmation dialog on every click. That
            // friction outweighs workspace-level precision, so ZCode clicks
            // simply open the app.
            return nil
        }
    }

    private static func strictUUID(_ value: String) -> UUID? {
        guard value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil else { return nil }
        return UUID(uuidString: value)
    }

    private static func isQoderSessionID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    /// Qoder's agent tasks (scheduled jobs, quests, headless CLI runs) execute in
    /// an auto-created workspace `…/Documents/Qoder/<yyyy-MM-dd>/<short-hex-id>`
    /// and their hook session IDs are task-run IDs, not chats: `qoder-cn://chat/open`
    /// only resolves chats in the signed-in account's chat list, and Qoder reports
    /// 「无法打开该会话」for everything else. Hook payloads carry no marker that
    /// separates these sessions from chats (verified against real hook inputs in
    /// docs/Qoder会话跳转调研.md), so the workspace path shape is the narrowest
    /// evidence available. A misdetection only downgrades the click to opening the
    /// app, which is strictly better than a source-side error toast.
    private static func isQoderAgentTaskWorkspace(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 4 else { return false }
        for index in 0...(components.count - 4) {
            guard components[index] == "Documents", components[index + 1] == "Qoder",
                  components[index + 2].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                  components[index + 3].range(of: "^[0-9a-fA-F]{6,16}$", options: .regularExpression) != nil
            else { continue }
            return true
        }
        return false
    }
}
