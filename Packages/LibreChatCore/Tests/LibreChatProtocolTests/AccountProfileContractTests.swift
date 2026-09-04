import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

@Suite("Account profile and deletion")
struct AccountProfileContractTests {
    @Test func profileReadUsesExactAuthenticatedIdempotentRoute() {
        let request = LibreChatAccountProfileAPI.profile()
        #expect(request.method == .get)
        #expect(request.path == "api/user")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
        #expect(request.body == nil)
        #expect(ProtocolRoute.classify(path: "/host/api/user") == .accountAccess)
    }

    @Test func deletionOmitsProofWhenAbsentAndEncodesExactlyOneProofWhenPresent() throws {
        let unprotected = try LibreChatAccountProfileAPI.deleteAccount(proof: nil)
        #expect(unprotected.method == .delete)
        #expect(unprotected.path == "api/user/delete")
        #expect(unprotected.authorization == .bearer)
        #expect(unprotected.retryPolicy == .never)
        #expect(unprotected.body == nil)

        let totp = try LibreChatAccountProfileAPI.deleteAccount(
            proof: .authenticatorCode("123456")
        )
        #expect(try object(totp.body) == ["token": "123456"])
        #expect(totp.retryPolicy == .never)

        let backup = try LibreChatAccountProfileAPI.deleteAccount(
            proof: .backupCode("opaque-backup")
        )
        #expect(try object(backup.body) == ["backupCode": "opaque-backup"])
        #expect(backup.pathComponents == nil)
        #expect(backup.queryItems.isEmpty)
        #expect(ProtocolRoute.classify(path: "/api/user/delete") == .accountAccess)
    }

    @Test func deletionRequiresThePinnedSuccessAcknowledgement() throws {
        try AccountDeletionResponseDTO(message: "User deleted").validateConfirmation()
        #expect(throws: AccountDeletionError.invalidResponse) {
            try AccountDeletionResponseDTO(message: "OK").validateConfirmation()
        }
        #expect(throws: AccountDeletionError.invalidResponse) {
            try AccountDeletionResponseDTO(message: nil).validateConfirmation()
        }
    }

    @Test func avatarUsesExactMultipartWireAndNeverRetries() throws {
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let request = try LibreChatAccountProfileAPI.uploadAvatar(
            AccountAvatarUpload(data: image, mimeType: "image/png"),
            boundary: "AccountAvatarBoundary"
        )
        let body = try #require(request.body)
        let text = String(decoding: body, as: UTF8.self)

        #expect(request.method == .post)
        #expect(request.path == "api/files/images/avatar")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=AccountAvatarBoundary")
        #expect(text.contains("name=\"file\"; filename=\"avatar.png\""))
        #expect(text.contains("Content-Type: image/png"))
        #expect(text.contains("name=\"manual\"\r\n\r\ntrue"))
        #expect(body.containsSubsequence(image))
    }

    @Test func avatarValidationChecksBytesSizeAndBoundaryBeforeNetwork() {
        #expect(throws: AccountProfileError.unsupportedAvatarFormat) {
            try LibreChatAccountProfileAPI.uploadAvatar(
                AccountAvatarUpload(data: Data("not-an-image".utf8), mimeType: "image/png"),
                boundary: "safe"
            )
        }
        #expect(throws: AccountProfileError.avatarTooLarge(
            maximumBytes: LibreChatAccountProfileAPI.maximumAvatarBytes
        )) {
            try LibreChatAccountProfileAPI.uploadAvatar(
                AccountAvatarUpload(
                    data: Data(repeating: 0xFF, count: LibreChatAccountProfileAPI.maximumAvatarBytes + 1),
                    mimeType: "image/jpeg"
                ),
                boundary: "safe"
            )
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatAccountProfileAPI.uploadAvatar(
                AccountAvatarUpload(
                    data: Data([0xFF, 0xD8, 0xFF, 0x00]),
                    mimeType: "image/jpeg"
                ),
                boundary: "unsafe\r\nboundary"
            )
        }
        #expect(throws: AccountProfileError.avatarTooLarge(maximumBytes: 0)) {
            try LibreChatAccountProfileAPI.uploadAvatar(
                AccountAvatarUpload(
                    data: Data([0xFF, 0xD8, 0xFF, 0x00]),
                    mimeType: "image/jpeg"
                ),
                boundary: "safe",
                maximumBytes: 0
            )
        }
        #expect(
            AccountProfileError.avatarTooLarge(maximumBytes: 0).errorDescription
                == "Profile image uploads are disabled by this server."
        )
    }

    @Test func avatarResponseAcceptsOnlySafeHTTPOrigins() throws {
        let base = try #require(URL(string: "https://chat.example/subpath"))
        #expect(
            try AccountAvatarResponseDTO(url: "/images/avatar.png")
                .domainURL(relativeTo: base).absoluteString
                == "https://chat.example/subpath/images/avatar.png"
        )
        #expect(
            try AccountAvatarResponseDTO(url: "https://cdn.example/avatar.png")
                .domainURL(relativeTo: base).host == "cdn.example"
        )
        #expect(throws: AccountProfileError.invalidAvatarResponse) {
            try AccountAvatarResponseDTO(url: "javascript:alert(1)")
                .domainURL(relativeTo: base)
        }
        #expect(throws: AccountProfileError.invalidAvatarResponse) {
            try AccountAvatarResponseDTO(url: "http://remote.example/avatar.png")
                .domainURL(relativeTo: base)
        }
    }

    @Test func accountDeletionCapabilityIsPostLoginOnlyAndFailsClosed() throws {
        let startup = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(#"{"allowAccountDeletion":true}"#.utf8)
        )
        let detector = CapabilityDetector()
        #expect(detector.detect(startup: startup, authenticated: false).capabilities.supportsAccountDeletion == nil)
        let authenticated = detector.detect(startup: startup, authenticated: true).capabilities
        #expect(authenticated.supportsAccountDeletion == true)
        #expect(authenticated.failingClosedAuthenticatedPolicy().supportsAccountDeletion == nil)
    }

    private func object(_ data: Data?) throws -> [String: String] {
        let data = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

private extension Data {
    func containsSubsequence(_ candidate: Data) -> Bool {
        range(of: candidate) != nil
    }
}
