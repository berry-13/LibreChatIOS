import Foundation

/// An in-memory avatar upload. Profile images are deliberately never written
/// to the conversation cache or a credential store.
public struct AccountAvatarUpload: Equatable, Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public enum AccountProfileError: LocalizedError, Equatable, Sendable {
    case accountMismatch
    case invalidAvatar
    case avatarTooLarge(maximumBytes: Int)
    case unsupportedAvatarFormat
    case invalidAvatarResponse
    /// The upload was dispatched, but an authoritative account read could
    /// not prove whether the server committed it. Callers must not replay the
    /// multipart upload automatically.
    case avatarOutcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .accountMismatch:
            "LibreChat returned a different account. Sign in again before changing account data."
        case .invalidAvatar:
            "Choose a valid profile image."
        case let .avatarTooLarge(maximumBytes):
            if maximumBytes <= 0 {
                "Profile image uploads are disabled by this server."
            } else {
                "Choose an image no larger than \(maximumBytes / 1_048_576) MB."
            }
        case .unsupportedAvatarFormat:
            "Choose a PNG or JPEG image."
        case .invalidAvatarResponse:
            "LibreChat did not confirm the new profile image."
        case .avatarOutcomeUnknown:
            "LibreChat may have updated the profile image, but the app could not confirm it. Refresh the account before trying again."
        }
    }
}

/// Account deletion is intentionally one-shot. Delivery uncertainty never
/// becomes a retryable generic transport error because the server may already
/// have deleted the account and all of its sessions.
public enum AccountDeletionError: LocalizedError, Equatable, Sendable {
    case verificationRequired
    case verificationRejected
    case notPermitted
    case outcomeUnknown
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .verificationRequired:
            "Enter an authenticator code or backup code before deleting this account."
        case .verificationRejected:
            "LibreChat did not accept that verification code."
        case .notPermitted:
            "This server does not allow this account to be deleted here."
        case .outcomeUnknown:
            "LibreChat may have deleted the account, but the app could not confirm it. Do not submit the deletion again; sign in to check the account state."
        case .invalidResponse:
            "LibreChat did not return a valid account-deletion confirmation."
        }
    }
}
