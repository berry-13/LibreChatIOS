import Foundation

/// A privacy-bounded, branch-scoped plain Markdown export. It deliberately
/// excludes protocol IDs, model/endpoint metadata, hidden tool payloads, and
/// raw citation markers. Callers decide which authoritative branch is visible.
public enum ConversationTranscript {
    public static func markdown(
        title: String,
        messages: [ChatMessage]
    ) -> String {
        let heading = singleLine(title).nonEmpty ?? "Conversation"
        let sections = messages.compactMap { message -> String? in
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "## \(roleLabel(message.author))\n\n\(text)"
        }
        guard !sections.isEmpty else { return "# \(heading)" }
        return (["# \(heading)"] + sections).joined(separator: "\n\n")
    }

    private static func roleLabel(_ author: MessageAuthor) -> String {
        switch author {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        }
    }

    private static func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
