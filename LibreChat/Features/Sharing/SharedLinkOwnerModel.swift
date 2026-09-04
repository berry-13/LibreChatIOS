import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation

/// UI state for the authenticated owner's shared-link lifecycle.
///
/// Shared snapshots deliberately remain outside the conversation cache: the
/// public representation uses per-response pseudonymous identifiers and is
/// not canonical chat history.
@MainActor
@Observable
final class SharedLinkOwnerModel {
    enum State: Equatable {
        case idle
        case loading
        case absent
        case available
        case failed(String)
    }

    let conversationID: ConversationID
    private let baseURL: URL
    private let repository: any SharedLinkRepository
    private let onUnauthorized: @MainActor () async -> Void

    private(set) var state: State = .idle
    private(set) var link: SharedLink?
    private(set) var isWorking = false
    private(set) var operationError: String?

    init(
        conversationID: ConversationID,
        baseURL: URL,
        repository: any SharedLinkRepository,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.conversationID = conversationID
        self.baseURL = baseURL
        self.repository = repository
        self.onUnauthorized = onUnauthorized
    }

    var shareURL: URL? {
        guard let shareID = link?.shareID else { return nil }
        return baseURL
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent(shareID.rawValue, isDirectory: false)
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard !isWorking else { return }
        isWorking = true
        state = .loading
        operationError = nil
        defer { isWorking = false }
        do {
            let result = try await repository.sharedLink(for: conversationID)
            install(result.link)
        } catch {
            await handle(error)
        }
    }

    @discardableResult
    func create(targetMessageID: MessageID?, snapshotFiles: Bool = false) async -> URL? {
        guard !isWorking, link == nil else { return shareURL }
        isWorking = true
        operationError = nil
        defer { isWorking = false }
        do {
            let result = try await repository.createSharedLink(
                for: conversationID,
                request: SharedLinkPublishRequest(
                    targetMessageID: targetMessageID,
                    snapshotFiles: snapshotFiles
                )
            )
            install(link(from: result))
            return shareURL
        } catch let error as LibreChatProtocolError where error.hasHTTPStatus(409) {
            // A concurrent client may have created the link first. Re-read the
            // authoritative owner state instead of fabricating an identifier.
            do {
                let result = try await repository.sharedLink(for: conversationID)
                install(result.link)
                return shareURL
            } catch {
                await handle(error)
                return nil
            }
        } catch {
            await handle(error)
            return nil
        }
    }

    @discardableResult
    func refresh(targetMessageID: MessageID?, snapshotFiles: Bool = false) async -> URL? {
        guard !isWorking, let current = link else { return nil }
        isWorking = true
        operationError = nil
        defer { isWorking = false }
        do {
            let result = try await repository.updateSharedLink(
                current.shareID,
                request: SharedLinkPublishRequest(
                    targetMessageID: targetMessageID,
                    snapshotFiles: snapshotFiles
                )
            )
            install(link(from: result, snapshotFiles: snapshotFiles))
            return shareURL
        } catch let error as LibreChatProtocolError where error.hasHTTPStatus(404) {
            // The server proves the snapshot was deleted or expired. Keeping
            // its URL available would present a known-dead link as active.
            install(nil)
            return nil
        } catch {
            await handle(error, preservingAvailableLink: true)
            return nil
        }
    }

    @discardableResult
    func revoke() async -> Bool {
        guard !isWorking, let current = link else { return false }
        isWorking = true
        operationError = nil
        defer { isWorking = false }
        do {
            _ = try await repository.deleteSharedLink(current.shareID)
            install(nil)
            return true
        } catch let error as LibreChatProtocolError where error.hasHTTPStatus(404) {
            // The user explicitly confirmed revocation and the server proves
            // the link is already absent.
            install(nil)
            return true
        } catch {
            await handle(error, preservingAvailableLink: true)
            return false
        }
    }

    private func install(_ link: SharedLink?) {
        self.link = link
        operationError = nil
        state = link == nil ? .absent : .available
    }

    private func link(
        from result: SharedLinkMutationResult,
        snapshotFiles: Bool? = nil
    ) -> SharedLink {
        SharedLink(
            shareID: result.shareID,
            resourceID: result.resourceID,
            conversationID: result.conversationID,
            targetMessageID: result.targetMessageID,
            snapshotFiles: snapshotFiles
        )
    }

    private func handle(_ error: Error, preservingAvailableLink: Bool = false) async {
        guard !(error is CancellationError) else { return }
        if error.isUnauthorized { await onUnauthorized() }
        let message = if let protocolError = error as? LibreChatProtocolError,
                         protocolError.hasHTTPStatus(403) {
            "Your LibreChat role does not allow creating or updating shared links."
        } else {
            error.userFacingMessage
        }
        operationError = message
        state = preservingAvailableLink && link != nil ? .available : .failed(message)
    }
}

private extension LibreChatProtocolError {
    func hasHTTPStatus(_ expectedStatus: Int) -> Bool {
        guard case let .httpStatus(status, _, _) = self else { return false }
        return status == expectedStatus
    }
}
