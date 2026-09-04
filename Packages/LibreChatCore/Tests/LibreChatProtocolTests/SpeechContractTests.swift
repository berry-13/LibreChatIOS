import Foundation
import LibreChatDomain
@testable import LibreChatProtocol
import Testing

struct SpeechContractTests {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")

    @Test func authenticatedConfigurationMapsOnlyProvenExternalSpeech() throws {
        let enabled = try JSONDecoder().decode(
            LibreChatSpeechConfigurationDTO.self,
            from: Data(#"{"sttExternal":true,"ttsExternal":false,"speechToText":true,"languageSTT":"EN-us","future":1}"#.utf8)
        )
        #expect(enabled.domainModel() == SpeechCapabilities(
            supportsSpeechToText: true,
            supportsTextToSpeech: false,
            preferredTranscriptionLanguage: "en-us"
        ))

        let disabled = LibreChatSpeechConfigurationDTO(
            sttExternal: true,
            ttsExternal: true,
            speechToText: false,
            textToSpeech: false,
            languageSTT: "not-a-locale"
        ).domainModel()
        #expect(disabled.supportsSpeechToText == false)
        #expect(disabled.supportsTextToSpeech == false)
        #expect(disabled.preferredTranscriptionLanguage == nil)

        let request = LibreChatSpeechAPI.configuration()
        #expect(request.method == .get)
        #expect(request.path == "api/files/speech/config/get")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func authenticatedConfigurationMapsSafeTTSPreferences() throws {
        let decoded = try JSONDecoder().decode(
            LibreChatSpeechConfigurationDTO.self,
            from: Data(#"{"ttsExternal":true,"textToSpeech":true,"voice":" alloy ","playbackRate":1.25}"#.utf8)
        ).domainModel()
        #expect(decoded.supportsTextToSpeech)
        #expect(decoded.preferredSynthesisVoice == "alloy")
        #expect(decoded.preferredPlaybackRate == 1.25)

        let invalid = LibreChatSpeechConfigurationDTO(
            ttsExternal: true,
            textToSpeech: true,
            voice: "bad\nvoice",
            playbackRate: 8
        ).domainModel()
        #expect(invalid.preferredSynthesisVoice == nil)
        #expect(invalid.preferredPlaybackRate == nil)
    }

