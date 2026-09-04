import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class SkillsManagementPresentationTests: XCTestCase {
    func testOfflineLoadKeepsPrivateCatalogOutOfMemoryAndMakesNoRequest() async {
        let repository = SkillsManagementRepositoryDouble()
        let model = makeModel(repository: repository, offline: true)

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .offline)
        XCTAssertNil(model.catalog)
        let requests = await repository.catalogRequestCount
        XCTAssertEqual(requests, 0)
    }

    func testFreshCatalogSupportsNativeSearchAndActivationFilters() async {
        let catalog = makeCatalog(skills: [
            makeSkill(
                id: "507f1f77bcf86cd799439011",
                name: "document-review",
                title: "Document Review",
                description: "Review approved files",
                active: true,
                basis: .deploymentDefault
            ),
            makeSkill(
                id: "507f1f77bcf86cd799439012",
                name: "chart-maker",
                title: "Chart Maker",
                description: "Build visual summaries",
                active: false,
                basis: .inactiveDefault
            ),
        ])
        let repository = SkillsManagementRepositoryDouble(catalogResults: [.success(catalog)])
        let model = makeModel(repository: repository)

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.visibleSkills.map(\.displayTitle), ["Document Review", "Chart Maker"])
        model.filter = .inactive
        XCTAssertEqual(model.visibleSkills.map(\.displayTitle), ["Chart Maker"])
        model.filter = .all
        model.query = "approved"
        XCTAssertEqual(model.visibleSkills.map(\.displayTitle), ["Document Review"])
    }

    func testConfirmedMutationUsesReviewedScopeAndInstallsServerCatalog() async {
        let skill = makeSkill(
            id: "507f1f77bcf86cd799439011",
            name: "document-review",
            title: "Document Review",
            description: "Review files",
            active: false,
            basis: .inactiveDefault
        )
        let before = makeCatalog(skills: [skill])
        let after = makeCatalog(
            skills: [withActivation(skill, active: true, basis: .explicitOverride)],
            explicitStates: [skill.id: true]
        )
        let repository = SkillsManagementRepositoryDouble(
            catalogResults: [.success(before)],
            mutationResults: [.success(.confirmed(after))]
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        await model.setActive(true, for: skill)

        XCTAssertEqual(model.catalog, after)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertNil(model.operationError)
        let requests = await repository.mutationRequests
        XCTAssertEqual(requests, [SkillActivationRequest(
            profileID: before.profileID,
            accountID: before.accountID,
            skillID: skill.id,
            isActive: true
        )])
    }

    func testNotConfirmedShowsReconciledServerStateWithoutPostingAgain() async {
        let skill = makeSkill(
            id: "507f1f77bcf86cd799439011",
            name: "document-review",
            title: "Document Review",
            description: "Review files",
            active: false,
            basis: .inactiveDefault
        )
        let authoritative = makeCatalog(skills: [skill])
        let repository = SkillsManagementRepositoryDouble(
            catalogResults: [.success(authoritative)],
            mutationResults: [.success(.notConfirmed(authoritative))]
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        await model.setActive(true, for: skill)

        XCTAssertEqual(model.catalog, authoritative)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertNotNil(model.operationError)
        let mutationCount = await repository.mutationRequests.count
        XCTAssertEqual(mutationCount, 1)
    }

    func testUnknownOutcomeClearsCatalogAndRequiresAnExplicitReload() async {
        let skill = makeSkill(
            id: "507f1f77bcf86cd799439011",
            name: "document-review",
            title: "Document Review",
            description: "Review files",
            active: false,
            basis: .inactiveDefault
        )
        let before = makeCatalog(skills: [skill])
        let repository = SkillsManagementRepositoryDouble(
            catalogResults: [.success(before)],
            mutationResults: [.success(.outcomeUnknown(.reconciliationUnavailable))]
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        await model.setActive(true, for: skill)

        XCTAssertNil(model.catalog)
        guard case let .failed(message) = model.state else {
            return XCTFail("Expected a locked failure state")
        }
        XCTAssertTrue(message.contains("Reload"))
        XCTAssertFalse(model.canChange(skill))
    }

    func testUnauthorizedMutationHidesCatalogAndExpiresSession() async {
        let skill = makeSkill(
            id: "507f1f77bcf86cd799439011",
            name: "document-review",
            title: "Document Review",
            description: "Review files",
            active: false,
            basis: .inactiveDefault
        )
        let repository = SkillsManagementRepositoryDouble(
            catalogResults: [.success(makeCatalog(skills: [skill]))],
            mutationResults: [.failure(.unauthorized)]
        )
        var didExpire = false
        let model = makeModel(repository: repository) { didExpire = true }
        await model.loadIfNeeded()

        await model.setActive(true, for: skill)

        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertNil(model.catalog)
        XCTAssertTrue(didExpire)
    }

    func testPendingMutationAdmitsOnlyOneToggleUntilServerOutcomeReturns() async throws {
        let first = makeSkill(
            id: "507f1f77bcf86cd799439011",
            name: "document-review",
            title: "Document Review",
            description: "Review files",
            active: false,
            basis: .inactiveDefault
        )
        let second = makeSkill(
            id: "507f1f77bcf86cd799439012",
            name: "chart-maker",
            title: "Chart Maker",
            description: "Build charts",
            active: false,
            basis: .inactiveDefault
        )
        let before = makeCatalog(skills: [first, second])
        let after = makeCatalog(
            skills: [withActivation(first, active: true, basis: .explicitOverride), second],
            explicitStates: [first.id: true]
        )
        let repository = SkillsManagementRepositoryDouble(
            catalogResults: [.success(before)],
            mutationResults: [.success(.confirmed(after))],
            mutationDelay: .milliseconds(100)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let firstTask = Task { await model.setActive(true, for: first) }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNotNil(model.pendingMutation)
        await model.setActive(true, for: second)
        await firstTask.value

        let requests = await repository.mutationRequests
        XCTAssertEqual(requests.map(\.skillID), [first.id])
        XCTAssertEqual(model.catalog, after)
    }

    private func makeModel(
        repository: SkillsManagementRepositoryDouble,
        offline: Bool = false,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> SkillsManagementModel {
        SkillsManagementModel(
            repository: repository,
            isOffline: { offline },
            onUnauthorized: onUnauthorized
        )
    }

    private func makeCatalog(
        skills: [AccountSkillSummary],
        explicitStates: [SkillID: Bool] = [:]
    ) -> AccountSkillCatalog {
        AccountSkillCatalog(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            skills: skills,
            explicitStates: explicitStates,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            isComplete: true
        )
    }

    private func makeSkill(
        id: String,
        name: String,
        title: String,
        description: String,
        active: Bool,
        basis: AccountSkillActivationBasis
    ) -> AccountSkillSummary {
        AccountSkillSummary(
            id: SkillID(rawValue: id),
            name: name,
            displayTitle: title,
            description: description,
            source: .inline,
            version: 1,
            fileCount: 0,
            isActive: active,
            activationBasis: basis,
            isUserInvocable: true,
            canChangeActivation: true
        )
    }

    private func withActivation(
        _ skill: AccountSkillSummary,
        active: Bool,
        basis: AccountSkillActivationBasis
    ) -> AccountSkillSummary {
        var updated = skill
        updated.isActive = active
        updated.activationBasis = basis
        return updated
    }
}

private actor SkillsManagementRepositoryDouble: SkillRepository {
    private var catalogResults: [Result<AccountSkillCatalog, LibreChatProtocolError>]
    private var mutationResults: [Result<SkillActivationOutcome, LibreChatProtocolError>]
    private let mutationDelay: Duration
    private(set) var catalogRequestCount = 0
    private(set) var mutationRequests: [SkillActivationRequest] = []

    init(
        catalogResults: [Result<AccountSkillCatalog, LibreChatProtocolError>] = [],
        mutationResults: [Result<SkillActivationOutcome, LibreChatProtocolError>] = [],
        mutationDelay: Duration = .zero
    ) {
        self.catalogResults = catalogResults
        self.mutationResults = mutationResults
        self.mutationDelay = mutationDelay
    }

    func skillInvocationCatalog(for target: ConversationTarget) async throws -> SkillInvocationCatalog {
        throw SkillInvocationError.unavailable
    }

    func accountSkillCatalog() async throws -> AccountSkillCatalog {
        catalogRequestCount += 1
        guard !catalogResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try catalogResults.removeFirst().get()
    }

    func setSkillActivation(_ request: SkillActivationRequest) async throws -> SkillActivationOutcome {
        mutationRequests.append(request)
        if mutationDelay != .zero {
            try await Task.sleep(for: mutationDelay)
        }
        guard !mutationResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try mutationResults.removeFirst().get()
    }
}
