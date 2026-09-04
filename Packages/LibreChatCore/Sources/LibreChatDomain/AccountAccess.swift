import Foundation

/// Anonymous capabilities that shape the native sign-in surface. They are
/// intentionally distinct from authenticated feature capabilities.
public struct PreLoginCapabilities: Codable, Equatable, Sendable {
    public var emailLoginEnabled: Bool
    public var registrationEnabled: Bool
    public var passwordResetEnabled: Bool
    public var emailDeliveryEnabled: Bool
    public var minimumPasswordLength: Int
    /// LibreChat currently advertises Turnstile presentation configuration,
    /// but the pinned server does not define a mobile verification contract.
    public var requiresWebChallenge: Bool

    public init(
        emailLoginEnabled: Bool = true,
        registrationEnabled: Bool = false,
        passwordResetEnabled: Bool = false,
        emailDeliveryEnabled: Bool = false,
        minimumPasswordLength: Int = 8,
        requiresWebChallenge: Bool = false
    ) {
        self.emailLoginEnabled = emailLoginEnabled
        self.registrationEnabled = registrationEnabled
        self.passwordResetEnabled = passwordResetEnabled
        self.emailDeliveryEnabled = emailDeliveryEnabled
        self.minimumPasswordLength = minimumPasswordLength
        self.requiresWebChallenge = requiresWebChallenge
    }
}

public struct PublicLegalLink: Codable, Equatable, Sendable {
    public var externalURL: URL
    public var opensExternally: Bool

    public init(externalURL: URL, opensExternally: Bool = true) {
        self.externalURL = externalURL
        self.opensExternally = opensExternally
    }
}

public struct PublicTermsOfService: Codable, Equatable, Identifiable, Sendable {
    public var externalURL: URL?
    public var opensExternally: Bool
    public var requiresAcceptance: Bool
    public var title: String?
    public var content: String

    public var id: String { "terms-of-service" }

    public init(
        externalURL: URL? = nil,
        opensExternally: Bool = true,
        requiresAcceptance: Bool = false,
        title: String? = nil,
        content: String = ""
    ) {
        self.externalURL = externalURL
        self.opensExternally = opensExternally
        self.requiresAcceptance = requiresAcceptance
        self.title = title
        self.content = content
    }
}

public struct PublicLegalConfiguration: Codable, Equatable, Sendable {
    public var privacyPolicy: PublicLegalLink?
    public var termsOfService: PublicTermsOfService?

    public init(
        privacyPolicy: PublicLegalLink? = nil,
        termsOfService: PublicTermsOfService? = nil
    ) {
        self.privacyPolicy = privacyPolicy
        self.termsOfService = termsOfService
    }
}

public struct PasswordResetRequestResult: Equatable, Sendable {
    /// Present only on deployments that deliberately return their web reset
    /// link because outbound email is unavailable. This value is never cached.
    public var recoveryURL: URL?

    public init(recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL
    }
}

/// A user-facing acknowledgement returned by a public account mutation.
///
/// Messages are server supplied and intentionally optional: LibreChat has
/// historically returned slightly different envelopes across deployments.
/// Callers must not infer account existence or mutation success from a missing
/// message.
public struct AccountMutationNotice: Codable, Equatable, Sendable {
    public var message: String?
    public var status: String?

    public init(message: String? = nil, status: String? = nil) {
        self.message = message
        self.status = status
    }
}

/// Input for LibreChat's public local-account registration endpoint. `token`
/// is an optional, one-shot invitation token and must remain body-only and
/// ephemeral.
public struct AccountRegistration: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var username: String?
    public var password: String
    public var confirmationPassword: String
    public var token: String?

    public init(
        name: String,
        email: String,
        username: String? = nil,
        password: String,
        confirmationPassword: String,
        token: String? = nil
    ) {
        self.name = name
        self.email = email
        self.username = username
        self.password = password
        self.confirmationPassword = confirmationPassword
        self.token = token
    }
}

public struct RegistrationResult: Codable, Equatable, Sendable {
    public var notice: AccountMutationNotice

    public init(notice: AccountMutationNotice = AccountMutationNotice()) {
        self.notice = notice
    }
}

/// Input for a password-reset completion. The reset token is deliberately
/// transmitted in the request body only; it must never become part of a route,
/// query string, log, or persisted model.
public struct PasswordResetCompletion: Codable, Equatable, Sendable {
    public var userID: String
    public var token: String
    public var password: String
    public var confirmationPassword: String?

    public init(
        userID: String,
        token: String,
        password: String,
        confirmationPassword: String? = nil
    ) {
        self.userID = userID
        self.token = token
        self.password = password
        self.confirmationPassword = confirmationPassword
    }
}

public struct PasswordResetCompletionResult: Codable, Equatable, Sendable {
    public var notice: AccountMutationNotice

    public init(notice: AccountMutationNotice = AccountMutationNotice()) {
        self.notice = notice
    }
}

/// Input for a public email-verification submission. The token is opaque and
/// body-only for the same reason as a password-reset token.
public struct EmailVerification: Codable, Equatable, Sendable {
    public var email: String
    public var token: String

    public init(email: String, token: String) {
        self.email = email
        self.token = token
    }
}

public struct EmailVerificationResult: Codable, Equatable, Sendable {
    public var notice: AccountMutationNotice

    public init(notice: AccountMutationNotice = AccountMutationNotice()) {
        self.notice = notice
    }
}

public struct EmailVerificationResendResult: Codable, Equatable, Sendable {
    public var notice: AccountMutationNotice

    public init(notice: AccountMutationNotice = AccountMutationNotice()) {
        self.notice = notice
    }
}

public enum AccountMutationUnavailableError: LocalizedError, Equatable, Sendable {
    case unavailable

    public var errorDescription: String? {
        "This LibreChat account action is not available in the current runtime."
    }
}

public struct TermsAcceptanceStatus: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var acceptedAt: Date?

    public init(accepted: Bool, acceptedAt: Date? = nil) {
        self.accepted = accepted
        self.acceptedAt = acceptedAt
    }
}

public protocol AccountAccessRepository: Sendable {
    func requestPasswordReset(email: String) async throws -> PasswordResetRequestResult
    func register(_ registration: AccountRegistration) async throws -> RegistrationResult
    func completePasswordReset(
        _ completion: PasswordResetCompletion
    ) async throws -> PasswordResetCompletionResult
    func verifyEmail(_ verification: EmailVerification) async throws -> EmailVerificationResult
    func resendEmailVerification(email: String) async throws -> EmailVerificationResendResult
    func termsAcceptanceStatus() async throws -> TermsAcceptanceStatus
    func acceptTerms() async throws -> TermsAcceptanceStatus
}

/// Mutation defaults keep the legacy repository source-compatible while
/// failing closed until an app runtime explicitly adopts these public flows.
public extension AccountAccessRepository {
    func register(_ registration: AccountRegistration) async throws -> RegistrationResult {
        throw AccountMutationUnavailableError.unavailable
    }

    func completePasswordReset(
        _ completion: PasswordResetCompletion
    ) async throws -> PasswordResetCompletionResult {
        throw AccountMutationUnavailableError.unavailable
    }

    func verifyEmail(_ verification: EmailVerification) async throws -> EmailVerificationResult {
        throw AccountMutationUnavailableError.unavailable
    }

    func resendEmailVerification(email: String) async throws -> EmailVerificationResendResult {
        throw AccountMutationUnavailableError.unavailable
    }
}