    @Test func transcriptionUsesExactMultipartContractAndNeverRetries() throws {
        let request = try LibreChatSpeechAPI.transcribe(
            SpeechTranscriptionRequest(
                profileID: profileID,
                accountID: accountID,
                audio: Data([0x00, 0x01, 0xFE, 0xFF]),
                filename: "voice-123.m4a",
                mimeType: "audio/mp4",
                language: "EN-US"
            ),
            boundary: "SpeechBoundary"
        )

        #expect(request.method == .post)
        #expect(request.path == "api/files/speech/stt")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=SpeechBoundary")
        let body = try #require(request.body)
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.contains("name=\"language\"\r\n\r\nen-us\r\n"))
        #expect(string.contains("name=\"audio\"; filename=\"voice-123.m4a\""))
        #expect(string.contains("Content-Type: audio/mp4"))
        #expect(string.hasSuffix("\r\n--SpeechBoundary--\r\n"))
        #expect(body.range(of: Data([0x00, 0x01, 0xFE, 0xFF])) != nil)
    }

    @Test func languageIsOmittedRatherThanInvented() throws {
        let request = try LibreChatSpeechAPI.transcribe(
            SpeechTranscriptionRequest(
                profileID: profileID,
                accountID: accountID,
                audio: Data([1]),
                filename: "audio.m4a",
                mimeType: "audio/x-m4a"
            ),
            boundary: "Boundary"
        )
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(!body.contains("name=\"language\""))
        #expect(body.contains("name=\"audio\""))
    }

    @Test func invalidAudioMetadataFailsBeforeTransport() {
        for invalid in [
            SpeechTranscriptionRequest(
                profileID: profileID,
                accountID: accountID,
                audio: Data(),
                filename: "audio.m4a",
                mimeType: "audio/mp4"
            ),
            SpeechTranscriptionRequest(
                profileID: profileID,
                accountID: accountID,
                audio: Data([1]),
                filename: "../audio.m4a",
                mimeType: "audio/mp4"
            ),
            SpeechTranscriptionRequest(
                profileID: profileID,
                accountID: accountID,
                audio: Data([1]),
                filename: "audio.aac",
                mimeType: "audio/aac"
            )
        ] {
            #expect(throws: LibreChatProtocolError.self) {
                _ = try LibreChatSpeechAPI.transcribe(invalid, boundary: "Boundary")
            }
        }

        #expect(throws: LibreChatProtocolError.encoding("The transcription language is invalid.")) {
            _ = try LibreChatSpeechAPI.transcribe(
                SpeechTranscriptionRequest(
                    profileID: profileID,
                    accountID: accountID,
                    audio: Data([1]),
                    filename: "audio.m4a",
                    mimeType: "audio/mp4",
                    language: "English"
                ),
                boundary: "Boundary"
            )
        }
    }

    @Test func responseRequiresNonemptyTranscriptAndTrimsIt() throws {
        let mapped = try LibreChatSpeechTranscriptionDTO(text: "  Hello world. \n").domainModel()
        #expect(mapped == SpeechTranscription(text: "Hello world."))
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try LibreChatSpeechTranscriptionDTO(text: " \n ").domainModel()
        }
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try LibreChatSpeechTranscriptionDTO(text: nil).domainModel()
        }
    }

    @Test func manualSynthesisUsesExactMultipartContractAndNeverRetries() throws {
        let request = try LibreChatSpeechAPI.synthesize(
            SpeechSynthesisRequest(
                profileID: profileID,
                accountID: accountID,
                text: "  Read this response.\n",
                voice: "alloy"
            ),
            boundary: "SpeechBoundary"
        )

        #expect(request.method == .post)
        #expect(request.path == "api/files/speech/tts/manual")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=SpeechBoundary")
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.contains("name=\"input\"\r\n\r\n  Read this response.\n\r\n"))
        #expect(body.contains("name=\"voice\"\r\n\r\nalloy\r\n"))
        #expect(body.hasSuffix("--SpeechBoundary--\r\n"))
    }

    @Test func manualSynthesisOmitsVoiceAndRejectsUnsafeInput() throws {
        let request = try LibreChatSpeechAPI.synthesize(
            SpeechSynthesisRequest(
                profileID: profileID,
                accountID: accountID,
                text: "Readable"
            ),
            boundary: "Boundary"
        )
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.contains("name=\"input\""))
        #expect(!body.contains("name=\"voice\""))

        #expect(throws: LibreChatProtocolError.self) {
            _ = try LibreChatSpeechAPI.synthesize(
                SpeechSynthesisRequest(
                    profileID: profileID,
                    accountID: accountID,
                    text: " \n "
                ),
                boundary: "Boundary"
            )
        }
        #expect(throws: LibreChatProtocolError.self) {
            _ = try LibreChatSpeechAPI.synthesize(
                SpeechSynthesisRequest(
                    profileID: profileID,
                    accountID: accountID,
                    text: "Readable",
                    voice: "bad\nvoice"
                ),
                boundary: "Boundary"
            )
        }
    }

    @Test func synthesisAudioRequiresNonemptyMPEGBinaryResponse() throws {
        let valid = HTTPResponse(
            data: Data([0x49, 0x44, 0x33, 0x04]),
            statusCode: 200,
            headers: ["content-type": "audio/mpeg; charset=binary"],
            finalURL: URL(string: "https://chat.example/api/files/speech/tts/manual")!
        )
        #expect(try LibreChatSpeechAPI.synthesisAudio(from: valid) == SynthesizedSpeechAudio(
            data: valid.data,
            mimeType: "audio/mpeg"
        ))

        for response in [
            HTTPResponse(
                data: Data(),
                statusCode: 200,
                headers: ["Content-Type": "audio/mpeg"],
                finalURL: valid.finalURL
            ),
            HTTPResponse(
                data: Data(#"{"error":"not audio"}"#.utf8),
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                finalURL: valid.finalURL
            )
        ] {
            #expect(throws: LibreChatProtocolError.invalidResponse) {
                _ = try LibreChatSpeechAPI.synthesisAudio(from: response)
            }
        }
    }

    @Test func configuredVoicesAreStableDeduplicatedAndFailClosed() {
        #expect(LibreChatSpeechAPI.synthesisVoices(from: [
            " alloy ", "ALL", "alloy", "nova", "bad\nvoice", "nova"
        ]) == [
            SpeechSynthesisVoice(id: "alloy"),
            SpeechSynthesisVoice(id: "nova")
        ])

        let request = LibreChatSpeechAPI.voices()
        #expect(request.path == "api/files/speech/tts/voices")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func voicePreferenceKeepsServerDefaultDistinctFromAnOpaqueSelection() throws {
        let serverDefault = SpeechSynthesisVoicePreference.serverDefault
        let selected = SpeechSynthesisVoicePreference.specific(
            SpeechSynthesisVoice(id: "provider-opaque-voice")
        )

        #expect(serverDefault.requestVoice(serverPreferredVoice: "configured") == "configured")
        #expect(serverDefault.selectedVoice == nil)
        #expect(selected.requestVoice(serverPreferredVoice: "configured") == "provider-opaque-voice")
        #expect(selected.selectedVoice == SpeechSynthesisVoice(id: "provider-opaque-voice"))

        let encoded = try JSONEncoder().encode(selected)
        #expect(try JSONDecoder().decode(
            SpeechSynthesisVoicePreference.self,
            from: encoded
        ) == selected)
    }

    @Test func spokenProjectionIncludesOnlyFinishedAssistantProse() throws {
        let message = ChatMessage(
            id: MessageID(rawValue: "assistant-1"),
            conversationID: ConversationID(rawValue: "conversation"),
            content: [
                .reasoning("hidden reasoning"),
                .text("# Answer\nVisible **prose** with [source](https://example.com).\n```swift\nsecret()\n```\n:::artifact{title=\"Hidden\"}\nartifact text\n:::\nFinal line with `inlineCode()`."),
                .code(CodeContent(language: "swift", code: "hiddenCode()")),
                .activity(.init(id: "activity", label: "Searching private files")),
                .error(.init(message: "hidden failure"))
            ],
            author: .assistant(name: "Assistant"),
            isUnfinished: false
        )
        let projection = try #require(MessageSpeechProjector.project(message))
        #expect(projection.text == "Answer\nVisible prose with source.\nFinal line with .")
        #expect(!projection.text.contains("reasoning"))
        #expect(!projection.text.contains("secret"))
        #expect(projection.revision == MessageSpeechProjector.project(message)?.revision)

        var streaming = message
        streaming.isUnfinished = true
        #expect(MessageSpeechProjector.project(streaming) == nil)

        let user = ChatMessage(
            id: MessageID(rawValue: "user"),
            conversationID: message.conversationID,
            content: [.text("Do not read")],
            author: .user
        )
        #expect(MessageSpeechProjector.project(user) == nil)
    }

    @Test func legacyCapabilitiesDecodeWithoutSpeechProof() throws {
        let current = ServerCapabilities(supportsSpeech: true)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)
        ) as? [String: Any])
        object.removeValue(forKey: "speechCapabilities")

        let decoded = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.supportsSpeech)
        #expect(decoded.speechCapabilities == nil)
    }
}
