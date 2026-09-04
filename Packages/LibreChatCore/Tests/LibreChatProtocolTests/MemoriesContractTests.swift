import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct MemoriesContractTests {
    @Test func listMapsPersonalAndAgentPartitionsWithoutLeakingUnknownFields() throws {
        let data = Data(#"""
        {
          "memories":[
            {"key":"timezone","value":"Europe/Rome","updated_at":"2026-08-18T12:00:00.000Z","tokenCount":4,"future":"ignored"},
            {"key":"tone","value":"Concise","agentId":"agent_safe-1","agentName":"Writer","tokenCount":2}
          ],
          "totalTokens":4,"tokenLimit":1000,"charLimit":12000,"usagePercentage":1,"future":true
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(
            LibreChatMemoriesResponseDTO.self,
            from: data
        ).domainModel()

        #expect(snapshot.memories.count == 2)
        #expect(snapshot.memories[0].id == UserMemoryID(key: "timezone"))
        #expect(snapshot.memories[0].updatedAt != nil)
        #expect(snapshot.memories[1].agentID == AgentID(rawValue: "agent_safe-1"))
        #expect(snapshot.memories[1].agentName == "Writer")
        #expect(snapshot.totalTokens == 4)
        #expect(snapshot.tokenLimit == 1000)
        #expect(snapshot.characterLimit == 12000)
        #expect(snapshot.usagePercentage == 1)
    }

    @Test func malformedIdentityAndUsageFailClosedWhileDuplicateRowsDoNotMultiply() throws {
        let duplicate = try JSONDecoder().decode(
            LibreChatMemoriesResponseDTO.self,
            from: Data(#"{"memories":[{"key":"tone","value":"One"},{"key":"tone","value":"Two"}],"totalTokens":0}"#.utf8)
        ).domainModel()
        #expect(duplicate.memories.map(\.value) == ["One"])

        #expect(throws: DTOMapperError.invalidField("memory.agentId")) {
            try JSONDecoder().decode(
                LibreChatMemoryDTO.self,
                from: Data(#"{"key":"x","value":"y","agentId":"../private"}"#.utf8)
            ).domainModel()
        }
        #expect(throws: DTOMapperError.self) {
            try JSONDecoder().decode(
                LibreChatMemoriesResponseDTO.self,
                from: Data(#"{"memories":[],"totalTokens":0,"usagePercentage":101}"#.utf8)
            ).domainModel()
        }
    }

    @Test func factoriesUseExactAuthenticatedRoutesEncodedKeysAndNeverRetry() throws {
        let create = try LibreChatMemoriesAPI.create(
            CreateMemoryInput(key: "  preferred tone  ", value: "  concise  "),
            characterLimit: 100
        )
        #expect(create.method == .post)
        #expect(create.path == "api/memories")
        #expect(create.authorization == .bearer)
        #expect(create.retryPolicy == .never)
        let encodedCreateBody = try #require(create.body)
        let createBody = try #require(
            JSONSerialization.jsonObject(with: encodedCreateBody) as? [String: Any]
        )
        #expect(createBody["key"] as? String == "preferred tone")
        #expect(createBody["value"] as? String == "concise")
        #expect(createBody["agentId"] == nil)

        let input = UpdateMemoryInput(
            originalKey: " old/key % ",
            key: "new key",
            value: "new value",
            agentID: AgentID(rawValue: "agent_safe")
        )
        let update = try LibreChatMemoriesAPI.update(input, characterLimit: 100)
        #expect(update.method == .patch)
        #expect(update.pathComponents == ["api", "memories", " old/key % "])
        #expect(update.queryItems == [URLQueryItem(name: "agentId", value: "agent_safe")])
        #expect(update.retryPolicy == .never)

        let delete = try LibreChatMemoriesAPI.delete(
            DeleteMemoryInput(key: " old/key % ", agentID: AgentID(rawValue: "agent_safe"))
        )
        #expect(delete.method == .delete)
        #expect(delete.pathComponents == ["api", "memories", " old/key % "])
        #expect(delete.retryPolicy == .never)

        let preference = try LibreChatMemoriesAPI.setEnabled(false)
        #expect(preference.method == .patch)
        #expect(preference.path == "api/memories/preferences")
        #expect(preference.retryPolicy == .never)
    }

    @Test func mutationValidationUsesServerUTF16LimitsAndSafeAgentCoordinates() {
        #expect(throws: MemoryMutationError.invalidKey) {
            try LibreChatMemoriesAPI.create(
                CreateMemoryInput(key: " ", value: "value"),
                characterLimit: 10
            )
        }
        #expect(throws: MemoryMutationError.valueTooLong(limit: 2)) {
            try LibreChatMemoriesAPI.create(
                CreateMemoryInput(key: "key", value: "😀😀"),
                characterLimit: 2
            )
        }
        #expect(throws: MemoryMutationError.invalidAgent) {
            try LibreChatMemoriesAPI.delete(
                DeleteMemoryInput(key: "key", agentID: AgentID(rawValue: "agent/foreign"))
            )
        }
    }

    @Test func acknowledgementsRequireExplicitSuccessFlagsAndTypedPayloads() throws {
        let created = try JSONDecoder().decode(
            LibreChatMemoryMutationDTO.self,
            from: Data(#"{"created":true,"memory":{"key":"tone","value":"concise"}}"#.utf8)
        )
        #expect(try created.createdMemory().key == "tone")

        let malformed = try JSONDecoder().decode(
            LibreChatMemoryMutationDTO.self,
            from: Data(#"{"created":false,"memory":{"key":"tone","value":"concise"}}"#.utf8)
        )
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try malformed.createdMemory()
        }

        let preference = try JSONDecoder().decode(
            LibreChatMemoryPreferenceDTO.self,
            from: Data(#"{"updated":true,"preferences":{"memories":false}}"#.utf8)
        )
        #expect(try preference.enabledValue() == false)
    }

    @Test func roleAndUserContractsPreserveMemoryPolicyWithLegacyDefaults() throws {
        let role = try JSONDecoder().decode(
            LibreChatRoleDTO.self,
            from: Data(#"{"permissions":{"MEMORIES":{"USE":true,"READ":true,"CREATE":false,"UPDATE":true,"OPT_OUT":false}}}"#.utf8)
        )
        #expect(role.memoryPermissions == MemoryPermissions(
            use: true,
            create: false,
            update: true,
            read: true,
            optOut: false
        ))
        let capabilities = LibreChatRoleCapabilityMapper.applying(
            role,
            to: ServerCapabilities(supportsMemories: true)
        )
        #expect(capabilities.memoryPermissions?.canRead == true)
        #expect(capabilities.memoryPermissions?.canCreate == false)

        let user = try JSONDecoder().decode(
            LibreChatUserDTO.self,
            from: Data(#"{"id":"user-1","personalization":{"memories":false}}"#.utf8)
        ).domainModel()
        #expect(user.memoriesEnabled == false)

        let legacy = try JSONDecoder().decode(
            UserAccount.self,
            from: Data(#"{"id":"user-2"}"#.utf8)
        )
        #expect(legacy.memoriesEnabled == nil)
    }
}
