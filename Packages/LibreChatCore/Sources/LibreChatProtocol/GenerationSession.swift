import Foundation
import LibreChatDomain

public actor GenerationSession {
    private let transport: any EventStreamTransport
    private let decoder: LibreChatGenerationDecoder
    private var reducers: [GenerationHandle: GenerationReducer] = [:]

    public init(
        transport: any EventStreamTransport,
        decoder: LibreChatGenerationDecoder = LibreChatGenerationDecoder()
    ) {
        self.transport = transport
        self.decoder = decoder
    }

    public func install(_ snapshot: GenerationSnapshot) {
        reducers[snapshot.handle] = GenerationReducer(handle: snapshot.handle, snapshot: snapshot)
    }

    public func apply(_ event: SequencedGenerationEvent, to handle: GenerationHandle) -> GenerationSnapshot {
        var reducer = reducers[handle] ?? GenerationReducer(handle: handle)
        let snapshot = reducer.apply(event)
        reducers[handle] = reducer
        return snapshot
    }

    public func snapshot(for handle: GenerationHandle) -> GenerationSnapshot? {
        reducers[handle]?.snapshot
    }

    public func detach(_ handle: GenerationHandle) {
        reducers.removeValue(forKey: handle)
    }

    public func snapshots(
        request: URLRequest,
        handle: GenerationHandle
    ) async -> AsyncThrowingStream<GenerationSnapshot, Error> {
        if reducers[handle] == nil {
            reducers[handle] = GenerationReducer(handle: handle)
        }
        let upstream = await transport.events(request: request)
        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastPublication = Date.distantPast
                var pendingSnapshot: GenerationSnapshot?
                do {
                    for try await serverEvent in upstream {
                        try Task.checkCancellation()
                        let events = decoder.decode(serverEvent, conversationID: handle.conversationID)
                        for event in events {
                            let snapshot = self.apply(event, to: handle)
                            let now = Date()
                            if event.event.requiresImmediatePublication
                                || now.timeIntervalSince(lastPublication) >= 0.05 {
                                continuation.yield(snapshot)
                                pendingSnapshot = nil
                                lastPublication = now
                            } else {
                                pendingSnapshot = snapshot
                            }
                        }
                    }
                    if let pendingSnapshot { continuation.yield(pendingSnapshot) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
