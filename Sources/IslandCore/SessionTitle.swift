import Foundation

/// Shared title cleanup and display fallback rules for normalized sessions.
public enum SessionTitle {
    private static let placeholderTitles: Set<String> = [
        "qoder会话", "qodercn会话", "qodercnide会话", "codex会话", "generic会话", "其他工具会话",
        "通义灵码会话", "灵码会话", "codebuddy会话", "workbuddy会话"
    ]

    /// Collapse whitespace to one line, trim it, reject generic tool labels, and bound display text.
    public static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }

        let compact = cleaned.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
        guard !placeholderTitles.contains(compact) else { return nil }
        return String(cleaned.prefix(120))
    }

    /// Returns a project directory name when cwd identifies a real project directory.
    public static func projectName(from cwd: String?) -> String? {
        guard let cwd else { return nil }
        let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last, !last.isEmpty else { return nil }
        if components.count == 2 && ["Users", "home"].contains(components[0]) { return nil }
        if isUUIDDirectory(last) { return nil }
        return normalize(last)
    }

    /// Extract only the user's requested body from the explicit attachment wrapper.
    public static func promptText(_ prompt: String) -> String? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "## My request:"
        if prompt.hasPrefix("# Files mentioned by the user:"), let range = prompt.range(of: marker) {
            var body = String(prompt[range.upperBound...])
            // Attachment markup follows the user's request in desktop hook
            // payloads. Its file paths are not part of a task title.
            if let attachment = body.range(of: #"(?m)^\s*<image(?:\s|>)"#, options: .regularExpression) {
                body = String(body[..<attachment.lowerBound])
            }
            return normalize(body)
        }
        return normalize(prompt)
    }

    /// Display title remains useful for callers that construct legacy sessions directly.
    public static func displayTitle(title: String?, cwd: String?, question: String?) -> String {
        normalize(title) ?? projectName(from: cwd) ?? normalize(question) ?? "未命名任务"
    }

    private static func isUUIDDirectory(_ name: String) -> Bool {
        let pattern = "^(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
