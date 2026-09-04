import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct PromptsContractTests {
    @Test func directoryMapsViewSafeProductionMetadataAndUnknownFields() throws {
        let data = Data(#"""
        {
          "promptGroups":[
            {
              "_id":"507f1f77bcf86cd799439011",
              "name":"  Weekly brief  ",
              "oneliner":"  Turn notes into a brief  ",
              "command":"brief",
              "category":"work",
              "productionPrompt":{"prompt":"  Summarize {{topic}}\n"},
              "author":"private-user-id",
              "authorName":"Editor",
              "isPublic":true,
              "numberOfGenerations":4,
              "future":{"ignored":true}
            }
          ],
          "has_more":true,
          "after":"opaque==cursor",
          "pages":"9999"
        }
        """#.utf8)
        let page = try JSONDecoder().decode(
            LibreChatPromptGroupPageDTO.self,
            from: data
        ).domainModel()
        let group = try #require(page.groups.first)

        #expect(group.id == PromptGroupID(rawValue: "507f1f77bcf86cd799439011"))
        #expect(group.name == "Weekly brief")
        #expect(group.summary == "Turn notes into a brief")
        #expect(group.productionText == "  Summarize {{topic}}\n")
        #expect(group.authorName == "Editor")
        #expect(group.isPublic)
        #expect(group.usageCount == 4)
        #expect(page.nextCursor == "opaque==cursor")
    }

    @Test func malformedGroupsAreDroppedButPaginationProofRemainsStrict() throws {
        let page = try JSONDecoder().decode(
            LibreChatPromptGroupPageDTO.self,
            from: Data(#"{"promptGroups":[{"_id":"../unsafe","name":"Bad"},{"_id":"507f1f77bcf86cd799439011","name":"Good"},{"_id":"507f1f77bcf86cd799439011","name":"Duplicate"}],"has_more":false,"after":"stale"}"#.utf8)
        ).domainModel()
        #expect(page.groups.map(\.name) == ["Good"])
        #expect(page.nextCursor == nil)

        #expect(throws: DTOMapperError.self) {
            try JSONDecoder().decode(
                LibreChatPromptGroupPageDTO.self,
                from: Data(#"{"promptGroups":[],"has_more":true,"after":null}"#.utf8)
            ).domainModel()
        }
    }

    @Test func listAndUsageFactoriesMatchPinnedACLContract() throws {
        let list = try LibreChatPromptsAPI.groups(PromptTemplateQuery(
            search: "  weekly brief  ",
            category: "  work  ",
            cursor: " opaque==cursor ",
            limit: 25
        ))
        #expect(list.method == .get)
        #expect(list.path == "api/prompts/groups")
        #expect(list.authorization == .bearer)
        #expect(list.queryItems == [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "name", value: "weekly brief"),
            URLQueryItem(name: "category", value: "work"),
            URLQueryItem(name: "cursor", value: "opaque==cursor"),
        ])
        #expect(list.retryPolicy == .idempotent(maximumAttempts: 2))

        let id = PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
        let usage = try LibreChatPromptsAPI.recordUsage(groupID: id)
        #expect(usage.method == .post)
        #expect(usage.pathComponents == ["api", "prompts", "groups", id.rawValue, "use"])
        #expect(usage.retryPolicy == .never)
        #expect(usage.body == nil)
    }

    @Test func requestValidationRejectsUnsafeIdentityAndOversizedQuery() {
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatPromptsAPI.recordUsage(
                groupID: PromptGroupID(rawValue: "../other")
            )
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatPromptsAPI.groups(PromptTemplateQuery(
                search: String(repeating: "x", count: 201)
            ))
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatPromptsAPI.groups(PromptTemplateQuery(limit: 0))
        }
    }

    @Test func variableExtractionPreservesOrderOptionsAndRepeatedIdentity() throws {
        let variables = try PromptTemplateExpander.variables(
            in: "For {{ topic }} use {{tone:formal|casual| custom }}. Reuse {{ topic }} at {{current_date}}."
        )
        #expect(variables == [
            PromptVariable(id: PromptVariableID(rawValue: " topic "), name: "topic"),
            PromptVariable(
                id: PromptVariableID(rawValue: "tone:formal|casual| custom "),
                name: "tone",
                options: ["formal", "casual", "custom"]
            ),
        ])
    }

    @Test func expansionResolvesSpecialAndUserVariablesWithoutReplacementInjection() throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-08-18T12:34:56Z"))
        let text = "{{current_user}} on {{current_date}}: {{topic}} / {{tone:formal|casual}}"
        let expanded = try PromptTemplateExpander.expand(
            text,
            values: [
                PromptVariableID(rawValue: "topic"): "$5 \\ path",
                PromptVariableID(rawValue: "tone:formal|casual"): "formal",
            ],
            userName: "Berry",
            now: instant,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(expanded == "Berry on 2026-08-18 (Tuesday): $5 \\ path / formal")

        #expect(throws: PromptExpansionError.missingValues([PromptVariableID(rawValue: "topic")])) {
            try PromptTemplateExpander.expand(
                "{{topic}}",
                values: [:],
                userName: nil
            )
        }
    }

    @Test func roleAndUsageAcknowledgementFailClosed() throws {
        let role = try JSONDecoder().decode(
            LibreChatRoleDTO.self,
            from: Data(#"{"permissions":{"PROMPTS":{"USE":true,"CREATE":false,"SHARE":true,"SHARE_PUBLIC":false}}}"#.utf8)
        )
        #expect(role.promptPermissions == PromptPermissions(
            use: true,
            create: false,
            share: true,
            sharePublicly: false
        ))
        let capabilities = LibreChatRoleCapabilityMapper.applying(
            role,
            to: ServerCapabilities()
        )
        #expect(capabilities.promptPermissions?.use == true)

        let usage = try JSONDecoder().decode(
            LibreChatPromptUsageDTO.self,
            from: Data(#"{"numberOfGenerations":9}"#.utf8)
        )
        #expect(try usage.count() == 9)
        let malformed = try JSONDecoder().decode(
            LibreChatPromptUsageDTO.self,
            from: Data(#"{"numberOfGenerations":-1}"#.utf8)
        )
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try malformed.count()
        }
    }

    @Test func managementDetailMapsExactProductionAndVersionCoordinates() throws {
        let group = try JSONDecoder().decode(
            LibreChatPromptGroupDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439011","name":"Template","oneliner":"Summary","category":"work","command":"weekly-brief","productionId":"507f1f77bcf86cd799439012","updatedAt":"2026-08-19T08:00:00.000Z","unknown":true}"#.utf8)
        ).managedDomainModel()
        let version = try JSONDecoder().decode(
            LibreChatPromptVersionDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439012","groupId":"507f1f77bcf86cd799439011","prompt":"Private exact text","type":"chat","createdAt":"2026-08-19T07:00:00Z","future":{"ignored":true}}"#.utf8)
        ).domainModel(expectedGroupID: group.id)

        #expect(group.productionVersionID == version.id)
        #expect(group.summary == "Summary")
        #expect(group.command == "weekly-brief")
        #expect(group.updatedAt != nil)
        #expect(version.kind == .chat)
        #expect(version.text == "Private exact text")
    }

    @Test func managementMappingRejectsMissingProductionAndCrossGroupVersions() throws {
        let missingProduction = try JSONDecoder().decode(
            LibreChatPromptGroupDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439011","name":"Template"}"#.utf8)
        )
        #expect(throws: DTOMapperError.self) {
            try missingProduction.managedDomainModel()
        }

        let version = try JSONDecoder().decode(
            LibreChatPromptVersionDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439012","groupId":"507f1f77bcf86cd799439099","prompt":"Text","type":"text"}"#.utf8)
        )
        #expect(throws: DTOMapperError.self) {
            try version.domainModel(
                expectedGroupID: PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
            )
        }
    }

    @Test func managementReadsUseExactACLProtectedRoutes() throws {
        let groupID = PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
        let group = try LibreChatPromptsAPI.group(groupID: groupID)
        #expect(group.method == .get)
        #expect(group.pathComponents == ["api", "prompts", "groups", groupID.rawValue])
        #expect(group.retryPolicy == .idempotent(maximumAttempts: 2))

        let versions = try LibreChatPromptsAPI.versions(groupID: groupID)
        #expect(versions.method == .get)
        #expect(versions.path == "api/prompts")
        #expect(versions.queryItems == [URLQueryItem(name: "groupId", value: groupID.rawValue)])
        #expect(versions.retryPolicy == .idempotent(maximumAttempts: 2))
        #expect(LibreChatPromptsAPI.myPromptsCategory == "sys__my__prompts__sys")
    }

    @Test func managementMutationFactoriesUseExactNeverRetryBodies() throws {
        let groupID = PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
        let versionID = PromptVersionID(rawValue: "507f1f77bcf86cd799439012")
        let create = try LibreChatPromptsAPI.create(CreatePromptGroupInput(
            name: " Template ",
            summary: " Summary ",
            category: " work ",
            command: "weekly-brief",
            text: " Exact text ",
            kind: .chat
        ))
        #expect(create.method == .post)
        #expect(create.path == "api/prompts")
        #expect(create.retryPolicy == .never)
        let createObject = try object(create.body)
        let prompt = try #require(createObject["prompt"] as? [String: Any])
        let group = try #require(createObject["group"] as? [String: Any])
        #expect(prompt["prompt"] as? String == "Exact text")
        #expect(prompt["type"] as? String == "chat")
        #expect(group["name"] as? String == "Template")
        #expect(group["command"] as? String == "weekly-brief")

        let add = try LibreChatPromptsAPI.addVersion(AddPromptVersionInput(
            groupID: groupID,
            text: "Second",
            kind: .text
        ))
        #expect(add.pathComponents == ["api", "prompts", "groups", groupID.rawValue, "prompts"])
        #expect(add.retryPolicy == .never)

        let update = try LibreChatPromptsAPI.updateGroup(UpdatePromptGroupInput(
            groupID: groupID,
            name: "Renamed",
            summary: "",
            category: "",
            command: nil
        ))
        #expect(update.method == .patch)
        #expect(update.retryPolicy == .never)
        let updateObject = try object(update.body)
        #expect(updateObject["name"] as? String == "Renamed")
        #expect(updateObject["oneliner"] as? String == "")
        #expect(updateObject["category"] as? String == "")
        #expect(updateObject["command"] is NSNull)

        let promote = try LibreChatPromptsAPI.promote(versionID: versionID)
        #expect(promote.pathComponents == ["api", "prompts", versionID.rawValue, "tags", "production"])
        #expect(promote.retryPolicy == .never)
        #expect(promote.body == nil)
    }

    @Test func managementValidationMatchesPinnedLimitsAndCommandGrammar() {
        #expect(throws: PromptManagementError.self) {
            try LibreChatPromptsAPI.create(CreatePromptGroupInput(name: "", text: "text"))
        }
        #expect(throws: PromptManagementError.self) {
            try LibreChatPromptsAPI.create(CreatePromptGroupInput(
                name: "Name",
                command: "Upper_Case",
                text: "text"
            ))
        }
        #expect(throws: PromptManagementError.self) {
            try LibreChatPromptsAPI.addVersion(AddPromptVersionInput(
                groupID: PromptGroupID(rawValue: "../unsafe"),
                text: "text",
                kind: .text
            ))
        }
        #expect(throws: PromptManagementError.self) {
            try LibreChatPromptsAPI.promote(
                versionID: PromptVersionID(rawValue: "../unsafe")
            )
        }
    }

    @Test func mutationErrorEnvelopesNeverMasqueradeAsCreatedResources() throws {
        let response = try JSONDecoder().decode(
            LibreChatPromptMutationResponseDTO.self,
            from: Data(#"{"message":"Error saving prompt"}"#.utf8)
        )
        #expect(response.prompt == nil)
        #expect(response.group == nil)
        #expect(response.message == "Error saving prompt")
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
