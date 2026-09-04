import Foundation

/// Authenticated speech features proven by LibreChat's speech configuration
/// endpoint. Startup hints alone are not sufficient to enable microphone UI.
public struct SpeechCapabilities: Codable, Equatable, Sendable {
    public var supportsSpeechToText: Bool
    public var supportsTextToSpeech: Bool
    public var preferredTranscriptionLanguage: String?
    public var preferredSynthesisVoice: String?
    public var preferredPlaybackRate: Double?

    public init(
        supportsSpeechToText: Bool,
        supportsTextToSpeech: Bool,
        preferredTranscriptionLanguage: String? = nil,
        preferredSynthesisVoice: String? = nil,
        preferredPlaybackRate: Double? = nil
    ) {
        self.supportsSpeechToText = supportsSpeechToText
        self.supportsTextToSpeech = supportsTextToSpeech
        self.preferredTranscriptionLanguage = preferredTranscriptionLanguage
        self.preferredSynthesisVoice = preferredSynthesisVoice
        self.preferredPlaybackRate = preferredPlaybackRate
    }
}

/// One explicit, user-initiated transcription request. Audio remains
/// profile/account scoped and is never treated as a chat attachment.
public struct SpeechTranscriptionRequest: Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let audio: Data
    public let filename: String
    public let mimeType: String
    public let language: String?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        audio: Data,
        filename: String,
        mimeType: String,
        language: String? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.audio = audio
        self.filename = filename
        self.mimeType = mimeType
        self.language = language
    }
}

public struct SpeechTranscription: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct SpeechSynthesisVoice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// One account-scoped manual TTS preference. Voice identifiers are opaque
/// server values: the native client never derives provider, locale, or gender
/// metadata from them. `serverDefault` means to honor LibreChat's authenticated
/// speech configuration rather than pinning a user-selected identifier.
public enum SpeechSynthesisVoicePreference: Codable, Equatable, Hashable, Sendable {
    case serverDefault
    case specific(SpeechSynthesisVoice)

    public var selectedVoice: SpeechSynthesisVoice? {
        guard case let .specific(voice) = self else { return nil }
        return voice
    }

    public func requestVoice(serverPreferredVoice: String?) -> String? {
        switch self {
        case .serverDefault:
            serverPreferredVoice
        case let .specific(voice):
            voice.id
        }
    }
}

/// One explicit read-aloud request. The full response text is sent only after
/// the user invokes the action and is never persisted as synthesized audio.
public struct SpeechSynthesisRequest: Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let text: String
    public let voice: String?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        text: String,
        voice: String? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.text = text
        self.voice = voice
    }
}

public struct SynthesizedSpeechAudio: Equatable, Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public enum SpeechSynthesisRepositoryError: LocalizedError, Equatable, Sendable {
    case unavailable

    public var errorDescription: String? {
        "Read aloud is unavailable for this repository."
    }
}

public struct SpokenMessageText: Equatable, Hashable, Sendable {
    public let text: String
    public let revision: String

    public init(text: String, revision: String) {
        self.text = text
        self.revision = revision
    }
}

/// Produces an intentionally narrow spoken projection: finished assistant
/// prose only. Reasoning, code content parts, tool payloads, activities,
/// errors, attachment transcripts, and hidden protocol metadata never enter
/// a server TTS request.
public enum MessageSpeechProjector {
    public static func project(_ message: ChatMessage) -> SpokenMessageText? {
        guard case .assistant = message.author,
              message.isUnfinished != true,
              !message.id.rawValue.hasPrefix("local-") else {
            return nil
        }

        let rawProse = message.content.compactMap { content -> String? in
            guard case let .text(text) = content else { return nil }
            return text
        }.joined(separator: "\n")
        let citationCleaned = CitationMarkerResolver.resolve(
            rawProse,
            sources: CitationSourceCatalog(attachments: message.citationAttachments)
        ).cleanedText
        let spoken = markdownProse(citationCleaned)
        guard !spoken.isEmpty else { return nil }
        return SpokenMessageText(text: spoken, revision: stableRevision(spoken))
    }

    private static func markdownProse(_ source: String) -> String {
        var proseLines: [String] = []
        var fence: Character?
        var inArtifact = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":::artifact") {
                inArtifact = true
                continue
            }
            if inArtifact {
                if trimmed == ":::" { inArtifact = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker: Character = trimmed.first == "`" ? "`" : "~"
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }

            var value = line
            value = value.replacingOccurrences(
                of: #"!\[([^\]]*)\]\([^)]*\)"#,
                with: "$1",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]*\)"#,
                with: "$1",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"`[^`]*`"#,
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#,
                with: "",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: #"[*_~]"#,
                with: "",
                options: .regularExpression
            )
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { proseLines.append(normalized) }
        }

        return proseLines.joined(separator: "\n")
            .replacingOccurrences(
                of: #"[\t ]{2,}"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableRevision(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
