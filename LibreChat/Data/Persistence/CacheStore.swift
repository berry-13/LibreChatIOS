import Foundation
import LibreChatDomain
import OSLog
import SwiftData

enum CacheSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ServerProfileRecord.self,
            AccountRecord.self,
            ConversationRecord.self,
            MessageRecord.self,
            DraftRecord.self,
            GenerationRecoveryRecord.self,
            PendingInteractionRecord.self,
            UploadRecord.self,
            ConfigurationSnapshotRecord.self
        ]
    }
}

/// V2 adds a dedicated, transactional follow-up queue journal. Existing V1
/// model layouts remain untouched so deployed stores can migrate without
/// reinterpreting conversation, draft, upload, or generation records.
enum CacheSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        CacheSchemaV1.models + [FollowUpQueueRecord.self]
    }
}

enum CacheMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CacheSchemaV1.self, CacheSchemaV2.self] }
    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: CacheSchemaV1.self,
                toVersion: CacheSchemaV2.self
            )
        ]
    }
}

@Model
final class ServerProfileRecord {
    @Attribute(.unique) var profileID: String
    var baseURL: String
    var displayName: String
    var accountID: String?
    var capabilities: Data?
    var trustPolicy: String
    var lastSelectedAt: Date?

    init(profile: ServerProfile, lastSelectedAt: Date? = nil) {
        profileID = profile.id.rawValue
        baseURL = profile.baseURL.absoluteString
        displayName = profile.displayName
        accountID = profile.accountIdentifier?.rawValue
        capabilities = profile.capabilities.flatMap { try? JSONEncoder().encode($0) }
        trustPolicy = profile.trustPolicy.rawValue
        self.lastSelectedAt = lastSelectedAt
    }

    func domainModel() -> ServerProfile? {
        guard let url = URL(string: baseURL) else { return nil }
        return ServerProfile(
            id: ServerProfileID(rawValue: profileID),
            baseURL: url,
            displayName: displayName,
            accountIdentifier: accountID.map(AccountID.init(rawValue:)),
            capabilities: capabilities.flatMap { try? JSONDecoder().decode(ServerCapabilities.self, from: $0) },
            trustPolicy: ServerTrustPolicy(rawValue: trustPolicy) ?? .system
        )
    }
}

@Model
final class AccountRecord {
    @Attribute(.unique) var namespace: String
    var profileID: String
    var accountID: String
    var account: Data
    var lastVerifiedAt: Date
    var cacheVisible: Bool

    init(profileID: ServerProfileID, account: UserAccount, lastVerifiedAt: Date = Date(), cacheVisible: Bool = true) {
        namespace = CacheNamespace.key(profileID: profileID, accountID: account.id)
        self.profileID = profileID.rawValue
        self.accountID = account.id.rawValue
        self.account = (try? JSONEncoder().encode(account)) ?? Data()
        self.lastVerifiedAt = lastVerifiedAt
        self.cacheVisible = cacheVisible
    }
}

@Model
final class ConversationRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var conversationID: String
    var conversation: Data
    var title: String
    var updatedAt: Date?
    var fetchedAt: Date

    init(namespace: String, conversation: LibreChatDomain.Conversation, fetchedAt: Date) {
        recordKey = "\(namespace)|conversation|\(conversation.id.rawValue)"
        self.namespace = namespace
        conversationID = conversation.id.rawValue
        self.conversation = (try? JSONEncoder().encode(conversation)) ?? Data()
        title = conversation.title
        updatedAt = conversation.updatedAt
        self.fetchedAt = fetchedAt
    }
}

@Model
final class MessageRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var conversationID: String
    var messageID: String
    var message: Data
    var createdAt: Date?
    var ordinal: Int
    var fetchedAt: Date

    init(namespace: String, message: ChatMessage, ordinal: Int, fetchedAt: Date) {
        recordKey = "\(namespace)|message|\(message.id.rawValue)"
        self.namespace = namespace
        conversationID = message.conversationID.rawValue
        messageID = message.id.rawValue
        self.message = (try? JSONEncoder().encode(message)) ?? Data()
        createdAt = message.createdAt
        self.ordinal = ordinal
        self.fetchedAt = fetchedAt
    }

    init(
        namespace: String,
        conversationID: ConversationID,
        snapshotData: Data,
        fetchedAt: Date
    ) {
        recordKey = "\(namespace)|messagesnapshot|\(conversationID.rawValue)"
        self.namespace = namespace
        self.conversationID = conversationID.rawValue
        messageID = ""
        message = snapshotData
        createdAt = nil
        ordinal = 0
        self.fetchedAt = fetchedAt
    }
}

@Model
final class DraftRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var conversationID: String
    var text: String
    var updatedAt: Date

    init(namespace: String, conversationID: ConversationID, text: String, updatedAt: Date = Date()) {
        recordKey = "\(namespace)|draft|\(conversationID.rawValue)"
        self.namespace = namespace
        self.conversationID = conversationID.rawValue
        self.text = text
        self.updatedAt = updatedAt
    }
}

