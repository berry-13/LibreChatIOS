import Foundation
import LibreChatDomain
import LibreChatProtocol
import OSLog
import SwiftData

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "LibreChat"

    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let authentication = Logger(subsystem: subsystem, category: "authentication")
    static let compatibility = Logger(subsystem: subsystem, category: "compatibility")
    static let generation = Logger(subsystem: subsystem, category: "generation")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let perf = Logger(subsystem: subsystem, category: "perf")
    static let uploads = Logger(subsystem: subsystem, category: "uploads")

    static let protocolObservability = ProtocolObservability { event in
        switch event {
        case let .transportStarted(route, method, attempt):
            transport.debug(
                "HTTP started route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        case let .transportResponded(route, method, status, attempt):
            transport.notice(
                "HTTP responded route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) status=\(status, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        case let .transportFailed(route, method, attempt, failure):
            transport.error(
                "HTTP failed route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) attempt=\(attempt, privacy: .public) failure=\(failure.rawValue, privacy: .public)"
            )
        case let .transportRetryScheduled(route, method, nextAttempt):
            transport.notice(
                "HTTP retry route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) next-attempt=\(nextAttempt, privacy: .public)"
            )
        case let .eventStreamOpened(route, status):
            transport.notice(
                "Event stream opened route=\(route.rawValue, privacy: .public) status=\(status, privacy: .public)"
            )
        case .authenticationLoginStarted:
            authentication.notice("Password login started")
        case let .authenticationLoginCompleted(outcome):
            authentication.notice(
                "Password login completed outcome=\(outcome.rawValue, privacy: .public)"
            )
        case .authenticationRefreshRequested:
            authentication.notice("Refresh requested")
        case .authenticationRefreshCoalesced:
            authentication.debug("Refresh coalesced")
        case .authenticationRefreshSucceeded:
            authentication.notice("Refresh succeeded")
        case .authenticationRefreshFailed:
            authentication.error("Refresh failed")
        case let .authenticationCredentialRevisionChanged(reason, revision):
            authentication.debug(
                "Credential revision changed reason=\(reason.rawValue, privacy: .public) revision=\(revision, privacy: .public)"
            )
        case let .authorizationRecoveryStarted(route, method):
            authentication.notice(
                "401 recovery started route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public)"
            )
        case let .authorizationRecoveryCompleted(route, method, outcome):
            authentication.notice(
                "401 recovery completed route=\(route.rawValue, privacy: .public) method=\(method.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)"
            )
        }
    }
}

/// Finite, non-sensitive state describing whether local cache durability is
/// available. The underlying SwiftData error is deliberately not retained or
/// presented because it can contain private filesystem details.
enum CacheHealth: Equatable, Sendable {
    enum Degradation: String, Equatable, Sendable {
        case persistentStoreUnavailable
    }

    case healthyPersistent
    case ephemeral
    case degraded(Degradation)

    var repairNotice: String? {
        guard case .degraded(.persistentStoreUnavailable) = self else { return nil }
        return "Offline storage is unavailable. Chats keep working, but this session's drafts and offline data won't be saved."
    }

    var allowsUserInitiatedClear: Bool {
        if case .degraded = self { return false }
        return true
    }
}

@MainActor
final class AppDependencies {
    typealias ProfileRuntimeFactory = @MainActor (ServerProfile, CacheCoordinator) -> ProfileRuntime
    typealias ModelContainerFactory = @MainActor (Schema, ModelConfiguration) throws -> ModelContainer

    let modelContainer: ModelContainer
    let cache: CacheCoordinator
    let cacheHealth: CacheHealth
    private let profileRuntimeFactory: ProfileRuntimeFactory?
    #if DEBUG
    let uiTestFixture: UITestFixture?
    #endif

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        cacheHealth: CacheHealth? = nil,
        modelContainerFactory: ModelContainerFactory? = nil,
        profileRuntimeFactory: ProfileRuntimeFactory? = nil
    ) throws {
        precondition(inMemory == false || storeURL == nil, "An in-memory cache cannot use a persistent store URL.")
        let schema = Schema(versionedSchema: CacheSchemaV2.self)
        let configuration = if let storeURL {
            ModelConfiguration("LibreChatCache", schema: schema, url: storeURL)
        } else {
            ModelConfiguration(
                "LibreChatCache",
                schema: schema,
                isStoredInMemoryOnly: inMemory
            )
        }
        if let modelContainerFactory {
            modelContainer = try modelContainerFactory(schema, configuration)
        } else {
            modelContainer = try Self.makeModelContainer(schema: schema, configuration: configuration)
        }
        cache = CacheCoordinator(container: modelContainer)
        self.cacheHealth = cacheHealth ?? (inMemory ? .ephemeral : .healthyPersistent)
        self.profileRuntimeFactory = profileRuntimeFactory
        #if DEBUG
        uiTestFixture = nil
        #endif
    }

    /// The cache store's fixed location. An explicit URL (matching the
    /// configuration name) keeps the file findable for the discard-and-
    /// rebuild repair below.
    static var defaultCacheStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "LibreChatCache.store")
    }

    /// Removes a store and its write-ahead sidecars so a fresh one can be
    /// created in place. The cache is disposable by design — offline data
    /// and drafts regenerate; a corrupted store must never wedge the app
    /// into the degraded state permanently.
    static func discardCacheStoreFiles(at url: URL) {
        let fileManager = FileManager.default
        for sidecar in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? fileManager.removeItem(atPath: sidecar)
        }
    }

    /// Only identified corruption or an incompatible schema justifies
    /// deleting the store: it holds unsent drafts, staged uploads, and
    /// follow-up journals that cannot be regenerated from the server.
    /// Transient failures (disk pressure, temporary I/O) must leave the
    /// persistent files in place and fall back to the in-memory store.
    static func isStoreCorruption(_ failure: NSError) -> Bool {
        var current: NSError = failure
        for _ in 0..<4 {
            if current.domain == NSCocoaErrorDomain {
                // NSFileReadCorruptFileError and
                // NSPersistentStoreIncompatibleVersionSchemaError.
                if current.code == 258 || current.code == 134_100 { return true }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                // SQLite-level corruption reaches here through the chain.
                if current.domain == "SQLite" || current.domain == "SQLiteErrorDomain",
                   current.code == 11 /* SQLITE_CORRUPT */ || current.code == 26 /* SQLITE_NOTADB */ {
                    return true
                }
                return false
            }
            current = underlying
        }
        return false
    }

    /// Private offline data — the conversation cache and staged attachment
    /// bytes — must never ride device backups: an app-container export would
    /// bypass the optional LocalAuthentication screen and expose messages
    /// and files that file protection alone does not shield.
    static func excludePrivateDataFromBackups(storeURL: URL) {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
            var fileURL = URL(fileURLWithPath: path)
            try? fileURL.setResourceValues(resourceValues)
        }
        var uploads = URL.applicationSupportDirectory.appending(
            path: "Uploads",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try? uploads.setResourceValues(resourceValues)
    }

    static func live(
        persistentContainerFactory: ModelContainerFactory? = nil,
        storeURL: URL? = nil
    ) -> AppDependencies {
        let cacheStoreURL = storeURL ?? defaultCacheStoreURL
        do {
            let dependencies = try AppDependencies(
                storeURL: cacheStoreURL,
                modelContainerFactory: persistentContainerFactory
            )
            excludePrivateDataFromBackups(storeURL: cacheStoreURL)
            return dependencies
        } catch {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            if isStoreCorruption(failure) {
                AppLog.persistence.fault(
                    "Persistent cache is corrupt; discarding the store and rebuilding it. domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) underlying-domain=\(underlying?.domain ?? "none", privacy: .public) underlying-code=\(underlying?.code ?? 0, privacy: .public)"
                )
                discardCacheStoreFiles(at: cacheStoreURL)
                do {
                    let dependencies = try AppDependencies(
                        storeURL: cacheStoreURL,
                        modelContainerFactory: persistentContainerFactory
                    )
                    excludePrivateDataFromBackups(storeURL: cacheStoreURL)
                    return dependencies
                } catch {
                    let retryFailure = error as NSError
                    AppLog.persistence.fault(
                        "Rebuilt cache store is still unavailable; using an in-memory recovery store. domain=\(retryFailure.domain, privacy: .public) code=\(retryFailure.code, privacy: .public)"
                    )
                }
            } else {
                AppLog.persistence.fault(
                    "Persistent cache unavailable without store corruption; keeping the store on disk and using an in-memory recovery store. domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) underlying-domain=\(underlying?.domain ?? "none", privacy: .public) underlying-code=\(underlying?.code ?? 0, privacy: .public)"
                )
            }
            do {
                return try AppDependencies(
                    inMemory: true,
                    cacheHealth: .degraded(.persistentStoreUnavailable)
                )
            } catch {
                fatalError("Unable to create the LibreChat recovery model container.")
            }
        }
    }

    #if DEBUG
    /// This process-argument-gated runtime is intentionally self-contained:
    /// it has no Keychain, persistent cache, or network dependency.
    static func uiTestFixtures() -> AppDependencies {
        do {
            return try AppDependencies(
                inMemory: true,
                profileRuntimeFactory: { profile, cache in
                    UITestFixture.runtime(profile: profile, cache: cache)
                },
                uiTestFixture: .standard
            )
        } catch {
            fatalError("Unable to create in-memory UI test fixtures.")
        }
    }

    private init(
        inMemory: Bool,
        profileRuntimeFactory: @escaping ProfileRuntimeFactory,
        uiTestFixture: UITestFixture
    ) throws {
        let schema = Schema(versionedSchema: CacheSchemaV2.self)
        let configuration = ModelConfiguration(
            "LibreChatUITestCache",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        modelContainer = try ModelContainer(
            for: schema,
            migrationPlan: CacheMigrationPlan.self,
            configurations: [configuration]
        )
        cache = CacheCoordinator(container: modelContainer)
        cacheHealth = .ephemeral
        self.profileRuntimeFactory = profileRuntimeFactory
        self.uiTestFixture = uiTestFixture
    }
    #endif

    private static func makeModelContainer(
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: CacheMigrationPlan.self,
            configurations: [configuration]
        )
    }

    func profileRuntime(for profile: ServerProfile) -> ProfileRuntime {
        if let profileRuntimeFactory {
            return profileRuntimeFactory(profile, cache)
        }
        let runtime = LibreChatRuntime.live(
            profile: profile,
            observability: AppLog.protocolObservability
        )
        let repository = LibreChatRepository(profile: profile, runtime: runtime, cache: cache)
        return ProfileRuntime(profile: profile, protocolRuntime: runtime, repository: repository)
    }
}

struct ProfileRuntime: Sendable {
    var profile: ServerProfile
    let protocolRuntime: LibreChatRuntime
    let repository: LibreChatRepository
}
