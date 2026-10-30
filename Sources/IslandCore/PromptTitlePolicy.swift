import Foundation

/// Per-source rules for turning a submitted prompt into a task title.
///
/// Desktop apps decorate user input differently: Codex wraps attached files
/// around the request, ZCode prepends ambient in-app-browser state. Each
/// source gets its own branch so one app's markup can never leak into
/// another's title handling; adding a source rule must not touch the others.
public enum PromptTitlePolicy {
    /// Codex desktop wraps attached files around the real request.
    case codexDesktop
    /// ZCode desktop prepends ambient in-app-browser context to the prompt.
    case zcodeDesktop
    /// Qoder, DeepSeek Harness, Buddy and unknown sources send raw user text.
    case plain

    public static func policy(for source: ProviderID) -> PromptTitlePolicy {
        switch source {
        case .codex: return .codexDesktop
        case .zcode: return .zcodeDesktop
        default: return .plain
        }
    }

    public func title(from prompt: String) -> String? {
        switch self {
        case .codexDesktop:
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(CodexQuestions.replyStart) else { return nil }
            return SessionTitle.promptText(prompt)
        case .zcodeDesktop: return SessionTitle.normalize(strippedAmbientBrowserContext(prompt))
        case .plain: return SessionTitle.normalize(prompt)
        }
    }

    /// ZCode injects `<in-app-browser-context source="ambient-ui-state">…</in-app-browser-context>`
    /// blocks ahead of the user's text while its in-app browser is open. The block is
    /// UI state, not the request, so anchored head occurrences are removed. An
    /// unterminated block is left in place rather than risk eating the real question.
    func strippedAmbientBrowserContext(_ prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^<in-app-browser-context\b[^>]*>[\s\S]*?</in-app-browser-context>"#
        while let range = text.range(of: pattern, options: .regularExpression) {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
