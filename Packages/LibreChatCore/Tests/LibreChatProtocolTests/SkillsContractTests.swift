import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct SkillsContractTests {
    private let a = "507f1f77bcf86cd799439011"
    private let b = "507f1f77bcf86cd799439012"

    @Test func listAndActiveFactoriesUseExactAuthenticatedRoutes() {
        let request = LibreChatSkillsAPI.list(category: " work ", search: "  review ", limit: 500, cursor: " next ")
        #expect(request.path == "api/skills")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
        #expect(request.queryItems == [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "category", value: "work"),
            URLQueryItem(name: "search", value: "review"),
            URLQueryItem(name: "cursor", value: "next")
        ])
        let states = LibreChatSkillsAPI.activeStates()
        #expect(states.path == "api/user/settings/skills/active")
        #expect(states.authorization == .bearer)
        #expect(states.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func activeStateMutationReplacesExactMapWithoutAutomaticRetry() throws {
        let request = try LibreChatSkillsAPI.updateActiveStates([a: true, b: false])

        #expect(request.method == .post)
        #expect(request.path == "api/user/settings/skills/active")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(LibreChatSkillStatesUpdateDTO.self, from: body)
        #expect(decoded.skillStates == [a: true, b: false])
    }

    @Test func activeStateMutationRejectsNonObjectIDAndOversizedMapsBeforeDispatch() {
        #expect(throws: SkillManagementError.self) {
            try LibreChatSkillsAPI.updateActiveStates(["deployment-skill": true])
        }
        let oversized = Dictionary(uniqueKeysWithValues: (0..<401).map { index in
            (String(format: "%024x", index), true)
        })
        #expect(throws: SkillManagementError.self) {
            try LibreChatSkillsAPI.updateActiveStates(oversized)
        }
    }

    @Test func pageAndStateDTOsIgnoreEvolvingFieldsAndMapRequiredMetadata() throws {
        let data = Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":" Review code ","displayTitle":"Review","source":"deployment","version":2,"fileCount":3,"userInvocable":true,"future":{"x":1}}],"has_more":true,"after":"opaque","future":true}"#.utf8)
        let page = try JSONDecoder().decode(LibreChatSkillPageDTO.self, from: data)
        #expect(page.hasMore == true)
        #expect(page.after == "opaque")
        let skill = try #require(page.skills.first).domainModel()
        #expect(skill.id == SkillID(rawValue: a))
        #expect(skill.name == "review-code")
        #expect(skill.displayTitle == "Review")
        #expect(skill.source == .deployment)
        let states = try JSONDecoder().decode(LibreChatSkillStatesDTO.self, from: Data(#"{"507f1f77bcf86cd799439011":false,"unknown":true}"#.utf8))
        #expect(states.states[a] == false)
        #expect(states.states["unknown"] == true)
    }

    @Test func summaryMappingRejectsWireTextBeyondServerBounds() throws {
        let valid = LibreChatSkillSummaryDTO(
            id: a,
            name: "review-code",
            displayTitle: String(repeating: "a", count: 128),
            description: String(repeating: "b", count: 1_024)
        )
        #expect(try valid.domainModel().displayTitle.utf16.count == 128)
        #expect(throws: DTOMapperError.self) {
            try LibreChatSkillSummaryDTO(
                id: a,
                name: "review-code",
                displayTitle: String(repeating: "a", count: 129),
                description: "Review"
            ).domainModel()
        }
        #expect(throws: DTOMapperError.self) {
            try LibreChatSkillSummaryDTO(
                id: a,
                name: "review-code",
                description: String(repeating: "b", count: 1_025)
            ).domainModel()
        }
    }

    @Test func modelSpecAndSavedAgentScopeControlAvailability() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(id: a, name: "review-code", description: "Review", author: "u", userInvocable: true),
            LibreChatSkillSummaryDTO(id: b, name: "write-tests", description: "Tests", author: "u", userInvocable: true)
        ])
        let target = ConversationTarget(endpoint: "agents", agentID: "agent_1", spec: "focused")
        let catalog = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"), accountID: AccountID(rawValue: "u"), target: target,
            page: page, activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, savedAgentScope: .identifiers([SkillID(rawValue: a)]))
        )
        #expect(catalog.skills[0].availability == .available)
        #expect(catalog.skills[1].availability == .excludedByTarget)

        let modelSpec = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"), accountID: AccountID(rawValue: "u"), target: target,
            page: page, activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, ephemeralScope: .names(["write-tests"]))
        )
        #expect(modelSpec.skills[0].availability == .excludedByTarget)
        #expect(modelSpec.skills[1].availability == .available)
    }

    @Test func activeStateAndUserInvocableGateSelection() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(id: a, name: "inactive", description: "Inactive", author: "u"),
            LibreChatSkillSummaryDTO(id: b, name: "model-only", description: "Model", author: "u", userInvocable: false)
        ])
        let target = ConversationTarget(endpoint: "agents", agentID: "agent_1")
        let catalog = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"), accountID: AccountID(rawValue: "u"), target: target,
            page: page, activeStates: LibreChatSkillStatesDTO(states: [a: false]),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, ephemeralScope: .all)
        )
        #expect(catalog.skills[0].availability == .inactive)
        #expect(catalog.skills[1].availability == .modelOnly)
        #expect(throws: SkillInvocationError.self) { try catalog.validatedSelection(["inactive"]) }
        #expect(throws: SkillInvocationError.self) { try catalog.validatedSelection(["model-only"]) }
    }

    @Test func duplicateInvocableNamesAreQuarantined() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(id: a, name: "same-name", description: "One", author: "u"),
            LibreChatSkillSummaryDTO(id: b, name: "same-name", description: "Two", author: "u")
        ])
        let catalog = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"), accountID: AccountID(rawValue: "u"),
            target: ConversationTarget(endpoint: "agents", agentID: "agent_1"), page: page,
            activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, ephemeralScope: .all)
        )
        #expect(catalog.skills.allSatisfy { $0.availability == .ambiguousName })
        #expect(throws: SkillInvocationError.self) { try catalog.validatedSelection(["same-name"]) }
    }

    @Test func selectionIsBoundedAndExact() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(id: a, name: "safe-name", description: "Safe", author: "u")
        ])
        let catalog = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"), accountID: AccountID(rawValue: "u"),
            target: ConversationTarget(endpoint: "agents", agentID: "agent_1"), page: page,
            activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, ephemeralScope: .all)
        )
        #expect(try catalog.validatedSelection(["safe-name"]) == ["safe-name"])
        #expect(throws: SkillInvocationError.self) { try catalog.validatedSelection(Array(repeating: "safe-name", count: 11)) }
        #expect(throws: SkillInvocationError.self) { try catalog.validatedSelection(["../unsafe"]) }
    }

    @Test func absentActiveOverrideUsesDeploymentOwnedAndSharedDefaults() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(
                id: a,
                name: "owned-skill",
                description: "Owned",
                author: "u"
            ),
            LibreChatSkillSummaryDTO(
                id: b,
                name: "shared-skill",
                description: "Shared",
                author: "someone-else"
            )
        ])
        let target = ConversationTarget(endpoint: "agents", agentID: "agent")
        let defaultOff = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"),
            accountID: AccountID(rawValue: "u"),
            target: target,
            page: page,
            activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, savedAgentScope: .all)
        )
        #expect(defaultOff.skills.map(\.availability) == [.available, .inactive])

        let defaultOn = try LibreChatSkillsMapper.catalog(
            profileID: ServerProfileID(rawValue: "p"),
            accountID: AccountID(rawValue: "u"),
            target: target,
            page: page,
            activeStates: LibreChatSkillStatesDTO(),
            scope: SkillInvocationTargetScope(capabilityEnabled: true, savedAgentScope: .all),
            sharedDefaultActive: true
        )
        #expect(defaultOn.skills.map(\.availability) == [.available, .available])
    }

    @Test func accountCatalogSeparatesExplicitAndServerDefaultActivation() throws {
        let deployment = "507f1f77bcf86cd799439013"
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(
                id: a,
                name: "owned-skill",
                description: "Owned",
                author: "u",
                userInvocable: true
            ),
            LibreChatSkillSummaryDTO(
                id: b,
                name: "shared-skill",
                description: "Shared",
                author: "someone-else",
                userInvocable: false
            ),
            LibreChatSkillSummaryDTO(
                id: deployment,
                name: "deployment-skill",
                description: "Deployment",
                source: "deployment"
            )
        ])

        let catalog = try LibreChatSkillsMapper.accountCatalog(
            profileID: ServerProfileID(rawValue: "p"),
            accountID: AccountID(rawValue: "u"),
            page: page,
            activeStates: LibreChatSkillStatesDTO(states: [a: false]),
            sharedDefaultActive: true
        )

        #expect(catalog.skills[0].isActive == false)
        #expect(catalog.skills[0].activationBasis == .explicitOverride)
        #expect(catalog.skills[1].isActive == true)
        #expect(catalog.skills[1].activationBasis == .sharedDefault)
        #expect(catalog.skills[1].isUserInvocable == false)
        #expect(catalog.skills[2].isActive == true)
        #expect(catalog.skills[2].activationBasis == .deploymentDefault)
        #expect(catalog.explicitStates == [SkillID(rawValue: a): false])
        #expect(catalog.skills.map(\.canChangeActivation) == [true, true, true])
    }

    @Test func accountCatalogFailsClosedForMalformedOrDuplicateStateIdentity() throws {
        let page = LibreChatSkillPageDTO(skills: [
            LibreChatSkillSummaryDTO(id: a, name: "one", description: "One"),
            LibreChatSkillSummaryDTO(id: a, name: "two", description: "Two")
        ])
        #expect(throws: SkillManagementError.self) {
            try LibreChatSkillsMapper.accountCatalog(
                profileID: ServerProfileID(rawValue: "p"),
                accountID: AccountID(rawValue: "u"),
                page: page,
                activeStates: LibreChatSkillStatesDTO()
            )
        }
        #expect(throws: SkillManagementError.self) {
            try LibreChatSkillsMapper.accountCatalog(
                profileID: ServerProfileID(rawValue: "p"),
                accountID: AccountID(rawValue: "u"),
                page: LibreChatSkillPageDTO(skills: [
                    LibreChatSkillSummaryDTO(id: a, name: "one", description: "One")
                ]),
                activeStates: LibreChatSkillStatesDTO(states: ["unsafe": true])
            )
        }
    }
}