@Model
final class GenerationRecoveryRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var streamID: String
    var snapshot: Data
    /// This column is part of the original on-device V1 schema and must remain
    /// present even though recovery reads independently decode `snapshot.state`.
    /// Removing it changes the V1 model checksum and prevents deployed stores
    /// from reaching the V1 -> V2 migration stage.
    var isTerminal: Bool
    var checkpointedAt: Date

    init(namespace: String, snapshot: GenerationSnapshot) {
        recordKey = GenerationRecoveryRecord.currentKey(namespace: namespace, handle: snapshot.handle)
        self.namespace = namespace
        streamID = snapshot.handle.streamID
        self.snapshot = (try? JSONEncoder().encode(snapshot)) ?? Data()
        isTerminal = snapshot.state.isTerminal
        checkpointedAt = snapshot.updatedAt
    }

    static func currentKey(namespace: String, handle: GenerationHandle) -> String {
        let epoch = handle.generationCreatedAt.map(String.init) ?? "nil"
        return "\(namespace)|generation-v2|\(handle.streamID)|\(handle.conversationID.rawValue)|\(epoch)|\(handle.protocolVersion)|\(handle.clientRequestID.uuidString)"
    }
}

@Model
final class PendingInteractionRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var streamID: String
    var interaction: Data
    var updatedAt: Date

    init(namespace: String, streamID: String, interaction: PendingInteraction, updatedAt: Date = Date()) {
        recordKey = "\(namespace)|interaction|\(streamID)"
        self.namespace = namespace
        self.streamID = streamID
        self.interaction = (try? JSONEncoder().encode(interaction)) ?? Data()
        self.updatedAt = updatedAt
    }
}

@Model
final class UploadRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var uploadID: String
    var upload: Data
    var updatedAt: Date

    init(namespace: String, upload: PendingUpload, updatedAt: Date = Date()) {
        recordKey = "\(namespace)|upload|\(upload.id.uuidString)"
        self.namespace = namespace
        uploadID = upload.id.uuidString
        self.upload = (try? JSONEncoder().encode(upload)) ?? Data()
        self.updatedAt = updatedAt
    }
}

