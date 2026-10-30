import Foundation

/// Observation of the local Codex tool protocol. Hooks do not provide a reply channel.
enum CodexQuestions {
    static func toolName(_ tool: String) -> String? {
        let name = tool.hasPrefix("functions.") ? String(tool.dropFirst("functions.".count)) : tool
        return ["request_user_input", "request_user_input_async"].contains(name) ? name : nil
    }

    static func request(tool: String, id: String, input: [String: JSONValue]) -> QuestionRequest? {
        guard let items = input["questions"]?.arrayValue, !items.isEmpty else { return nil }
        let prompts = items.compactMap { $0["question"]?.stringValue ?? $0["title"]?.stringValue }
        guard prompts.count == items.count, prompts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let options = items.count == 1 ? (items[0]["options"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["label"]?.stringValue } : []
        let responseIDs: [String]? = tool == "request_user_input_async" ? items.indices.compactMap { index in
            itemID([.string(tool), .string(id), .number(Double(index))])
        } : nil
        if let responseIDs, responseIDs.count != items.count { return nil }
        return QuestionRequest(id: id, prompt: prompts.joined(separator: "\n\n"), options: options, canAnswer: false, responseItemIDs: responseIDs)
    }

    static let replyStart = "<send_user_message_question_reply>"
    static let replyEnd = "</send_user_message_question_reply>"

    static func accepted(_ response: JSONValue?) -> Bool {
        if let text = response?.stringValue,
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            return decoded["accepted"]?.boolValue == true
        }
        return response?["accepted"]?.boolValue == true
    }

    static func answers(in prompt: String) -> [String]? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(replyStart), text.hasSuffix(replyEnd),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.dropFirst(replyStart.count).dropLast(replyEnd.count).utf8)) else { return nil }
        let items = value.arrayValue ?? (value.objectValue == nil ? [] : [value])
        guard !items.isEmpty else { return nil }
        var result: [String] = []
        for item in items {
            guard item["question"]?.stringValue != nil, item["answer"]?.stringValue != nil,
                  let id = item["questionItemId"]?.stringValue,
                  let parts = try? JSONDecoder().decode([JSONValue].self, from: Data(id.utf8)), parts.count == 3,
                  parts[0].stringValue == "request_user_input_async", let call = parts[1].stringValue, !call.isEmpty,
                  let index = parts[2].numberValue, index >= 0, index.rounded() == index else { return nil }
            // Canonicalize JSON whitespace/escaping before matching the opaque tuple.
            guard let canonical = itemID(parts) else { return nil }
            result.append(canonical)
        }
        return result
    }

    private static func itemID(_ parts: [JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(parts) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
