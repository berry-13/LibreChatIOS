import Foundation
import LibreChatProtocol

/// The resume action is single-winner. Once its POST has been dispatched, any
/// response failure is ambiguous until the exact generation/action is
/// reconciled. Keeping the dispatch stage in the error prevents a generic
/// HTTP 4xx classifier from turning an already-dispatched action into a safe
/// retry.
enum PendingInteractionResponseError: LocalizedError, Equatable, Sendable {
    case postDispatch(LibreChatProtocolError)

    var underlying: LibreChatProtocolError {
        switch self {
        case let .postDispatch(error): error
        }
    }

    var errorDescription: String? { underlying.errorDescription }
}

extension Error {
    var isUnauthorized: Bool {
        if self as? LibreChatProtocolError == .unauthorized { return true }
        if let pending = self as? PendingInteractionResponseError,
           pending.underlying == .unauthorized {
            return true
        }
        return false
    }

    var userFacingMessage: String {
        if self is CancellationError {
            return "Cancelled."
        }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }

    /// A local pre-dispatch validation/encoding failure or a non-conflict 4xx
    /// returned directly by a preflight operation did not ambiguously consume
    /// LibreChat's single-winner resume action. Post-dispatch failures are
    /// wrapped above and must reconcile before the UI can offer another submit.
    var isSafeToRetryPendingInteraction: Bool {
        // This wrapper is only produced after the resume POST was dispatched.
        // Its underlying status is deliberately not eligible for a blind
        // second submission (including non-conflict 4xx responses).
        if self is PendingInteractionResponseError { return false }
        guard let protocolError = self as? LibreChatProtocolError else { return false }
        switch protocolError {
        case .unsupported, .encoding:
            return true
        case let .httpStatus(status, _, _):
            return (400...499).contains(status) && status != 409
        case .unauthorized, .transport, .serverNotReady, .generationConflict,
             .decoding, .invalidResponse, .keychain:
            return false
        }
    }
}
