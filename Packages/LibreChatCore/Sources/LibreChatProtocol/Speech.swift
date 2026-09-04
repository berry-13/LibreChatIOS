import Foundation
import LibreChatDomain

public struct LibreChatSpeechConfigurationDTO: Codable, Equatable, Sendable {
    public var sttExternal: Bool?
    public var ttsExternal: Bool?
    public var speechToText: Bool?
    public var textToSpeech: Bool?
    public var languageSTT: String?
    public var voice: String?
    public var playbackRate: Double?

    public init(
        sttExternal: Bool? = nil,
        ttsExternal: Bool? = nil,
        speechToText: Bool? = nil,
        textToSpeech: Bool? = nil,
        languageSTT: String? = nil,
        voice: String? = nil,
        playbackRate: Double? = nil
    ) {
        self.sttExternal = sttExternal
        self.ttsExternal = ttsExternal
        self.speechToText = speechToText
        self.textToSpeech = textToSpeech
        self.languageSTT = languageSTT
        self.voice = voice
        self.playbackRate = playbackRate
    }

    public func domainModel() -> SpeechCapabilities {
        SpeechCapabilities(
            supportsSpeechToText: sttExternal == true && speechToText != false,
            supportsTextToSpeech: ttsExternal == true && textToSpeech != false,
            preferredTranscriptionLanguage: Self.validLanguage(languageSTT),
            preferredSynthesisVoice: Self.validVoice(voice),
            preferredPlaybackRate: Self.validPlaybackRate(playbackRate)
        )
    }

    private static func validLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.range(
            of: #"^[a-z]{2}(?:-[a-z]{2})?$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return normalized
    }

    private static func validVoice(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf16.count <= 256,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    private static func validPlaybackRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0.25...4).contains(value) else { return nil }
        return value
    }
}

public struct LibreChatSpeechTranscriptionDTO: Codable, Equatable, Sendable {
    public var text: String?

    public init(text: String? = nil) {
        self.text = text
    }

    public func domainModel() throws -> SpeechTranscription {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return SpeechTranscription(text: normalized)
    }
}

public enum LibreChatSpeechAPI {
    public static func configuration() -> APIRequest<LibreChatSpeechConfigurationDTO> {
        APIRequest(
            path: "api/files/speech/config/get",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func transcribe(
        _ request: SpeechTranscriptionRequest,
        boundary: String = "LibreChatSpeech-\(UUID().uuidString)"
    ) throws -> APIRequest<LibreChatSpeechTranscriptionDTO> {
        guard !request.audio.isEmpty, request.audio.count <= 25 * 1_024 * 1_024 else {
            throw LibreChatProtocolError.unsupported("The voice recording is empty or too large to transcribe.")
        }
        guard request.filename.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw LibreChatProtocolError.encoding("The recording filename is invalid.")
        }
        let allowedMIMETypes: Set<String> = [
            "audio/flac", "audio/mp3", "audio/mp4", "audio/mpeg", "audio/mpeg3",
            "audio/ogg", "audio/vorbis", "audio/wav", "audio/wave", "audio/webm",
            "audio/x-flac", "audio/x-m4a", "audio/x-wav"
        ]
        guard allowedMIMETypes.contains(request.mimeType.lowercased()) else {
            throw LibreChatProtocolError.unsupported("That audio format is not supported for transcription.")
        }
        guard boundary.range(
            of: #"^[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression
        ) != nil else {
            throw LibreChatProtocolError.encoding("The multipart boundary is invalid.")
        }

        var normalizedLanguage: String?
        if let language = request.language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            let candidate = language.lowercased()
            guard candidate.range(
                of: #"^[a-z]{2}(?:-[a-z]{2})?$"#,
                options: .regularExpression
            ) != nil else {
                throw LibreChatProtocolError.encoding("The transcription language is invalid.")
            }
            normalizedLanguage = candidate
        }

        let body: Data? = multipartBody(
            audio: request.audio,
            filename: request.filename,
            mimeType: request.mimeType.lowercased(),
            language: normalizedLanguage,
            boundary: boundary
        )
        return APIRequest(
            method: .post,
            path: "api/files/speech/stt",
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: body,
            authorization: .bearer,
            retryPolicy: .never
        )
    }

    public static func voices() -> APIRequest<[String]> {
        APIRequest(
            path: "api/files/speech/tts/voices",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func synthesisVoices(from values: [String]) -> [SpeechSynthesisVoice] {
        var seen = Set<String>()
        return values.compactMap { value in
            let voice = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voice.isEmpty,
                  voice.caseInsensitiveCompare("ALL") != .orderedSame,
                  voice.utf16.count <= 256,
                  voice.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  seen.insert(voice).inserted else {
                return nil
            }
            return SpeechSynthesisVoice(id: voice)
        }
    }

    public static func synthesize(
        _ request: SpeechSynthesisRequest,
        boundary: String = "LibreChatSpeech-\(UUID().uuidString)"
    ) throws -> APIRequest<EmptyResponse> {
        let visibleText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty, request.text.utf16.count <= 200_000 else {
            throw LibreChatProtocolError.unsupported(
                "The response is empty or too long to read aloud."
            )
        }
        guard boundary.range(
            of: #"^[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression
        ) != nil else {
            throw LibreChatProtocolError.encoding("The multipart boundary is invalid.")
        }

        var normalizedVoice: String?
        if let voice = request.voice?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voice.isEmpty {
            guard voice.utf16.count <= 256,
                  voice.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw LibreChatProtocolError.encoding("The speech voice is invalid.")
            }
            normalizedVoice = voice
        }

        let body: Data? = synthesisMultipartBody(
            text: request.text,
            voice: normalizedVoice,
            boundary: boundary
        )
        return APIRequest(
            method: .post,
            path: "api/files/speech/tts/manual",
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: body,
            authorization: .bearer,
            retryPolicy: .never
        )
    }

    private static func multipartBody(
        audio: Data,
        filename: String,
        mimeType: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        if let language {
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n", to: &body)
            append("\(language)\r\n", to: &body)
        }
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n",
            to: &body
        )
        append("Content-Type: \(mimeType)\r\n\r\n", to: &body)
        body.append(audio)
        append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func synthesisMultipartBody(
        text: String,
        voice: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"input\"\r\n\r\n", to: &body)
        append("\(text)\r\n", to: &body)
        if let voice {
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"voice\"\r\n\r\n", to: &body)
            append("\(voice)\r\n", to: &body)
        }
        append("--\(boundary)--\r\n", to: &body)
        return body
    }

    public static func synthesisAudio(
        from response: HTTPResponse,
        maximumBytes: Int = 64 * 1_024 * 1_024
    ) throws -> SynthesizedSpeechAudio {
        guard !response.data.isEmpty, response.data.count <= maximumBytes else {
            throw LibreChatProtocolError.invalidResponse
        }
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType == "audio/mpeg" || contentType == "audio/mp3" else {
            throw LibreChatProtocolError.invalidResponse
        }
        return SynthesizedSpeechAudio(data: response.data, mimeType: "audio/mpeg")
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }
}
