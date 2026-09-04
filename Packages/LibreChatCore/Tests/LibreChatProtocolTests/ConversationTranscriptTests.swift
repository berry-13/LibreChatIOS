import LibreChatDomain
import Testing

struct ConversationTranscriptTests {
    @Test func exportUsesVisibleTextAndStableRoleLabelsWithoutProtocolMetadata() {
        let conversationID = ConversationID(rawValue: "private-conversation-id")
        let transcript = ConversationTranscript.markdown(
            title: "Weekly\nreview",
            messages: [
                ChatMessage(
                    id: MessageID(rawValue: "private-user-id"),
                    conversationID: conversationID,
                    content: [.text("What changed?")],
                    author: .user,
                    model: "private-model",
                    endpoint: "private-endpoint"
                ),
                ChatMessage(
                    id: MessageID(rawValue: "private-assistant-id"),
                    conversationID: conversationID,
                    content: [.text("A concise answer.")],
                    author: .assistant(name: "Server-provided private agent name")
                ),
            ]
        )

        #expect(transcript == "# Weekly review\n\n## You\n\nWhat changed?\n\n## Assistant\n\nA concise answer.")
        #expect(!transcript.contains("private"))
        #expect(!transcript.contains("Server-provided"))
    }

    @Test func exportUsesCleanedCitationTextAndSkipsNontextOnlyRows() {
        let conversationID = ConversationID(rawValue: "conversation")
        let transcript = ConversationTranscript.markdown(
            title: "",
            messages: [
                ChatMessage(
                    id: MessageID(rawValue: "assistant"),
                    conversationID: conversationID,
                    content: [.text("Verified claim \u{E202}turn0search0")],
                    author: .assistant(name: "Assistant")
                ),
                ChatMessage(
                    id: MessageID(rawValue: "file"),
                    conversationID: conversationID,
                    content: [.file(UploadedFile(id: "secret-file-id", filename: "report.pdf"))],
                    author: .system(name: "Tool")
                ),
            ]
        )

        #expect(transcript == "# Conversation\n\n## Assistant\n\nVerified claim")
        #expect(!transcript.contains("turn0search0"))
        #expect(!transcript.contains("secret-file-id"))
    }
}
