import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct AccountAccessContractTests {
    @Test func registrationIsPublicNeverRetriedAndOmitsAbsentOptionalFields() throws {
        let request = try LibreChatAccountAccessAPI.register(
            AccountRegistration(
                name: "Person",
                email: "person@example.com",
                password: "safe-password",
                confirmationPassword: "safe-password"
            )
        )
        let object = try request.jsonObject()

        #expect(request.method == .post)
        #expect(request.path == "api/auth/register")
        #expect(request.authorization == .none)
        #expect(request.retryPolicy == .never)
        #expect(object["name"] as? String == "Person")
        #expect(object["email"] as? String == "person@example.com")
        #expect(object["password"] as? String == "safe-password")
        #expect(object["confirm_password"] as? String == "safe-password")
        #expect(object["username"] == nil)
        #expect(object["token"] == nil)
        #expect(object.count == 4)
    }

    @Test func registrationIncludesOptionalUsernameAndOpaqueChallengeTokenOnlyInBody() throws {
        let opaqueToken = "javascript:alert(1)?redirect=/../../secret"
        let request = try LibreChatAccountAccessAPI.register(
            AccountRegistration(
                name: "Person",
                email: "person@example.com",
                username: "person",
                password: "safe-password",
                confirmationPassword: "safe-password",
                token: opaqueToken
            )
        )
        let object = try request.jsonObject()

        #expect(request.path == "api/auth/register")
        #expect(request.queryItems.isEmpty)
        #expect(request.pathComponents == nil)
        #expect(object["username"] as? String == "person")
        #expect(object["token"] as? String == opaqueToken)
    }

    @Test func passwordResetRequestIsPublicExactAndNeverBlindlyRetried() throws {
        let request = try LibreChatAccountAccessAPI.requestPasswordReset(
            email: "person@example.com"
        )
        let body = try #require(request.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(request.method == .post)
        #expect(request.path == "api/auth/requestPasswordReset")
        #expect(request.authorization == .none)
        #expect(request.retryPolicy == .never)
        #expect(object["email"] as? String == "person@example.com")
        #expect(object.count == 1)
    }

    @Test func returnedRecoveryLinkFailsClosedForUnsafeSchemesAndRemoteHTTP() {
        #expect(
            PasswordResetRequestResponseDTO(link: "https://chat.example/reset?token=secret")
                .domainModel().recoveryURL?.scheme == "https"
        )
        #expect(
            PasswordResetRequestResponseDTO(link: "http://localhost:3080/reset?token=secret")
                .domainModel().recoveryURL?.host == "localhost"
        )
        #expect(PasswordResetRequestResponseDTO(link: "http://chat.example/reset").domainModel().recoveryURL == nil)
        #expect(PasswordResetRequestResponseDTO(link: "javascript:alert(1)").domainModel().recoveryURL == nil)
        #expect(PasswordResetRequestResponseDTO(link: "file:///tmp/reset").domainModel().recoveryURL == nil)
    }

    @Test func termsRequestsUseBearerAndOnlyAcceptanceIsNonIdempotent() {
        let status = LibreChatAccountAccessAPI.termsAcceptanceStatus()
        let acceptance = LibreChatAccountAccessAPI.acceptTerms()

        #expect(status.method == .get)
        #expect(status.path == "api/user/terms")
        #expect(status.authorization == .bearer)
        #expect(status.retryPolicy == .idempotent(maximumAttempts: 2))

        #expect(acceptance.method == .post)
        #expect(acceptance.path == "api/user/terms/accept")
        #expect(acceptance.authorization == .bearer)
        #expect(acceptance.retryPolicy == .never)
    }

    @Test func passwordResetCompletionIsPublicNeverRetriedAndOmitsOptionalConfirmation() throws {
        let opaqueToken = "../?token=not-a-route"
        let request = try LibreChatAccountAccessAPI.completePasswordReset(
            PasswordResetCompletion(
                userID: "user-id",
                token: opaqueToken,
                password: "new-password"
            )
        )
        let object = try request.jsonObject()

        #expect(request.method == .post)
        #expect(request.path == "api/auth/resetPassword")
        #expect(request.pathComponents == nil)
        #expect(request.queryItems.isEmpty)
        #expect(request.authorization == .none)
        #expect(request.retryPolicy == .never)
        #expect(object["userId"] as? String == "user-id")
        #expect(object["token"] as? String == opaqueToken)
        #expect(object["password"] as? String == "new-password")
        #expect(object["confirm_password"] == nil)
        #expect(object.count == 3)
    }

    @Test func passwordResetCompletionIncludesOptionalConfirmationWithExactSnakeCase() throws {
        let request = try LibreChatAccountAccessAPI.completePasswordReset(
            PasswordResetCompletion(
                userID: "user-id",
                token: "opaque",
                password: "new-password",
                confirmationPassword: "new-password"
            )
        )
        let object = try request.jsonObject()

        #expect(object["confirm_password"] as? String == "new-password")
        #expect(object["confirmationPassword"] == nil)
    }

    @Test func emailVerificationAndResendArePublicExactAndNeverRetried() throws {
        let opaqueToken = "file:///private/token?x=1"
        let verification = try LibreChatAccountAccessAPI.verifyEmail(
            EmailVerification(email: "person@example.com", token: opaqueToken)
        )
        let resend = try LibreChatAccountAccessAPI.resendEmailVerification(
            email: "person@example.com"
        )
        let verificationObject = try verification.jsonObject()
        let resendObject = try resend.jsonObject()

        #expect(verification.method == .post)
        #expect(verification.path == "api/user/verify")
        #expect(verification.pathComponents == nil)
        #expect(verification.queryItems.isEmpty)
        #expect(verification.authorization == .none)
        #expect(verification.retryPolicy == .never)
        #expect(verificationObject["email"] as? String == "person@example.com")
        #expect(verificationObject["token"] as? String == opaqueToken)
        #expect(verificationObject.count == 2)

        #expect(resend.method == .post)
        #expect(resend.path == "api/user/verify/resend")
        #expect(resend.authorization == .none)
        #expect(resend.retryPolicy == .never)
        #expect(resendObject["email"] as? String == "person@example.com")
        #expect(resendObject.count == 1)
    }

    @Test func accountMutationResponsesMapToTypedNotices() {
        #expect(
            RegistrationResponseDTO(message: "Check your email").domainModel().notice.message
                == "Check your email"
        )
        #expect(
            PasswordResetCompletionResponseDTO(message: "Password reset was successful")
                .domainModel().notice.message == "Password reset was successful"
        )
        let verification = EmailVerificationResponseDTO(
            message: "Email verification was successful",
            status: "success"
        ).domainModel()
        #expect(verification.notice.message == "Email verification was successful")
        #expect(verification.notice.status == "success")
        #expect(
            EmailVerificationResendResponseDTO(message: "Check your email")
                .domainModel().notice.message == "Check your email"
        )
    }

    @Test func termsDatesDecodeWithAndWithoutFractionalSeconds() {
        let fractional = TermsAcceptanceStatusDTO(
            termsAccepted: true,
            termsAcceptedAt: "2026-08-18T10:00:00.123Z"
        ).domainModel()
        let whole = TermsAcceptanceReceiptDTO(
            termsAcceptedAt: "2026-08-18T10:00:00Z"
        ).domainModel()

        #expect(fractional.accepted)
        #expect(fractional.acceptedAt != nil)
        #expect(whole.accepted)
        #expect(whole.acceptedAt != nil)
    }
}

private extension APIRequest {
    func jsonObject() throws -> [String: Any] {
        let body = try #require(body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
