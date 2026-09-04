import Foundation
import LibreChatDomain
import SwiftData
import XCTest
@testable import LibreChat

@MainActor
final class FollowUpQueuePersistenceTests: XCTestCase {
    func testV1StoreMigratesThenQueueJournalReopensWithoutLosingLegacyData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatQueueMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "cache.store")
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let profile = ServerProfile(
            id: profileID,
            baseURL: try XCTUnwrap(URL(string: "https://chat.example.com")),
            displayName: "Legacy",
            accountIdentifier: accountID
        )

        let legacySchema = Schema(versionedSchema: CacheSchemaV1.self)
        let legacyConfiguration = ModelConfiguration(
            "LibreChatCache",
            schema: legacySchema,
            url: storeURL
        )
        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [legacyConfiguration]
        )
        let legacyContext = try XCTUnwrap(legacyContainer).mainContext
        legacyContext.insert(ServerProfileRecord(profile: profile))
        legacyContext.insert(AccountRecord(
            profileID: profileID,
            account: UserAccount(id: accountID)
        ))
        legacyContext.insert(DraftRecord(
            namespace: CacheNamespace.key(profileID: profileID, accountID: accountID),
            conversationID: conversationID,
            text: "Preserve me"
        ))
        let legacyHandle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000090")!,
            streamID: "legacy-stream",
            conversationID: conversationID,
            generationCreatedAt: 900,
            protocolVersion: 2
        )
        let legacyRecovery = GenerationSnapshot(handle: legacyHandle, state: .completed)
        legacyContext.insert(GenerationRecoveryRecord(
            namespace: CacheNamespace.key(profileID: profileID, accountID: accountID),
            snapshot: legacyRecovery
        ))
        try legacyContext.save()
        legacyContainer = nil

        var migrated: AppDependencies? = try AppDependencies(storeURL: storeURL)
        let migratedDraft = try await migrated?.cache.draft(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(migratedDraft, "Preserve me")
        let migratedContext = try XCTUnwrap(migrated).modelContainer.mainContext
        let migratedRecoveryRecords = try migratedContext.fetch(
            FetchDescriptor<GenerationRecoveryRecord>()
        )
        let migratedRecovery = try XCTUnwrap(migratedRecoveryRecords.first)
        XCTAssertTrue(migratedRecovery.isTerminal)
        XCTAssertEqual(
            try JSONDecoder().decode(GenerationSnapshot.self, from: migratedRecovery.snapshot),
            legacyRecovery
        )

        let snapshot = try makeSnapshot(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        try await migrated?.cache.saveFollowUpQueue(snapshot)
        migrated = nil

        let reopened = try AppDependencies(storeURL: storeURL)
        let recovered = try await reopened.cache.followUpQueue(namespace: snapshot.namespace)
        XCTAssertEqual(recovered, snapshot)
        let reopenedDraft = try await reopened.cache.draft(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(reopenedDraft, "Preserve me")
    }

    func testCorruptQueueJournalFailsClosedInsteadOfAppearingEmpty() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let cache = dependencies.cache
        let snapshot = try makeSnapshot()
        try await cache.saveFollowUpQueue(snapshot)

        let context = ModelContext(dependencies.modelContainer)
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>())
        let record = try XCTUnwrap(records.first)
        record.snapshot = Data("not-json".utf8)
        try context.save()

        do {
            _ = try await dependencies.cache.followUpQueue(namespace: snapshot.namespace)
            XCTFail("A corrupt reservation journal must never become an empty queue")
        } catch let error as FollowUpQueuePersistenceError {
            XCTAssertEqual(error, .corruptRecord)
        }
    }

    func testCorruptQueueRecordKeyCannotHideAnExistingJournal() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let snapshot = try makeSnapshot()
        try await dependencies.cache.saveFollowUpQueue(snapshot)

        let context = ModelContext(dependencies.modelContainer)
        let record = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FollowUpQueueRecord>()).first
        )
        record.recordKey = "corrupt-hidden-key"
        try context.save()

        do {
            _ = try await dependencies.cache.followUpQueue(namespace: snapshot.namespace)
            XCTFail("A corrupted key must not make an existing journal appear empty")
        } catch let error as FollowUpQueuePersistenceError {
            XCTAssertEqual(error, .corruptRecord)
        }
    }

    func testQueueJournalIsAccountIsolatedAndPurgedWithItsNamespace() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let first = try makeSnapshot(accountID: AccountID(rawValue: "first"))
        let sibling = try makeSnapshot(accountID: AccountID(rawValue: "sibling"))
        try await dependencies.cache.saveAccount(
            profileID: first.namespace.profileID,
            account: UserAccount(id: first.namespace.accountID)
        )
        try await dependencies.cache.saveAccount(
            profileID: sibling.namespace.profileID,
            account: UserAccount(id: sibling.namespace.accountID)
        )
        try await dependencies.cache.saveFollowUpQueue(first)
        try await dependencies.cache.saveFollowUpQueue(sibling)

        try await dependencies.cache.purge(
            profileID: first.namespace.profileID,
            accountID: first.namespace.accountID
        )

        let removed = try await dependencies.cache.followUpQueue(namespace: first.namespace)
        let retained = try await dependencies.cache.followUpQueue(namespace: sibling.namespace)
        XCTAssertTrue(removed.items.isEmpty)
        XCTAssertEqual(retained, sibling)
    }

    func testQueueNamespaceDiscoveryIsExactAccountScopedAndDeterministicallySorted() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let later = try makeSnapshot(
            profileID: profileID,
            accountID: accountID,
            conversationID: ConversationID(rawValue: "conversation-z")
        )
        let earlier = try makeSnapshot(
            profileID: profileID,
            accountID: accountID,
            conversationID: ConversationID(rawValue: "conversation-a")
        )
        let foreignAccount = try makeSnapshot(
            profileID: profileID,
            accountID: AccountID(rawValue: "other-account"),
            conversationID: ConversationID(rawValue: "conversation-foreign")
        )
        try await dependencies.cache.saveFollowUpQueue(later)
        try await dependencies.cache.saveFollowUpQueue(foreignAccount)
        try await dependencies.cache.saveFollowUpQueue(earlier)

        let discovered = try await dependencies.cache.followUpQueueNamespaces(
            profileID: profileID,
            accountID: accountID
        )

        XCTAssertEqual(discovered, [earlier.namespace, later.namespace])
    }

    func testQueueNamespaceDiscoveryFailsClosedWhenAnyOwnedSiblingIsCorrupt() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let first = try makeSnapshot(
            conversationID: ConversationID(rawValue: "conversation-a")
        )
        let second = try makeSnapshot(
            conversationID: ConversationID(rawValue: "conversation-b")
        )
        try await dependencies.cache.saveFollowUpQueue(first)
        try await dependencies.cache.saveFollowUpQueue(second)

        let context = ModelContext(dependencies.modelContainer)
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>())
        let corrupt = try XCTUnwrap(records.first(where: {
            $0.conversationID == second.namespace.conversationID.rawValue
        }))
        corrupt.snapshot = Data("corrupt".utf8)
        try context.save()

        do {
            _ = try await dependencies.cache.followUpQueueNamespaces(
                profileID: first.namespace.profileID,
                accountID: first.namespace.accountID
            )
            XCTFail("A corrupt sibling journal must stop namespace discovery")
        } catch let error as FollowUpQueuePersistenceError {
            XCTAssertEqual(error, .corruptRecord)
        }
    }

    func testConcurrentPersistedReserveTriggersCommitExactlyOneAttempt() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let cache = dependencies.cache
        let snapshot = try makeSnapshot()
        try await cache.saveFollowUpQueue(snapshot)
        let sourceHandle = snapshot.items[0].sourceAnchor.handle
        let signal = FollowUpGenerationSignal.completed(
            handle: sourceHandle,
            responseMessageID: MessageID(rawValue: "finished-assistant")
        )

        let reservedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let result = try? await cache.mutateFollowUpQueue(
                        namespace: snapshot.namespace
                    ) { reducer in
                        try reducer.reserveNext(
                            after: signal,
                            attemptID: UUID(),
                            clientRequestID: UUID(),
                            clientMessageID: MessageID(rawValue: "queued-user-\(index)")
                        )
                    }
                    return result?.result != nil
                }
            }
            var count = 0
            for await reserved in group where reserved { count += 1 }
            return count
        }

        XCTAssertEqual(reservedCount, 1)
        let persisted = try await cache.followUpQueue(namespace: snapshot.namespace)
        let activeStates = persisted.items.filter { item in
            if case .reserved = item.state { return true }
            return false
        }
        XCTAssertEqual(activeStates.count, 1)
    }

    private func makeSnapshot(
        profileID: ServerProfileID = ServerProfileID(rawValue: "profile"),
        accountID: AccountID = AccountID(rawValue: "account"),
        conversationID: ConversationID = ConversationID(rawValue: "conversation")
    ) throws -> FollowUpQueueSnapshot {
        let namespace = try FollowUpQueueNamespace(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: 1_000,
            protocolVersion: 2
        )
        let item = try FollowUpQueueItem(
            id: FollowUpQueueItemID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000082")!
            ),
            namespace: namespace,
            order: FollowUpQueueOrder(rawValue: 1),
            text: "Follow up",
            target: FollowUpTargetFingerprint(
                endpoint: "agents",
                agentID: "agent"
            ),
            sourceAnchor: FollowUpSourceAnchor(
                handle: handle,
                sourceUserMessageID: MessageID(rawValue: "source-user")
            )
        )
        return try FollowUpQueueSnapshot(namespace: namespace, items: [item])
    }
}
