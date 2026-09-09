import Foundation
import Testing
import LibreChatDomain
import LibreChatTestSupport
@testable import LibreChatProtocol

struct CookieIsolationTests {
    @Test func sameHostProfilesRemainIsolated() async throws {
        let secrets = MemorySecretStore()
        let url = URL(string: "https://chat.example.com/api/auth/refresh")!
        let first = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "one"),
            baseURL: url,
            secretStore: secrets
        )
        let second = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "two"),
            baseURL: url,
            secretStore: secrets
        )
        await first.absorb(
            responseHeaders: ["Set-Cookie": "refreshToken=first; Path=/; Secure; HttpOnly"],
            for: url
        )
        await second.absorb(
            responseHeaders: ["Set-Cookie": "refreshToken=second; Path=/; Secure; HttpOnly"],
            for: url
        )
        #expect(try await first.cookieHeader(for: url) == "refreshToken=first")
        #expect(try await second.cookieHeader(for: url) == "refreshToken=second")

        let restoredFirst = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "one"),
            baseURL: url,
            secretStore: secrets
        )
        let restoredSecond = ProfileCookieJar(
            profileID: ServerProfileID(rawValue: "two"),
            baseURL: url,
            secretStore: secrets
        )
        #expect(try await restoredFirst.cookieHeader(for: url) == "refreshToken=first")
        #expect(try await restoredSecond.cookieHeader(for: url) == "refreshToken=second")
    }
}