@Model
final class ConfigurationSnapshotRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var kind: String
    var payload: Data
    var fetchedAt: Date

    init(namespace: String, kind: String, payload: Data, fetchedAt: Date = Date()) {
        recordKey = "\(namespace)|configuration|\(kind)"
        self.namespace = namespace
        self.kind = kind
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

@Model
final class FollowUpQueueRecord {
    @Attribute(.unique) var recordKey: String
    var namespace: String
    var conversationID: String
    var snapshot: Data
    var updatedAt: Date

    init(namespace: String, snapshot: FollowUpQueueSnapshot, updatedAt: Date = Date()) {
        recordKey = Self.key(namespace: namespace, conversationID: snapshot.namespace.conversationID)
        self.namespace = namespace
        conversationID = snapshot.namespace.conversationID.rawValue
        self.snapshot = (try? JSONEncoder().encode(snapshot)) ?? Data()
        self.updatedAt = updatedAt
    }

    static func key(namespace: String, conversationID: ConversationID) -> String {
        "\(namespace)|follow-up-queue-v2|\(conversationID.rawValue)"
    }
}

enum FollowUpQueuePersistenceError: Error, Equatable, Sendable {
    case contextMismatch
    case corruptRecord
}

enum CacheNamespace {
    static func key(profileID: ServerProfileID, accountID: AccountID) -> String {
        "\(profileID.rawValue)|\(accountID.rawValue)"
    }
}

/// A small account-scoped preference stored inside the existing configuration
/// snapshot payload. Keeping this out of `ConfigurationSnapshotRecord`'s
/// columns preserves the already-shipped SwiftData V1 schema.
struct RecentChatTargetPreference: Codable, Equatable, Sendable {
    let optionID: String
    let selectedAt: Date
}

enum RecentChatTargetPreferenceError: Error, Equatable {
    case invalidOptionID
}

/// Stable payload for the account-scoped manual TTS choice. The surrounding
/// configuration record provides namespace isolation and purge behavior
/// without changing the shipped SwiftData schema.
private struct SpeechSynthesisVoicePreferencePayload: Codable, Equatable, Sendable {
    let usesServerDefault: Bool
    let voiceID: String?
    let selectedAt: Date
}

enum SpeechSynthesisVoicePreferencePersistenceError: Error, Equatable {
    case invalidVoiceID
}

actor CacheCoordinator: GenerationCheckpointStore {
    private static let recentChatTargetKind = "recent-chat-target-v1"
    private static let speechSynthesisVoiceKind = "speech-synthesis-voice-v1"
    private static let messageDecoder = JSONDecoder()
    private static let messageEncoder = JSONEncoder()

    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func profiles() throws -> [ServerProfile] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ServerProfileRecord>(
            sortBy: [SortDescriptor(\.lastSelectedAt, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).compactMap { $0.domainModel() }
    }

    func save(profile: ServerProfile, selected: Bool = false) throws {
        let context = ModelContext(container)
        let id = profile.id.rawValue
        let descriptor = FetchDescriptor<ServerProfileRecord>(predicate: #Predicate { $0.profileID == id })
        if let record = try context.fetch(descriptor).first {
            record.baseURL = profile.baseURL.absoluteString
            record.displayName = profile.displayName
            record.accountID = profile.accountIdentifier?.rawValue
            record.capabilities = profile.capabilities.flatMap { try? JSONEncoder().encode($0) }
            record.trustPolicy = profile.trustPolicy.rawValue
            if selected { record.lastSelectedAt = Date() }
        } else {
            context.insert(ServerProfileRecord(profile: profile, lastSelectedAt: selected ? Date() : nil))
        }
        try context.save()
    }

    func remove(profileID: ServerProfileID) throws {
        try purge(profileID: profileID)
        let context = ModelContext(container)
        let id = profileID.rawValue
        try context.fetch(FetchDescriptor<ServerProfileRecord>(predicate: #Predicate { $0.profileID == id }))
            .forEach(context.delete)
        try context.save()
    }

    func saveAccount(profileID: ServerProfileID, account: UserAccount, visible: Bool = true) throws {
        let context = ModelContext(container)
        let key = CacheNamespace.key(profileID: profileID, accountID: account.id)
        let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.namespace == key })
        if let record = try context.fetch(descriptor).first {
            record.account = try JSONEncoder().encode(account)
            record.lastVerifiedAt = Date()
            record.cacheVisible = visible
        } else {
            context.insert(AccountRecord(profileID: profileID, account: account, cacheVisible: visible))
        }
        try context.save()
    }

    func lastVerifiedAccount(
        profileID: ServerProfileID,
        accountID: AccountID? = nil
    ) throws -> UserAccount? {
        let context = ModelContext(container)
        let id = profileID.rawValue
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate { $0.profileID == id && $0.cacheVisible },
            sortBy: [SortDescriptor(\.lastVerifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = accountID == nil ? 1 : nil
        let records = try context.fetch(descriptor)
        let record = if let accountID {
            records.first { $0.accountID == accountID.rawValue }
        } else {
            records.first
        }
        guard let record,
              let account = try? JSONDecoder().decode(UserAccount.self, from: record.account),
              account.id.rawValue == record.accountID else { return nil }
        return account
    }

    func setCacheVisible(_ visible: Bool, profileID: ServerProfileID, accountID: AccountID) throws {
        let context = ModelContext(container)
        let key = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.namespace == key })
        try context.fetch(descriptor).forEach { $0.cacheVisible = visible }
        try context.save()
    }

    func conversations(profileID: ServerProfileID, accountID: AccountID, limit: Int) throws -> ConversationPage? {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let records = try context.fetch(descriptor)
        guard !records.isEmpty else { return nil }
        let conversations = records.compactMap { try? JSONDecoder().decode(LibreChatDomain.Conversation.self, from: $0.conversation) }
        return ConversationPage(
            conversations: conversations,
            fetchedAt: records.map(\.fetchedAt).max() ?? .distantPast,
            isFromCache: true
        )
    }

    func save(
        page: ConversationPage,
        profileID: ServerProfileID,
        accountID: AccountID,
        completeSynchronization: Bool
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let existing = try context.fetch(FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.namespace == namespace }))
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.conversationID, $0) })
        for conversation in page.conversations {
            if let record = byID[conversation.id.rawValue] {
                record.conversation = try JSONEncoder().encode(conversation)
                record.title = conversation.title
                record.updatedAt = conversation.updatedAt
                record.fetchedAt = page.fetchedAt
            } else {
                context.insert(ConversationRecord(namespace: namespace, conversation: conversation, fetchedAt: page.fetchedAt))
            }
        }
        if completeSynchronization {
            let received = Set(page.conversations.map { $0.id.rawValue })
            existing.filter { !received.contains($0.conversationID) }.forEach(context.delete)
        }
        try context.save()
    }

    /// Removes an archived conversation from the active conversation index
    /// while retaining its message, draft, upload, and recovery records.
    func removeConversationFromActiveList(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let id = conversationID.rawValue
        try context.fetch(FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == id }
        )).forEach(context.delete)
        try context.save()
    }

    /// Mirrors LibreChat's project deletion side effect without treating a
    /// partial conversation page as an authoritative deletion boundary.
    func clearProjectMembership(
        projectID: ProjectID,
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let records = try context.fetch(FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        var changed = false
        for record in records {
            guard var conversation = try? JSONDecoder().decode(
                LibreChatDomain.Conversation.self,
                from: record.conversation
            ), conversation.projectID == projectID else { continue }
            conversation.projectID = nil
            record.conversation = try JSONEncoder().encode(conversation)
            changed = true
        }
        if changed { try context.save() }
    }

    func updateConversationTags(
        _ tags: [String],
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let id = conversationID.rawValue
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == id }
        )
        guard let record = try context.fetch(descriptor).first,
              var conversation = try? JSONDecoder().decode(
                LibreChatDomain.Conversation.self,
                from: record.conversation
              ) else { return }
        conversation.tags = tags
        record.conversation = try JSONEncoder().encode(conversation)
        try context.save()
    }

    func messages(profileID: ServerProfileID, accountID: AccountID, conversationID: ConversationID) throws -> [ChatMessage] {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let conversation = conversationID.rawValue
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation },
            sortBy: [SortDescriptor(\.ordinal)]
        )
        let records = try context.fetch(descriptor)
        // The wholesale snapshot decodes as one payload, which keeps first
        // paint fast on long conversations. Legacy per-message rows keep
        // their row-by-row read until the next save rewrites the snapshot.
        if records.count == 1,
           let snapshot = try? Self.messageDecoder.decode([ChatMessage].self, from: records[0].message) {
            return snapshot
        }
        return try records.compactMap { try? Self.messageDecoder.decode(ChatMessage.self, from: $0.message) }
    }

    func save(messages: [ChatMessage], profileID: ServerProfileID, accountID: AccountID, conversationID: ConversationID) throws {
        let saveStart = Date()
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let conversation = conversationID.rawValue
        let existing = try context.fetch(FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        ))
        existing.forEach(context.delete)
        let now = Date()
        // One wholesale snapshot record: this cache is only ever rewritten as
        // a whole (the save above deletes every row first), and decoding one
        // payload on open is several times faster than per-message rows.
        context.insert(MessageRecord(
            namespace: namespace,
            conversationID: conversationID,
            snapshotData: (try? Self.messageEncoder.encode(messages)) ?? Data(),
            fetchedAt: now
        ))
        try context.save()
        if messages.count >= 500 || Date().timeIntervalSince(saveStart) > 0.25 {
            AppLog.perf.debug(
                "chat-cache-save ms=\(Int(Date().timeIntervalSince(saveStart) * 1000)) count=\(messages.count)"
            )
        }
    }

    func deleteConversation(profileID: ServerProfileID, accountID: AccountID, conversationID: ConversationID) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let conversation = conversationID.rawValue
        try context.fetch(FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<DraftRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)

        var generationStreamIDs = Set([conversation])
        let generations = try context.fetch(FetchDescriptor<GenerationRecoveryRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        for record in generations {
            guard let snapshot = try? JSONDecoder().decode(GenerationSnapshot.self, from: record.snapshot),
                  snapshot.handle.conversationID == conversationID else { continue }
            generationStreamIDs.insert(snapshot.handle.streamID)
            context.delete(record)
        }
        try context.fetch(FetchDescriptor<PendingInteractionRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        .filter { generationStreamIDs.contains($0.streamID) }
        .forEach(context.delete)

        let uploads = try context.fetch(FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        for record in uploads {
            guard let upload = try? JSONDecoder().decode(PendingUpload.self, from: record.upload),
                  upload.conversationID == conversationID else { continue }
            try? FileManager.default.removeItem(at: upload.localURL)
            context.delete(record)
        }
        try context.save()
    }

    /// Removes local recovery and transcript material for a server-owned
    /// Temporary Chat. This is intentionally namespace-exact and does not
    /// delete the remote conversation; LibreChat remains authoritative for
    /// its retention deadline.
    func purgeTemporaryConversationContent(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let conversation = conversationID.rawValue
        try context.fetch(FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<DraftRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)
        try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.conversationID == conversation }
        )).forEach(context.delete)

        var streamIDs = Set([conversation])
        let generations = try context.fetch(FetchDescriptor<GenerationRecoveryRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        for record in generations {
            guard let snapshot = try? JSONDecoder().decode(GenerationSnapshot.self, from: record.snapshot),
                  snapshot.handle.conversationID == conversationID else { continue }
            streamIDs.insert(snapshot.handle.streamID)
            context.delete(record)
        }
        try context.fetch(FetchDescriptor<PendingInteractionRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        .filter { streamIDs.contains($0.streamID) }
        .forEach(context.delete)

        let uploads = try context.fetch(FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        for record in uploads {
            guard let upload = try? JSONDecoder().decode(PendingUpload.self, from: record.upload),
                  upload.conversationID == conversationID else { continue }
            try? FileManager.default.removeItem(at: upload.localURL)
            context.delete(record)
        }
        try context.save()
    }

    func completeConversationSynchronization(
        profileID: ServerProfileID,
        accountID: AccountID,
        receivedIDs: Set<ConversationID>
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let received = Set(receivedIDs.map(\.rawValue))
        try context.fetch(FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.namespace == namespace }
        ))
        .filter { !received.contains($0.conversationID) }
        .forEach(context.delete)
        try context.save()
    }

    func draft(profileID: ServerProfileID, accountID: AccountID, conversationID: ConversationID) throws -> String {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let key = "\(namespace)|draft|\(conversationID.rawValue)"
        return try context.fetch(FetchDescriptor<DraftRecord>(predicate: #Predicate { $0.recordKey == key })).first?.text ?? ""
    }

    func saveDraft(_ text: String, profileID: ServerProfileID, accountID: AccountID, conversationID: ConversationID) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let key = "\(namespace)|draft|\(conversationID.rawValue)"
        let descriptor = FetchDescriptor<DraftRecord>(predicate: #Predicate { $0.recordKey == key })
        if let record = try context.fetch(descriptor).first {
            record.text = text
            record.updatedAt = Date()
        } else {
            context.insert(DraftRecord(namespace: namespace, conversationID: conversationID, text: text))
        }
        try context.save()
    }

    func recentChatTargetOptionID(
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws -> String? {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let kind = Self.recentChatTargetKind
        let descriptor = FetchDescriptor<ConfigurationSnapshotRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.kind == kind }
        )
        guard let record = try context.fetch(descriptor).first,
              let preference = try? JSONDecoder().decode(
                RecentChatTargetPreference.self,
                from: record.payload
              ), Self.isValidTargetOptionID(preference.optionID) else {
            return nil
        }
        return preference.optionID
    }

    func saveRecentChatTargetOptionID(
        _ optionID: String,
        profileID: ServerProfileID,
        accountID: AccountID,
        selectedAt: Date = Date()
    ) throws {
        guard Self.isValidTargetOptionID(optionID) else {
            throw RecentChatTargetPreferenceError.invalidOptionID
        }
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let kind = Self.recentChatTargetKind
        let payload = try JSONEncoder().encode(RecentChatTargetPreference(
            optionID: optionID,
            selectedAt: selectedAt
        ))
        let descriptor = FetchDescriptor<ConfigurationSnapshotRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.kind == kind }
        )
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
            record.fetchedAt = selectedAt
        } else {
            context.insert(ConfigurationSnapshotRecord(
                namespace: namespace,
                kind: kind,
                payload: payload,
                fetchedAt: selectedAt
            ))
        }
        try context.save()
    }

    func speechSynthesisVoicePreference(
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws -> SpeechSynthesisVoicePreference? {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let kind = Self.speechSynthesisVoiceKind
        let descriptor = FetchDescriptor<ConfigurationSnapshotRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.kind == kind }
        )
        guard let record = try context.fetch(descriptor).first,
              let payload = try? JSONDecoder().decode(
                SpeechSynthesisVoicePreferencePayload.self,
                from: record.payload
              ) else {
            return nil
        }

        if payload.usesServerDefault {
            guard payload.voiceID == nil else { return nil }
            return .serverDefault
        }
        guard let voiceID = payload.voiceID,
              Self.isValidSpeechSynthesisVoiceID(voiceID) else {
            return nil
        }
        return .specific(SpeechSynthesisVoice(id: voiceID))
    }

    func saveSpeechSynthesisVoicePreference(
        _ preference: SpeechSynthesisVoicePreference,
        profileID: ServerProfileID,
        accountID: AccountID,
        selectedAt: Date = Date()
    ) throws {
        let payload: SpeechSynthesisVoicePreferencePayload
        switch preference {
        case .serverDefault:
            payload = SpeechSynthesisVoicePreferencePayload(
                usesServerDefault: true,
                voiceID: nil,
                selectedAt: selectedAt
            )
        case let .specific(voice):
            guard Self.isValidSpeechSynthesisVoiceID(voice.id) else {
                throw SpeechSynthesisVoicePreferencePersistenceError.invalidVoiceID
            }
            payload = SpeechSynthesisVoicePreferencePayload(
                usesServerDefault: false,
                voiceID: voice.id,
                selectedAt: selectedAt
            )
        }

        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let kind = Self.speechSynthesisVoiceKind
        let data = try JSONEncoder().encode(payload)
        let descriptor = FetchDescriptor<ConfigurationSnapshotRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.kind == kind }
        )
        if let record = try context.fetch(descriptor).first {
            record.payload = data
            record.fetchedAt = selectedAt
        } else {
            context.insert(ConfigurationSnapshotRecord(
                namespace: namespace,
                kind: kind,
                payload: data,
                fetchedAt: selectedAt
            ))
        }
        try context.save()
    }

    /// Reads one atomic queue journal for an exact server/account/chat. A
    /// corrupt record is never treated as an empty queue because doing so
    /// could silently discard a reserved or delivery-uncertain submission.
    func followUpQueue(
        namespace: FollowUpQueueNamespace
    ) throws -> FollowUpQueueSnapshot {
        let context = ModelContext(container)
        let cacheNamespace = CacheNamespace.key(
            profileID: namespace.profileID,
            accountID: namespace.accountID
        )
        let key = FollowUpQueueRecord.key(
            namespace: cacheNamespace,
            conversationID: namespace.conversationID
        )
        let conversationID = namespace.conversationID.rawValue
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate {
                $0.namespace == cacheNamespace && $0.conversationID == conversationID
            }
        ))
        guard let record = records.first else {
            return try FollowUpQueueSnapshot(namespace: namespace)
        }
        guard records.count == 1,
              record.recordKey == key,
              record.namespace == cacheNamespace,
              record.conversationID == conversationID,
              let snapshot = try? JSONDecoder().decode(
                FollowUpQueueSnapshot.self,
                from: record.snapshot
              ), snapshot.namespace == namespace else {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        return snapshot
    }

    /// Discovers every durable queue journal owned by one exact authenticated
    /// profile/account. Every row is decoded and key-verified before any
    /// namespace is returned; a corrupt sibling must not be silently skipped
    /// because it may contain the only copy of an uncertain admission.
    func followUpQueueNamespaces(
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws -> [FollowUpQueueNamespace] {
        let context = ModelContext(container)
        let cacheNamespace = CacheNamespace.key(
            profileID: profileID,
            accountID: accountID
        )
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate { $0.namespace == cacheNamespace }
        ))
        var namespaces: [FollowUpQueueNamespace] = []
        namespaces.reserveCapacity(records.count)
        for record in records {
            guard let snapshot = try? JSONDecoder().decode(
                FollowUpQueueSnapshot.self,
                from: record.snapshot
            ),
                  snapshot.namespace.profileID == profileID,
                  snapshot.namespace.accountID == accountID,
                  snapshot.namespace.conversationID.rawValue == record.conversationID,
                  !snapshot.items.isEmpty,
                  record.recordKey == FollowUpQueueRecord.key(
                    namespace: cacheNamespace,
                    conversationID: snapshot.namespace.conversationID
                  ) else {
                throw FollowUpQueuePersistenceError.corruptRecord
            }
            namespaces.append(snapshot.namespace)
        }
        guard Set(namespaces.map(\.conversationID)).count == namespaces.count else {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        return namespaces.sorted {
            $0.conversationID.rawValue < $1.conversationID.rawValue
        }
    }

    /// Replaces the entire per-conversation journal in one SwiftData save.
    /// Reservation state and its byte-stable request fingerprint therefore
    /// survive crashes together rather than as independently written rows.
    func saveFollowUpQueue(_ snapshot: FollowUpQueueSnapshot) throws {
        let context = ModelContext(container)
        let cacheNamespace = CacheNamespace.key(
            profileID: snapshot.namespace.profileID,
            accountID: snapshot.namespace.accountID
        )
        let key = FollowUpQueueRecord.key(
            namespace: cacheNamespace,
            conversationID: snapshot.namespace.conversationID
        )
        let conversationID = snapshot.namespace.conversationID.rawValue
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate {
                $0.namespace == cacheNamespace && $0.conversationID == conversationID
            }
        ))
        guard records.count <= 1 else {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        if let record = records.first, record.recordKey != key {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        if snapshot.items.isEmpty {
            records.forEach(context.delete)
            try context.save()
            return
        }
        let payload = try JSONEncoder().encode(snapshot)
        guard let verified = try? JSONDecoder().decode(
            FollowUpQueueSnapshot.self,
            from: payload
        ), verified == snapshot else {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        if let record = records.first {
            guard record.namespace == cacheNamespace,
                  record.conversationID == snapshot.namespace.conversationID.rawValue else {
                throw FollowUpQueuePersistenceError.contextMismatch
            }
            record.snapshot = payload
            record.updatedAt = Date()
        } else {
            context.insert(FollowUpQueueRecord(
                namespace: cacheNamespace,
                snapshot: snapshot
            ))
        }
        try context.save()
    }

    func removeFollowUpQueue(namespace: FollowUpQueueNamespace) throws {
        let context = ModelContext(container)
        let cacheNamespace = CacheNamespace.key(
            profileID: namespace.profileID,
            accountID: namespace.accountID
        )
        let key = FollowUpQueueRecord.key(
            namespace: cacheNamespace,
            conversationID: namespace.conversationID
        )
        let conversationID = namespace.conversationID.rawValue
        let records = try context.fetch(FetchDescriptor<FollowUpQueueRecord>(
            predicate: #Predicate {
                $0.namespace == cacheNamespace && $0.conversationID == conversationID
            }
        ))
        guard records.count <= 1,
              records.first?.recordKey == key || records.isEmpty else {
            throw FollowUpQueuePersistenceError.corruptRecord
        }
        records.forEach(context.delete)
        try context.save()
    }

    /// Performs one reducer transition and its journal replacement in the
    /// same non-suspending cache-actor turn. Foreground, connectivity, and
    /// terminal callbacks therefore cannot reserve two attempts from the same
    /// persisted queue snapshot.
    func mutateFollowUpQueue<Result: Sendable>(
        namespace: FollowUpQueueNamespace,
        _ mutation: @Sendable (inout FollowUpQueueReducer) throws -> Result
    ) throws -> (result: Result, snapshot: FollowUpQueueSnapshot) {
        let current = try followUpQueue(namespace: namespace)
        var reducer = FollowUpQueueReducer(snapshot: current)
        let result = try mutation(&reducer)
        try saveFollowUpQueue(reducer.snapshot)
        return (result, reducer.snapshot)
    }

    private static func isValidTargetOptionID(_ optionID: String) -> Bool {
        !optionID.isEmpty
            && optionID.utf16.count <= 2_048
            && optionID == optionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidSpeechSynthesisVoiceID(_ voiceID: String) -> Bool {
        !voiceID.isEmpty
            && voiceID.utf16.count <= 256
            && voiceID.caseInsensitiveCompare("ALL") != .orderedSame
            && voiceID == voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            && voiceID.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    func save(_ snapshot: GenerationSnapshot) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: snapshot.handle.profileID, accountID: snapshot.handle.accountID)
        let matches = try exactGenerationRecords(
            context: context,
            namespace: namespace,
            handle: snapshot.handle
        )
        if let record = matches.first {
            record.snapshot = try JSONEncoder().encode(snapshot)
            record.isTerminal = snapshot.state.isTerminal
            record.checkpointedAt = snapshot.updatedAt
            for duplicate in matches.dropFirst() { context.delete(duplicate) }
        } else {
            let key = GenerationRecoveryRecord.currentKey(namespace: namespace, handle: snapshot.handle)
            let keyCollision = try context.fetch(FetchDescriptor<GenerationRecoveryRecord>(
                predicate: #Predicate { $0.recordKey == key }
            ))
            guard keyCollision.isEmpty else { throw RecoverableSteerError.contextMismatch }
            context.insert(GenerationRecoveryRecord(namespace: namespace, snapshot: snapshot))
        }
        try context.save()
    }

    func recoverableGenerations(profileID: ServerProfileID, accountID: AccountID) throws -> [GenerationSnapshot] {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let descriptor = FetchDescriptor<GenerationRecoveryRecord>(
            predicate: #Predicate { $0.namespace == namespace },
            sortBy: [SortDescriptor(\.checkpointedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { record in
            guard let snapshot = try? JSONDecoder().decode(GenerationSnapshot.self, from: record.snapshot),
                  !snapshot.state.isTerminal else { return nil }
            return snapshot
        }
    }

    func remove(handle: GenerationHandle) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: handle.profileID, accountID: handle.accountID)
        try exactGenerationRecords(context: context, namespace: namespace, handle: handle)
            .forEach(context.delete)
        try context.save()
    }

    /// Reads only terminal steer leftovers for one exact server/account/chat
    /// namespace. Active generation checkpoints remain on their existing,
    /// separate recovery path.
    func terminalSteerRecoveries(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) throws -> [RecoverableSteerBatch] {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let records = try context.fetch(FetchDescriptor<GenerationRecoveryRecord>(
            predicate: #Predicate { $0.namespace == namespace },
            sortBy: [SortDescriptor(\.checkpointedAt, order: .reverse)]
        ))
        var seen = Set<GenerationHandle>()
        return records.compactMap { record in
            guard let snapshot = validatedTerminalSteerSnapshot(
                record: record,
                profileID: profileID,
                accountID: accountID,
                conversationID: conversationID
            ), seen.insert(snapshot.handle).inserted else { return nil }
            return RecoverableSteerBatch(
                handle: snapshot.handle,
                steers: snapshot.recoverableSteers,
                checkpointedAt: record.checkpointedAt
            )
        }
    }

    /// Atomically removes exactly the identities acknowledged by the caller.
    /// A duplicate acknowledgement is a harmless no-op; unrelated identities
    /// and similarly named records in other namespaces are never touched.
    func acknowledgeTerminalSteers(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        handle: GenerationHandle,
        identities: Set<RecoverableSteerIdentity>
    ) throws -> RecoverableSteerBatch? {
        guard handle.profileID == profileID,
              handle.accountID == accountID,
              handle.conversationID == conversationID else {
            throw RecoverableSteerError.contextMismatch
        }

        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let matches = try exactGenerationRecords(context: context, namespace: namespace, handle: handle)
            .filter { record in
                validatedTerminalSteerSnapshot(
                    record: record,
                    profileID: profileID,
                    accountID: accountID,
                    conversationID: conversationID
                ) != nil
            }
            .sorted { $0.checkpointedAt > $1.checkpointedAt }
        guard let record = matches.first,
              var snapshot = validatedTerminalSteerSnapshot(
                record: record,
                profileID: profileID,
                accountID: accountID,
                conversationID: conversationID
              ) else { return nil }

        for duplicate in matches.dropFirst() { context.delete(duplicate) }
        guard !identities.isEmpty else {
            if matches.count > 1 { try context.save() }
            return RecoverableSteerBatch(
                handle: handle,
                steers: snapshot.recoverableSteers,
                checkpointedAt: record.checkpointedAt
            )
        }

        let priorCount = snapshot.recoverableSteers.count
        snapshot.recoverableSteers.removeAll { identities.contains($0.recoveryIdentity) }
        guard snapshot.recoverableSteers.count != priorCount else {
            if matches.count > 1 { try context.save() }
            return RecoverableSteerBatch(
                handle: handle,
                steers: snapshot.recoverableSteers,
                checkpointedAt: record.checkpointedAt
            )
        }
        if snapshot.recoverableSteers.isEmpty {
            context.delete(record)
            try context.save()
            return nil
        }

        snapshot.updatedAt = Date()
        record.snapshot = try JSONEncoder().encode(snapshot)
        record.checkpointedAt = snapshot.updatedAt
        try context.save()
        return RecoverableSteerBatch(
            handle: handle,
            steers: snapshot.recoverableSteers,
            checkpointedAt: record.checkpointedAt
        )
    }

    /// Finds both current records and V1 records whose keys did not include a
    /// client request ID and represented a nil epoch as zero. Decoded full
    /// handle equality is the authority, so legacy key collisions fail closed.
    private func exactGenerationRecords(
        context: ModelContext,
        namespace: String,
        handle: GenerationHandle
    ) throws -> [GenerationRecoveryRecord] {
        let streamID = handle.streamID
        return try context.fetch(FetchDescriptor<GenerationRecoveryRecord>(
            predicate: #Predicate { $0.namespace == namespace && $0.streamID == streamID }
        ))
        .filter { record in
            guard let snapshot = try? JSONDecoder().decode(GenerationSnapshot.self, from: record.snapshot) else {
                return false
            }
            return snapshot.handle == handle
                && snapshot.handle.profileID == handle.profileID
                && snapshot.handle.accountID == handle.accountID
                && snapshot.handle.conversationID == handle.conversationID
        }
        .sorted { lhs, rhs in
            let current = GenerationRecoveryRecord.currentKey(namespace: namespace, handle: handle)
            if lhs.recordKey == current { return true }
            if rhs.recordKey == current { return false }
            return lhs.checkpointedAt > rhs.checkpointedAt
        }
    }

    private func validatedTerminalSteerSnapshot(
        record: GenerationRecoveryRecord,
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) -> GenerationSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(GenerationSnapshot.self, from: record.snapshot),
              snapshot.state.isTerminal,
              snapshot.handle.profileID == profileID,
              snapshot.handle.accountID == accountID,
              snapshot.handle.conversationID == conversationID,
              snapshot.handle.streamID == record.streamID,
              !snapshot.recoverableSteers.isEmpty else { return nil }
        return snapshot
    }

    func save(upload: PendingUpload) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: upload.profileID, accountID: upload.accountID)
        let key = "\(namespace)|upload|\(upload.id.uuidString)"
        let descriptor = FetchDescriptor<UploadRecord>(predicate: #Predicate { $0.recordKey == key })
        if let record = try context.fetch(descriptor).first {
            record.upload = try JSONEncoder().encode(upload)
            record.updatedAt = Date()
        } else {
            context.insert(UploadRecord(namespace: namespace, upload: upload))
        }
        try context.save()
    }

    func removeUpload(
        id: UUID,
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let key = "\(namespace)|upload|\(id.uuidString)"
        try context.fetch(FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.recordKey == key }
        )).forEach(context.delete)
        try context.save()
    }

    func uploads(profileID: ServerProfileID, accountID: AccountID) throws -> [PendingUpload] {
        let context = ModelContext(container)
        let namespace = CacheNamespace.key(profileID: profileID, accountID: accountID)
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.namespace == namespace },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { try? JSONDecoder().decode(PendingUpload.self, from: $0.upload) }
    }

    func purge(profileID: ServerProfileID, accountID: AccountID? = nil) throws {
        let context = ModelContext(container)
        let profile = profileID.rawValue
        let namespaces: Set<String>
        if let accountID {
            namespaces = [CacheNamespace.key(profileID: profileID, accountID: accountID)]
        } else {
            // Profile ownership comes from explicit stored columns. Child
            // records are then deleted by exact namespace equality, avoiding
            // collisions such as account "a" versus account "ab".
            let accounts = try context.fetch(FetchDescriptor<AccountRecord>(
                predicate: #Predicate { $0.profileID == profile }
            ))
            let profiles = try context.fetch(FetchDescriptor<ServerProfileRecord>(
                predicate: #Predicate { $0.profileID == profile }
            ))
            namespaces = Set(accounts.map(\.namespace)).union(
                profiles.compactMap(\.accountID).map {
                    CacheNamespace.key(profileID: profileID, accountID: AccountID(rawValue: $0))
                }
            )
        }

        let stagedUploads = try context.fetch(FetchDescriptor<UploadRecord>())
            .filter { namespaces.contains($0.namespace) }
            .compactMap { try? JSONDecoder().decode(PendingUpload.self, from: $0.upload) }
        for upload in stagedUploads {
            try? FileManager.default.removeItem(at: upload.localURL)
        }

        if accountID == nil {
            try deleteMatching(AccountRecord.self, context: context) { $0.profileID == profile }
        } else {
            try deleteMatching(AccountRecord.self, context: context) { namespaces.contains($0.namespace) }
        }
        try deleteMatching(ConversationRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(MessageRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(DraftRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(GenerationRecoveryRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(PendingInteractionRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(UploadRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(ConfigurationSnapshotRecord.self, context: context) { namespaces.contains($0.namespace) }
        try deleteMatching(FollowUpQueueRecord.self, context: context) { namespaces.contains($0.namespace) }
        try context.save()
        try FileTransferCacheDirectory.purge(profileID: profileID, accountID: accountID)
        try LegacyGeneratedFileCacheDirectory.purge(profileID: profileID, accountID: accountID)
    }

    private func deleteMatching<Model: PersistentModel>(
        _ type: Model.Type,
        context: ModelContext,
        where predicate: (Model) -> Bool
    ) throws {
        try context.fetch(FetchDescriptor<Model>()).filter(predicate).forEach(context.delete)
    }
}
