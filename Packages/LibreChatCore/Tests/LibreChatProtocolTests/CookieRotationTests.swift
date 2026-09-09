import Foundation
import LibreChatDomain
import LibreChatProtocol
import LibreChatTestSupport
import Testing

struct CookieRotationTests {
    @Test("Splitting comma-joined Set-Cookie preserves Expires dates")
    func splitMergedSetCookieHeader() {
        let merged = "refreshToken=first-token; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly; Secure, accessToken=second; Path=/; Expires=Thu, 22 Oct 2026 07:28:00 GMT"
        let parts = ProfileCookieJar.splitSetCookieValues(merged)
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("refreshToken=first-token"))
        #expect(parts[0].contains("Expires=Wed, 21 Oct 2026 07:28:00 GMT"))
        #expect(parts[1].hasPrefix("accessToken=second"))
    }

    @Test("A single Set-Cookie value passes through unchanged")
    func singleSetCookieUnchanged() {
        let single = "refreshToken=token; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly"
        #expect(ProfileCookieJar.splitSetCookieValues(single) == [single])
    }

    @Test("Rotated refresh cookies are stored from a merged refresh response")
    func absorbStoresRotatedRefreshTokenFromMergedHeader() async throws {
        let secretStore = MemorySecretStore()
        let baseURL = try #require(URL(string: "https://chat.example.com"))
        let jar = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "profile-1"),
            baseURL: baseURL,
            secretStore: secretStore
        )

        // URLSession's allHeaderFields merges duplicate Set-Cookie headers
        // into one comma-joined value. LibreChat's refresh rotation sends the
        // replacement refreshToken this way; losing it forced a 401 logout on
        // the next cold start.
        let merged = "refreshToken=rotated-token; Path=/; Expires=Sat, 31 Oct 2026 18:00:00 GMT; HttpOnly; Secure, csrfToken=abc123; Path=/; Expires=Sat, 31 Oct 2026 18:00:00 GMT"
        await jar.absorb(
            responseHeaders: ["Set-Cookie": merged],
            for: baseURL.appending(path: "api/auth/refresh")
        )

        let snapshot = await jar.snapshot()
        #expect(snapshot.contains { $0.name == "refreshToken" && $0.value == "rotated-token" })
        #expect(snapshot.contains { $0.name == "csrfToken" && $0.value == "abc123" })

        // The persisted form survives a fresh jar instance (cold start).
        let relaunched = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "profile-1"),
            baseURL: baseURL,
            secretStore: secretStore
        )
        let restored = try await relaunched.cookieHeader(
            for: baseURL.appending(path: "api/auth/refresh")
        )
        #expect(restored?.contains("refreshToken=rotated-token") == true)
        #expect(restored?.contains("csrfToken=abc123") == true)
    }
}

struct MirroredSecretStoreTests {
    @Test("Mirrored store recovers secrets after a Keychain wipe")
    func mirroredStoreRecoversAfterPrimaryLoss() async throws {
        let primary = MemorySecretStore()
        let mirrorDirectory = FileManager.default.temporaryDirectory
            .appending(path: "mirror-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let key = "cookies.profile-1"
        let payload = Data("rotated-token".utf8)

        let original = MirroredSecretStore(primary: primary, directory: mirrorDirectory)
        try await original.set(payload, for: key)

        // A "reinstall" loses the primary store but keeps the data container.
        let wipedPrimary = MemorySecretStore()
        let afterInstall = MirroredSecretStore(primary: wipedPrimary, directory: mirrorDirectory)
        let recovered = try await afterInstall.data(for: key)
        #expect(recovered == payload)

        // The read heals the new primary so later primary-only reads work.
        #expect(try await wipedPrimary.data(for: key) == payload)

        // Removal clears both layers.
        try await afterInstall.remove(key)
        #expect(try await afterInstall.data(for: key) == nil)
    }

    @Test("Mirror still persists when the Keychain write fails entirely")
    func mirroredStoreSurvivesPrimaryWriteFailure() async throws {
        let mirrorDirectory = FileManager.default.temporaryDirectory
            .appending(path: "mirror-fail-\(UUID().uuidString)", directoryHint: .isDirectory)
        let key = "cookies.unsigned-build"
        let payload = Data("refresh-cookie".utf8)

        // Unsigned or entitlement-less builds cannot write the Keychain at
        // all; the mirror must still capture the session.
        struct FailingSecretStore: SecretStore {
            func data(for key: String) async throws -> Data? { nil }
            func set(_ data: Data, for key: String) async throws {
                throw LibreChatProtocolError.keychain(-34018)
            }
            func remove(_ key: String) async throws {}
        }

        let store = MirroredSecretStore(primary: FailingSecretStore(), directory: mirrorDirectory)
        try await store.set(payload, for: key)

        // The mirror alone restores the session on the next launch.
        let reloaded = MirroredSecretStore(primary: FailingSecretStore(), directory: mirrorDirectory)
        #expect(try await reloaded.data(for: key) == payload)
    }

    @Test("Secure cookies from loopback HTTP are stored and sent")
    func secureCookiesFromLoopbackHTTPPersist() async throws {
        let secretStore = MemorySecretStore()
        let baseURL = try #require(URL(string: "http://localhost:3080"))
        let jar = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "profile-loopback"),
            baseURL: baseURL,
            secretStore: secretStore
        )

        // LibreChat marks its auth cookies `Secure` even on plain-HTTP
        // deployments. HTTPCookie drops `Secure` cookies for non-HTTPS URLs,
        // which used to leave the jar empty: the next cold start refreshed
        // with no cookie header and signed the user out.
        let merged = "refreshToken=loopback-refresh; Path=/; Expires=Sat, 31 Oct 2026 18:00:00 GMT; HttpOnly; Secure; SameSite=Strict, token_provider=librechat; Path=/; Expires=Sat, 31 Oct 2026 18:00:00 GMT; HttpOnly; Secure; SameSite=Strict"
        await jar.absorb(responseHeaders: ["Set-Cookie": merged], for: baseURL)

        let stored = await jar.snapshot()
        #expect(stored.map(\.name).sorted() == ["refreshToken", "token_provider"])

        let header = try await jar.cookieHeader(for: try #require(URL(string: "http://localhost:3080/api/auth/refresh")))
        #expect(header?.contains("refreshToken=loopback-refresh") == true)
    }

    @Test("Secure cookies are still withheld from non-loopback HTTP")
    func secureCookiesFromRemoteHTTPWithheld() async throws {
        let secretStore = MemorySecretStore()
        let baseURL = try #require(URL(string: "http://chat.example.com"))
        let jar = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "profile-remote"),
            baseURL: baseURL,
            secretStore: secretStore
        )
        let merged = "refreshToken=remote-refresh; Path=/; Expires=Sat, 31 Oct 2026 18:00:00 GMT; HttpOnly; Secure"
        await jar.absorb(responseHeaders: ["Set-Cookie": merged], for: baseURL)

        let stored = await jar.snapshot()
        #expect(stored.isEmpty)
    }
}
