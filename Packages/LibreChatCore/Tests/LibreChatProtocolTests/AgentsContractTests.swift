import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct AgentsContractTests {
    @Test func listMapsOnlyStableViewMetadataAndIgnoresUnknownFields() throws {
        let data = Data(
            #"{"object":"list","data":[{"id":"agent_alpha","name":"Researcher","description":"  Finds evidence  ","category":"work","isPublic":true,"isEditable":false,"instructions":"must not escape"}],"has_more":true,"after":"opaque==cursor","future":{"x":1}}"#.utf8
        )
        let page = try JSONDecoder().decode(AgentListResponseDTO.self, from: data)
        let agent = try #require(page.data.first).summaryModel()
        #expect(agent.id == AgentID(rawValue: "agent_alpha"))
        #expect(agent.name == "Researcher")
        #expect(agent.description == "Finds evidence")
        #expect(agent.category == "work")
        #expect(agent.isPublic)
        #expect(!agent.canEdit)
        #expect(page.hasMore)
        #expect(page.after == "opaque==cursor")
    }

    @Test func viewDetailIsLossyForEvolvingOptionalFieldsButStrictForIdentity() throws {
        let data = Data(
            #"{"_id":"507f1f77bcf86cd799439011","id":"agent_alpha","name":"Researcher","description":"Evidence","conversation_starters":["  Find sources  ",""],"provider":"openai","model":"gpt-x","isPublic":true,"version":4,"model_parameters":{"temperature":0.2},"tools":["secret-to-view"]}"#.utf8
        )
        let detail = try JSONDecoder().decode(LibreChatAgentDetailDTO.self, from: data).domainModel()
        #expect(detail.id == AgentID(rawValue: "agent_alpha"))
        #expect(detail.resourceID == AgentResourceID(rawValue: "507f1f77bcf86cd799439011"))
        #expect(detail.conversationStarters == ["Find sources"])
        #expect(detail.provider == "openai")
        #expect(detail.model == "gpt-x")
        #expect(detail.isPublic)
        #expect(detail.version == 4)

        let evolving = try JSONDecoder().decode(
            LibreChatAgentDetailDTO.self,
            from: Data(#"{"id":"agent_beta","name":"Beta","conversation_starters":{"future":true},"version":"future"}"#.utf8)
        ).domainModel()
        #expect(evolving.conversationStarters.isEmpty)
        #expect(evolving.version == nil)
    }

    @Test func listUsesPinnedACLSearchAndCursorContract() {
        let request = LibreChatAgentsAPI.list(
            search: "  researcher  ",
            cursor: " opaque==cursor ",
            limit: 500
        )
        #expect(request.method == .get)
        #expect(request.path == "api/agents")
        #expect(request.queryItems == [
            URLQueryItem(name: "requiredPermission", value: "1"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "search", value: "researcher"),
            URLQueryItem(name: "cursor", value: "opaque==cursor")
        ])
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func detailRejectsUnsafePathIdentityBeforeTransport() throws {
        let request = try LibreChatAgentsAPI.detail(id: AgentID(rawValue: "agent_safe-1:test"))
        #expect(request.path == "api/agents/agent_safe-1:test")
        #expect(request.pathComponents == ["api", "agents", "agent_safe-1:test"])
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatAgentsAPI.detail(id: AgentID(rawValue: "../other-user"))
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatAgentsAPI.detail(id: AgentID(rawValue: "agent/other"))
        }
    }

    @Test func expandedMappingDropsSensitiveAgentConfiguration() throws {
        let dto = try JSONDecoder().decode(
            LibreChatAgentDetailDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439011","id":"agent_alpha","name":" Researcher ","description":" Evidence ","category":" work ","isPublic":true,"version":8,"instructions":"private","tools":["secret"],"actions":[{"api_key":"secret"}],"model_parameters":{"api_key":"secret"}}"#.utf8)
        )
        let metadata = try dto.managedDomainModel()
        #expect(metadata == ManagedAgentMetadata(
            id: AgentID(rawValue: "agent_alpha"),
            resourceID: AgentResourceID(rawValue: "507f1f77bcf86cd799439011"),
            name: "Researcher",
            description: "Evidence",
            category: "work",
            isPublic: true,
            version: 8
        ))
    }

    @Test func metadataMutationUsesExactPatchBodyAndNeverRetries() throws {
        let input = AgentMetadataUpdateInput(
            agentID: AgentID(rawValue: "agent_alpha"),
            name: "  Renamed  ",
            description: "  ",
            category: " Research "
        )
        let request = try LibreChatAgentsAPI.updateMetadata(input)
        #expect(request.method == .patch)
        #expect(request.pathComponents == ["api", "agents", "agent_alpha"])
        #expect(request.retryPolicy == .never)
        let body = try #require(request.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object == [
            "name": "Renamed",
            "description": "",
            "category": "Research"
        ])

        #expect(throws: AgentManagementError.invalidInput("Enter an agent name between 1 and 1,000 characters.")) {
            try LibreChatAgentsAPI.updateMetadata(AgentMetadataUpdateInput(
                agentID: input.agentID,
                name: " ",
                description: "",
                category: ""
            ))
        }
    }

    @Test func duplicateUsesExactOneShotServerRouteAndMapsNewEditableIdentity() throws {
        let request = try LibreChatAgentsAPI.duplicate(id: AgentID(rawValue: "agent_alpha"))
        #expect(request.method == .post)
        #expect(request.pathComponents == ["api", "agents", "agent_alpha", "duplicate"])
        #expect(request.body == nil)
        #expect(request.retryPolicy == .never)

        let response = try JSONDecoder().decode(
            LibreChatAgentDuplicateResponseDTO.self,
            from: Data(#"{"agent":{"id":"agent_copy","name":"Researcher copy","category":"work"},"actions":[{"metadata":{"future":true}}]}"#.utf8)
        )
        let copy = try #require(response.agent).summaryModel(canEdit: true)
        #expect(copy.id == AgentID(rawValue: "agent_copy"))
        #expect(copy.canEdit)
        #expect(copy.category == "work")
    }

    @Test func effectivePermissionsUseExactAgentRouteAndKnownBitProjection() throws {
        let id = AgentResourceID(rawValue: "507f1f77bcf86cd799439011")
        let request = try LibreChatAgentsAPI.effectivePermissions(resourceID: id)
        #expect(request.method == .get)
        #expect(request.pathComponents == ["api", "permissions", "agent", id.rawValue, "effective"])
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))

        let permissions = try JSONDecoder().decode(
            LibreChatAgentEffectivePermissionsDTO.self,
            from: Data(#"{"permissionBits":15,"future":true}"#.utf8)
        ).domainModel()
        #expect(permissions == AgentResourcePermissions(
            canView: true,
            canEdit: true,
            canDelete: true,
            canShare: true
        ))
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try LibreChatAgentEffectivePermissionsDTO(permissionBits: -1).domainModel()
        }
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try LibreChatAgentEffectivePermissionsDTO().domainModel()
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatAgentsAPI.effectivePermissions(
                resourceID: AgentResourceID(rawValue: "agent_alpha")
            )
        }
    }

    @Test func deletionUsesExactNonRetriedRouteAndRequiresPinnedAcknowledgement() throws {
        let id = AgentID(rawValue: "agent_alpha")
        let request = try LibreChatAgentsAPI.delete(id: id)
        #expect(request.method == .delete)
        #expect(request.pathComponents == ["api", "agents", id.rawValue])
        #expect(request.retryPolicy == .never)
        #expect(request.body == nil)
        #expect(LibreChatAgentDeletionResponseDTO(message: "Agent deleted").confirmsDeletion())
        #expect(!LibreChatAgentDeletionResponseDTO(message: "Deleted").confirmsDeletion())
    }

    @Test func versionHistoryPreservesRawServerIndicesWhileDroppingSensitiveConfiguration() throws {
        let dto = try JSONDecoder().decode(
            LibreChatAgentVersionsDTO.self,
            from: Data(
                #"[{"name":" First ","description":" Safe summary ","category":" work ","createdAt":"2026-08-19T09:10:11.123Z","instructions":"private","tools":["secret"],"actions":[{"api_key":"secret"}]},"malformed",{"name":"Third","updatedAt":"2026-08-19T10:11:12Z","model_parameters":{"api_key":"secret"}}]"#.utf8
            )
        )
        let agentID = AgentID(rawValue: "agent_alpha")
        let fetchedAt = Date(timeIntervalSince1970: 123)
        let history = dto.domainModel(agentID: agentID, fetchedAt: fetchedAt)

        #expect(history.agentID == agentID)
        #expect(history.fetchedAt == fetchedAt)
        #expect(history.versions.count == 3)
        #expect(history.versions.map(\.coordinate.serverIndex) == [0, 1, 2])
        #expect(history.versions[0].name == "First")
        #expect(history.versions[0].description == "Safe summary")
        #expect(history.versions[0].category == "work")
        #expect(history.versions[0].createdAt != nil)
        #expect(!history.versions[1].isRestorable)
        #expect(history.versions[1].name == nil)
        #expect(history.versions[2].name == "Third")
        #expect(history.versions[2].updatedAt != nil)
    }

    @Test func versionReadAndRevertUseExactPinnedRoutesAndOneShotMutation() throws {
        let agentID = AgentID(rawValue: "agent_alpha")
        let read = try LibreChatAgentsAPI.versions(id: agentID)
        #expect(read.method == .get)
        #expect(read.pathComponents == ["api", "agents", "agent_alpha", "versions"])
        #expect(read.retryPolicy == .idempotent(maximumAttempts: 2))

        let coordinate = AgentVersionCoordinate(agentID: agentID, serverIndex: 7)
        let revert = try LibreChatAgentsAPI.revert(coordinate)
        #expect(revert.method == .post)
        #expect(revert.pathComponents == ["api", "agents", "agent_alpha", "revert"])
        #expect(revert.retryPolicy == .never)
        let body = try #require(revert.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Int])
        #expect(object == ["version_index": 7])

        #expect(throws: AgentManagementError.self) {
            try LibreChatAgentsAPI.revert(
                AgentVersionCoordinate(agentID: agentID, serverIndex: -1)
            )
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatAgentsAPI.versions(id: AgentID(rawValue: "../unsafe"))
        }
    }

    @Test func basicCreationFetchesFreshScopedModelEvidence() throws {
        let request = LibreChatAgentsAPI.modelsForBasicCreation()
        #expect(request.method == .get)
        #expect(request.path == "api/models")
        #expect(request.pathComponents == ["api", "models"])
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))

        let dto = try JSONDecoder().decode(
            LibreChatAgentModelCatalogDTO.self,
            from: Data(#"{"openAI":["gpt-safe","gpt-safe",17],"bad\nprovider":["skip"],"custom":["model-1"],"future":{"models":["skip"]}}"#.utf8)
        )
        let catalog = dto.basicAgentCreationCatalog(
            profileID: ServerProfileID(rawValue: "profile-1"),
            accountID: AccountID(rawValue: "account-1")
        )
        #expect(catalog.modelsByProvider == [
            "openAI": ["gpt-safe"],
            "custom": ["model-1"]
        ])

        let basic = BasicAgentCreationRequest(
            profileID: ServerProfileID(rawValue: "profile-1"),
            accountID: AccountID(rawValue: "account-1"),
            name: "Research partner",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe")
        )
        #expect(try basic.validated(in: catalog).reviewedModel.provider == "openAI")

        let differentAccount = BasicAgentModelCatalog(
            profileID: catalog.profileID,
            accountID: AccountID(rawValue: "account-2"),
            modelsByProvider: catalog.modelsByProvider
        )
        #expect(throws: BasicAgentCreationError.reviewedScopeMismatch) {
            try basic.validated(in: differentAccount)
        }
        let stale = BasicAgentModelCatalog(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            modelsByProvider: ["openAI": ["gpt-replaced"]]
        )
        #expect(throws: BasicAgentCreationError.reviewedModelUnavailable) {
            try basic.validated(in: stale)
        }
    }

    @Test func basicCreationUsesOnlyAllowlistedBodyAndNeverRetries() throws {
        let catalog = BasicAgentModelCatalog(
            profileID: ServerProfileID(rawValue: "profile-1"),
            accountID: AccountID(rawValue: "account-1"),
            modelsByProvider: ["openAI": ["gpt-safe"]]
        )
        let request = BasicAgentCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            name: "Research partner",
            description: "  Finds cited answers.  ",
            instructions: "  Use primary sources.\nState uncertainty.  ",
            category: "  Work  ",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe"),
            modelParameters: BasicAgentModelParameters(
                temperature: 0.2,
                topP: 0.9,
                maxTokens: 4_096
            )
        )
        let apiRequest = try LibreChatAgentsAPI.createBasic(request, validatingAgainst: catalog)
        #expect(apiRequest.method == .post)
        #expect(apiRequest.path == "api/agents")
        #expect(apiRequest.pathComponents == ["api", "agents"])
        #expect(apiRequest.retryPolicy == .never)
        let data = try #require(apiRequest.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == [
            "name", "description", "instructions", "provider", "model",
            "model_parameters", "tools", "category"
        ])
        #expect(body["name"] as? String == "Research partner")
        #expect(body["description"] as? String == "Finds cited answers.")
        #expect(body["instructions"] as? String == "Use primary sources.\nState uncertainty.")
        #expect(body["provider"] as? String == "openAI")
        #expect(body["model"] as? String == "gpt-safe")
        #expect(body["category"] as? String == "Work")
        #expect((body["tools"] as? [Any])?.isEmpty == true)
        let parameters = try #require(body["model_parameters"] as? [String: Any])
        #expect(parameters["temperature"] as? Double == 0.2)
        #expect(parameters["top_p"] as? Double == 0.9)
        #expect(parameters["max_tokens"] as? Int == 4_096)
        for forbidden in [
            "avatar", "tool_resources", "edges", "subagents", "skills",
            "actions", "mcp", "mcpServers", "files", "file_ids", "metadata",
            "agent_ids", "memory_scope", "tool_options"
        ] {
            #expect(body[forbidden] == nil)
        }
    }

    @Test func basicCreationFailsClosedForUnsafeInputOrUnavailableFreshModel() {
        let catalog = BasicAgentModelCatalog(
            profileID: ServerProfileID(rawValue: "profile-1"),
            accountID: AccountID(rawValue: "account-1"),
            modelsByProvider: ["openAI": ["gpt-safe"]]
        )
        let blankName = BasicAgentCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            name: " ",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe")
        )
        #expect(throws: BasicAgentCreationError.invalidName) {
            try LibreChatAgentsAPI.createBasic(blankName, validatingAgainst: catalog)
        }
        let unsafeParameters = BasicAgentCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            name: "Safe",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe"),
            modelParameters: BasicAgentModelParameters(temperature: 2.1)
        )
        #expect(throws: BasicAgentCreationError.invalidModelParameters) {
            try LibreChatAgentsAPI.createBasic(unsafeParameters, validatingAgainst: catalog)
        }
        let unavailable = BasicAgentCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            name: "Safe",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-removed")
        )
        #expect(throws: BasicAgentCreationError.reviewedModelUnavailable) {
            try LibreChatAgentsAPI.createBasic(unavailable, validatingAgainst: catalog)
        }
    }

    @Test func basicCreationRequiresExact201GeneratedIdentityAndEcho() throws {
        let catalog = BasicAgentModelCatalog(
            profileID: ServerProfileID(rawValue: "profile-1"),
            accountID: AccountID(rawValue: "account-1"),
            modelsByProvider: ["openAI": ["gpt-safe"]]
        )
        let request = BasicAgentCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            name: "Research partner",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe")
        )
        let response = LibreChatBasicAgentCreationResponseDTO(
            id: "agent_created-1",
            mongoID: "507f1f77bcf86cd799439011",
            name: "Research partner",
            provider: "openAI",
            model: "gpt-safe"
        )
        let outcome = try LibreChatAgentsAPI.confirmedBasicCreation(
            from: response,
            statusCode: 201,
            for: request,
            validatingAgainst: catalog
        )
        #expect(outcome == .confirmed(BasicAgentCreationResult(
            agentID: AgentID(rawValue: "agent_created-1"),
            resourceID: AgentResourceID(rawValue: "507f1f77bcf86cd799439011"),
            name: "Research partner",
            provider: "openAI",
            model: "gpt-safe"
        )))
        #expect(throws: BasicAgentCreationError.invalidResponse) {
            try LibreChatAgentsAPI.confirmedBasicCreation(
                from: response,
                statusCode: 200,
                for: request,
                validatingAgainst: catalog
            )
        }
        #expect(throws: BasicAgentCreationError.invalidResponse) {
            try LibreChatAgentsAPI.confirmedBasicCreation(
                from: LibreChatBasicAgentCreationResponseDTO(
                    id: "agent_created-1",
                    mongoID: "not-a-resource-id",
                    name: "Research partner",
                    provider: "openAI",
                    model: "gpt-safe"
                ),
                statusCode: 201,
                for: request,
                validatingAgainst: catalog
            )
        }

        let unknown: BasicAgentCreationOutcome = .outcomeUnknown(.responseLostAfterDispatch)
        #expect(unknown == .outcomeUnknown(.responseLostAfterDispatch))
    }
}
