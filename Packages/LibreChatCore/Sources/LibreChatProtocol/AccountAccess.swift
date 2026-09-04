import Foundation
import LibreChatDomain

public struct PasswordResetRequestDTO: Codable, Equatable, Sendable {
    public var email: String

    public init(email: String) {
        self.email = email
    }
}

public struct AccountRegistrationDTO: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var username: String?
    public var password: String
    public var confirmPassword: String
    public var token: String?

    public init(_ registration: AccountRegistration) {
        name = registration.name
        email = registration.email
        username = registration.username
        password = registration.password
        confirmPassword = registration.confirmationPassword
        token = registration.token
    }

    private enum CodingKeys: String, CodingKey {
        case name, email, username, password, token
        case confirmPassword = "confirm_password"
    }
}

public struct PasswordResetCompletionDTO: Codable, Equatable, Sendable {
    public var userID: String
    public var token: String
    public var password: String
    public var confirmPassword: String?

    public init(_ completion: PasswordResetCompletion) {
        userID = completion.userID
        token = completion.token
        password = completion.password
        confirmPassword = completion.confirmationPassword
    }

    private enum CodingKeys: String, CodingKey {
        case token, password
        case userID = "userId"
        case confirmPassword = "confirm_password"
    }
}

public struct EmailVerificationDTO: Codable, Equatable, Sendable {
    public var email: String
    public var token: String

    public init(_ verification: EmailVerification) {
        email = verification.email
        token = verification.token
    }
}

public struct EmailVerificationResendDTO: Codable, Equatable, Sendable {
    public var email: String

    public init(email: String) {
        self.email = email
    }
}

public struct RegistrationResponseDTO: Codable, Equatable, Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public func domainModel() -> RegistrationResult {
        RegistrationResult(notice: AccountMutationNotice(message: message))
    }
}

public struct PasswordResetCompletionResponseDTO: Codable, Equatable, Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public func domainModel() -> PasswordResetCompletionResult {
        PasswordResetCompletionResult(notice: AccountMutationNotice(message: message))
    }
}

public struct EmailVerificationResponseDTO: Codable, Equatable, Sendable {
    public var message: String?
    public var status: String?

    public init(message: String? = nil, status: String? = nil) {
        self.message = message
        self.status = status
    }

    public func domainModel() -> EmailVerificationResult {
        EmailVerificationResult(
            notice: AccountMutationNotice(message: message, status: status)
        )
    }
}

public struct EmailVerificationResendResponseDTO: Codable, Equatable, Sendable {
    public var message: String?
    public var status: String?

    public init(message: String? = nil, status: String? = nil) {
        self.message = message
        self.status = status
    }

    public func domainModel() -> EmailVerificationResendResult {
        EmailVerificationResendResult(
            notice: AccountMutationNotice(message: message, status: status)
        )
    }
}

public struct PasswordResetRequestResponseDTO: Codable, Equatable, Sendable {
    public var message: String?
    public var link: String?

    public init(message: String? = nil, link: String? = nil) {
        self.message = message
        self.link = link
    }

    public func domainModel() -> PasswordResetRequestResult {
        PasswordResetRequestResult(recoveryURL: Self.safeExternalURL(link))
    }

    private static func safeExternalURL(_ rawValue: String?) -> URL? {
        guard let rawValue, let url = URL(string: rawValue), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased()) {
            return url
        }
        return nil
    }
}

public struct TermsAcceptanceStatusDTO: Codable, Equatable, Sendable {
    public var termsAccepted: Bool
    public var termsAcceptedAt: String?

    public init(termsAccepted: Bool, termsAcceptedAt: String? = nil) {
        self.termsAccepted = termsAccepted
        self.termsAcceptedAt = termsAcceptedAt
    }

    public func domainModel() -> TermsAcceptanceStatus {
        TermsAcceptanceStatus(
            accepted: termsAccepted,
            acceptedAt: termsAcceptedAt.flatMap(Self.parseDate)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct TermsAcceptanceReceiptDTO: Codable, Equatable, Sendable {
    public var message: String?
    public var termsAcceptedAt: String?

    public init(message: String? = nil, termsAcceptedAt: String? = nil) {
        self.message = message
        self.termsAcceptedAt = termsAcceptedAt
    }

    public func domainModel() -> TermsAcceptanceStatus {
        TermsAcceptanceStatus(
            accepted: true,
            acceptedAt: TermsAcceptanceStatusDTO(
                termsAccepted: true,
                termsAcceptedAt: termsAcceptedAt
            ).domainModel().acceptedAt
        )
    }
}

public enum LibreChatAccountAccessAPI {
    public static func register(
        _ registration: AccountRegistration
    ) throws -> APIRequest<RegistrationResponseDTO> {
        try APIRequest(
            path: "api/auth/register",
            body: AccountRegistrationDTO(registration),
            authorization: .none,
            retryPolicy: .never
        )
    }

    public static func requestPasswordReset(
        email: String
    ) throws -> APIRequest<PasswordResetRequestResponseDTO> {
        try APIRequest(
            path: "api/auth/requestPasswordReset",
            body: PasswordResetRequestDTO(email: email),
            authorization: .none,
            retryPolicy: .never
        )
    }

    public static func completePasswordReset(
        _ completion: PasswordResetCompletion
    ) throws -> APIRequest<PasswordResetCompletionResponseDTO> {
        try APIRequest(
            path: "api/auth/resetPassword",
            body: PasswordResetCompletionDTO(completion),
            authorization: .none,
            retryPolicy: .never
        )
    }

    public static func verifyEmail(
        _ verification: EmailVerification
    ) throws -> APIRequest<EmailVerificationResponseDTO> {
        try APIRequest(
            path: "api/user/verify",
            body: EmailVerificationDTO(verification),
            authorization: .none,
            retryPolicy: .never
        )
    }

    public static func resendEmailVerification(
        email: String
    ) throws -> APIRequest<EmailVerificationResendResponseDTO> {
        try APIRequest(
            path: "api/user/verify/resend",
            body: EmailVerificationResendDTO(email: email),
            authorization: .none,
            retryPolicy: .never
        )
    }

    public static func termsAcceptanceStatus() -> APIRequest<TermsAcceptanceStatusDTO> {
        APIRequest(
            path: "api/user/terms",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func acceptTerms() -> APIRequest<TermsAcceptanceReceiptDTO> {
        APIRequest(
            method: .post,
            path: "api/user/terms/accept",
            authorization: .bearer,
            retryPolicy: .never
        )
    }
}
