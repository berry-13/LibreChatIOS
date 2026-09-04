import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct MappingTests {
    @Test func messagePreservesOptionalReplayMetadataAndLegacyAbsence() throws {
        let data = Data(
            """
            {"messageId":"m-meta","conversationId":"c1","isCreatedByUser":true,
             "text":"Prompt","manualSkills":["skill-a"],"quotes":["quote-a"]}
            """.utf8
        )
        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()
        #expect(message.manualSkills == ["skill-a"])
        #expect(message.quotes == ["quote-a"])

        let legacy = try JSONDecoder().decode(
            LibreChatMessageDTO.self,
            from: Data(#"{"messageId":"m-legacy","conversationId":"c1","text":"Prompt"}"#.utf8)
        ).domainModel()
        #expect(legacy.manualSkills == nil)
        #expect(legacy.quotes == nil)
    }

    @Test func conversationMappingKeepsRoutingSeparate() throws {
        let data = Data(
            """
            {"conversationId":"c1","title":"Plan","endpoint":"agents","model":"m1","agent_id":"a1","unknown":true}
            """.utf8
        )
        let dto = try JSONDecoder().decode(LibreChatConversationDTO.self, from: data)
        let conversation = try dto.domainModel()
        #expect(conversation.id == ConversationID(rawValue: "c1"))
        #expect(conversation.target?.agentID == "a1")
    }

    @Test func conversationMappingPreservesTemporaryRetentionAndLegacyInference() throws {
        let explicit = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(
                #"{"conversationId":"temporary","title":"Temporary","isTemporary":true,"expiredAt":"2030-01-02T03:04:05.123Z"}"#.utf8
            )
        ).domainModel()
        #expect(explicit.isTemporaryConversation)
        #expect(explicit.expiresAt != nil)

        let legacy = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(
                #"{"conversationId":"legacy-temporary","expiredAt":"2030-01-02T03:04:05Z"}"#.utf8
            )
        ).domainModel()
        #expect(legacy.isTemporary == nil)
        #expect(legacy.isTemporaryConversation)

        let permanent = Conversation(id: ConversationID(rawValue: "permanent"), title: "Saved")
        #expect(!permanent.isTemporaryConversation)
    }

    @Test func messagePreservesKnownAndUnsupportedParts() throws {
        let data = Data(
            """
            {
              "messageId":"m1","conversationId":"c1","sender":"Assistant","isCreatedByUser":false,
              "content":[
                {"type":"text","text":"Hello "},
                {"type":"reasoning","text":{"value":"thinking"}},
                {"type":"future_widget","payload":{"anything":true}}
              ]
            }
            """.utf8
        )
        let dto = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data)
        let message = try dto.domainModel()
        #expect(message.content == [.text("Hello "), .reasoning("thinking"), .unsupported(kind: "future_widget")])
    }

    @Test func messageMapsServerFileAttachmentsWithoutFlatteningMetadata() throws {
        let data = Data(
            """
            {
              "messageId":"m-file","conversationId":"c1","sender":"You","isCreatedByUser":true,
              "text":"Review this",
              "files":[{
                "file_id":"file-1","temp_file_id":"temp-1","filename":"brief.pdf",
                "bytes":2048,"type":"application/pdf","context":"message_attachment",
                "source":"local","status":"ready"
              }]
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()

        #expect(message.content == [
            .text("Review this"),
            .file(UploadedFile(
                id: "file-1",
                temporaryID: "temp-1",
                filename: "brief.pdf",
                mimeType: "application/pdf",
                bytes: 2048,
                context: "message_attachment",
                source: "local",
                previewStatus: "ready"
            ))
        ])
    }

    @Test func queuedFileUsageAndDeletionBodiesMatchLibreChatWireKeys() throws {
        let usage = try JSONEncoder().encode(FilesUsageRequestDTO(fileIDs: ["file-1", "file-2"]))
        let usageObject = try #require(JSONSerialization.jsonObject(with: usage) as? [String: Any])
        #expect(usageObject["file_ids"] as? [String] == ["file-1", "file-2"])

        let file = UploadedFile(
            id: "file-1",
            temporaryID: "temp-1",
            filename: "brief.pdf",
            filepath: "/uploads/brief.pdf",
            source: "local",
            embedded: false
        )
        let deletion = try JSONEncoder().encode(
            DeleteFilesRequestDTO(files: [try FileDeletionDTO(file: file)])
        )
        let deletionObject = try #require(JSONSerialization.jsonObject(with: deletion) as? [String: Any])
        let files = try #require(deletionObject["files"] as? [[String: Any]])
        #expect(files.first?["file_id"] as? String == "file-1")
        #expect(files.first?["temp_file_id"] as? String == "temp-1")
        #expect(files.first?["filepath"] as? String == "/uploads/brief.pdf")
        #expect(files.first?["source"] as? String == "local")
        #expect(files.first?["embedded"] as? Bool == false)
    }

    @Test func fileConfigurationPreservesClientImageResizePolicy() throws {
        let data = Data(
            #"{"serverFileSizeLimit":536870912,"clientImageResize":{"enabled":true,"maxWidth":1900,"maxHeight":1200,"quality":0.92},"endpoints":{"agents":{"fileLimit":10,"supportedMimeTypes":["^image/"]}}}"#.utf8
        )

        let configuration = try JSONDecoder().decode(FileConfigurationDTO.self, from: data)

        #expect(configuration.serverFileSizeLimit == 536_870_912)
        #expect(configuration.clientImageResize == ClientImageResizeConfigurationDTO(
            enabled: true,
            maxWidth: 1_900,
            maxHeight: 1_200,
            quality: 0.92
        ))
        #expect(configuration.endpoints?["agents"]?.fileLimit == 10)
        #expect(configuration.endpoints?["agents"]?.supportedMimeTypes == ["^image/"])
    }

    @Test func messageMapsRichSemanticPartsAndTerminalMetadata() throws {
        let data = Data(
            """
            {
              "messageId":"rich","conversationId":"c1","sender":"Assistant","isCreatedByUser":false,
              "unfinished":true,"finish_reason":"tool_pause",
              "content":[
                {"type":"summary","content":[{"type":"text","text":"Condensed result"}],"token_count":42,"model":"m1","provider":"p1"},
                {"type":"activity_label","id":"phase-1","label":"Searching sources","status":"running","pending":true,"agent_id":"agent-1"},
                {"type":"tool_call","tool_call":{"id":"call-1","name":"search","status":"completed","args":{"q":"swift"},"output":{"result":"ok"}}},
                {"type":"video_url","video_url":{"url":"https://example.com/demo.mp4"},"alt":"Demo"},
                {"type":"input_audio","input_audio":{"url":"https://example.com/input.m4a"},"transcript":"Question"},
                {"type":"error","code":"TOOL_WARNING","message":"One source failed","recoverable":true}
              ]
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()

        #expect(message.isUnfinished == true)
        #expect(message.finishReason == "tool_pause")
        #expect(message.content == [
            .summary(MessageSummaryContent(
                text: "Condensed result",
                tokenCount: 42,
                model: "m1",
                provider: "p1"
            )),
            .activity(MessageActivityContent(
                id: "phase-1",
                label: "Searching sources",
                status: "running",
                isPending: true,
                agentID: "agent-1"
            )),
            .tool(ToolCall(
                id: "call-1",
                name: "search",
                status: .completed,
                summary: #"{"result":"ok"}"#,
                input: #"{"q":"swift"}"#,
                output: #"{"result":"ok"}"#
            )),
            .video(URL(string: "https://example.com/demo.mp4")!, alternativeText: "Demo"),
            .audio(URL(string: "https://example.com/input.m4a")!, transcript: "Question"),
            .error(MessageErrorContent(
                code: "TOOL_WARNING",
                message: "One source failed",
                isRecoverable: true
            ))
        ])
    }

    @Test func localDraftConversationIDsAreUniqueButUseServerNewPlaceholder() {
        let first = ConversationID(localDraftID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = ConversationID(localDraftID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        #expect(first != second)
        #expect(first.isLocalDraft)
        #expect(second.isLocalDraft)
        #expect(first.serverValue == "new")
        #expect(ConversationID(rawValue: "server-conversation").serverValue == "server-conversation")
    }

    @Test func targetCatalogMapsCurrentEndpointModelsAndEnforcedSpecs() throws {
        let endpoints = try JSONDecoder().decode(JSONValue.self, from: Data(
            """
            {"openAI":{"order":0,"type":"openAI"},"agents":{"order":1,"type":"agents"},"muse":{"order":2,"type":"custom","modelDisplayLabel":"Muse"}}
            """.utf8
        ))
        let models = try JSONDecoder().decode(JSONValue.self, from: Data(
            """
            {"openAI":["gpt-4o"],"muse":["meta/muse-spark-1.2-contributor"]}
            """.utf8
        ))
        let startup = try JSONDecoder().decode(StartupConfigDTO.self, from: Data(
            """
            {"modelSpecs":{"enforce":true,"list":[{"name":"primary","label":"Primary agent","preset":{"endpoint":"agents","agent_id":"agent-1","model":"gpt-5"}}]}}
            """.utf8
        ))

        let enforced = TargetCatalogMapper().snapshot(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 0),
            baseURL: URL(string: "https://chat.example.com")!,
            endpoints: endpoints,
            models: models,
            startup: startup,
            agentDiscovery: .available([])
        ).options
        #expect(enforced.count == 1)
        #expect(enforced[0].target.agentID == "agent-1")
        #expect(enforced[0].target.spec == "primary")

        let direct = TargetCatalogMapper().options(endpoints: endpoints, models: models, startup: nil)
        #expect(direct.map(\.target.endpoint) == ["openAI", "muse"])
        #expect(direct.last?.target.endpointType == "custom")
        #expect(direct.last?.target.model == "meta/muse-spark-1.2-contributor")
    }

    @Test func savedAgentCatalogUsesOpaquePaginationAndFiltersInaccessibleAgentSpecs() throws {
        let page = try JSONDecoder().decode(AgentListResponseDTO.self, from: Data(
            """
            {
              "object":"list",
              "data":[{
                "id":"agent_visible","name":"Researcher","description":"Finds sources",
                "avatar":{"filepath":"/images/agent.png","source":"local"},
                "isPublic":true,"isEditable":false
              }],
              "first_id":"agent_visible","last_id":"agent_visible",
              "has_more":true,"after":"opaque==cursor"
            }
            """.utf8
        ))
        let saved = try page.data.map {
            try $0.targetOption(baseURL: URL(string: "https://chat.example.com")!)
        }
        let startup = try JSONDecoder().decode(StartupConfigDTO.self, from: Data(
            """
            {"modelSpecs":{"enforce":true,"list":[
              {"name":"visible","preset":{"endpoint":"agents","agent_id":"agent_visible"}},
              {"name":"hidden","preset":{"endpoint":"agents","agent_id":"agent_hidden"}}
            ]}}
            """.utf8
        ))

        let options = TargetCatalogMapper().snapshot(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 0),
            baseURL: URL(string: "https://chat.example.com")!,
            endpoints: .object(["agents": .object(["order": .number(0)])]),
            models: .object([:]),
            startup: startup,
            agentDiscovery: .available(saved)
        ).options

        #expect(page.hasMore)
        #expect(page.after == "opaque==cursor")
        #expect(options.map(\.id) == ["spec:visible"])
        #expect(saved[0].iconURL == URL(string: "https://chat.example.com/images/agent.png"))
        #expect(saved[0].target == ConversationTarget(endpoint: "agents", agentID: "agent_visible"))
    }
}
