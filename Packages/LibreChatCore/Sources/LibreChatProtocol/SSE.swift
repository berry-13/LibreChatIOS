import Foundation

public struct ServerSentEvent: Codable, Equatable, Sendable {
    public var event: String?
    public var id: String?
    public var retry: Int?
    public var data: String

    public init(event: String? = nil, id: String? = nil, retry: Int? = nil, data: String) {
        self.event = event
        self.id = id
        self.retry = retry
        self.data = data
    }
}

public struct SSEDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var scanIndex = 0

    public init() {}

    /// A single SSE frame may legitimately carry a large tool payload, but an
    /// unterminated frame must not grow for the lifetime of the stream.
    static let maximumFrameBytes = 1_048_576

    public mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        buffer.append(contentsOf: data)
        guard buffer.count <= Self.maximumFrameBytes else {
            buffer.removeAll()
            scanIndex = 0
            throw LibreChatProtocolError.unsupported(
                "The server sent an event frame larger than \(Self.maximumFrameBytes) bytes."
            )
        }
        var events: [ServerSentEvent] = []

        while let delimiter = nextDelimiter() {
            let frame = Data(buffer.prefix(delimiter.offset))
            buffer.removeFirst(delimiter.offset + delimiter.length)
            scanIndex = 0
            if let event = parse(frame) {
                events.append(event)
            }
        }
        return events
    }

    private mutating func nextDelimiter() -> (offset: Int, length: Int)? {
        guard !buffer.isEmpty else { return nil }
        for index in scanIndex..<buffer.count {
            if index + 3 < buffer.count,
               buffer[index] == 13, buffer[index + 1] == 10,
               buffer[index + 2] == 13, buffer[index + 3] == 10 {
                return (index, 4)
            }
            if index + 1 < buffer.count,
               (buffer[index] == 10 && buffer[index + 1] == 10
                || buffer[index] == 13 && buffer[index + 1] == 13) {
                return (index, 2)
            }
        }
        scanIndex = max(buffer.count - 3, 0)
        return nil
    }

    private func parse(_ frame: Data) -> ServerSentEvent? {
        let raw = String(decoding: frame, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result = ServerSentEvent(data: "")
        var dataLines: [String] = []
        var hasField = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0])
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event":
                result.event = value
                hasField = true
            case "id":
                if !value.contains("\0") { result.id = value }
                hasField = true
            case "retry":
                result.retry = Int(value)
                hasField = true
            case "data":
                dataLines.append(value)
                hasField = true
            default:
                continue
            }
        }
        result.data = dataLines.joined(separator: "\n")
        return hasField ? result : nil
    }
}

public protocol EventStreamTransport: Sendable {
    func events(request: URLRequest) async -> AsyncThrowingStream<ServerSentEvent, Error>
}

public actor URLSessionEventStreamTransport: EventStreamTransport {
    private let session: URLSession
    private let observability: ProtocolObservability

    public init(
        // Shares the development User-Agent policy with `HTTPTransport.live`
        // so streaming chat requests are not rejected by the server's
        // non-browser middleware (see `UserAgentPolicy`).
        session: URLSession = URLSession(configuration: UserAgentPolicy.makeConfiguration()),
        observability: ProtocolObservability = .disabled
    ) {
        self.session = session
        self.observability = observability
    }

    public func events(request: URLRequest) async -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw LibreChatProtocolError.invalidResponse
                    }
                    guard (200..<300).contains(response.statusCode) else {
                        throw LibreChatProtocolError.httpStatus(
                            response.statusCode,
                            message: nil,
                            retryAfter: Self.retryAfter(response)
                        )
                    }
                    // An expired session can be redirected to the browser
                    // login page, which URLSession follows to a final 200.
                    // Surfacing HTML as an unauthorized failure lets the
                    // reconciliation refresh or expire the session instead
                    // of reconnecting to a page that will never stream.
                    let finalURL = response.url ?? request.url
                    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                    if Self.isBrowserLoginRedirect(finalURL)
                        || contentType?.contains("text/html") == true {
                        throw LibreChatProtocolError.unauthorized
                    }
                    observability.record(.eventStreamOpened(
                        route: ProtocolRoute.classify(path: request.url?.path ?? ""),
                        status: response.statusCode
                    ))
                    var decoder = SSEDecoder()
                    // Feed the decoder line-sized chunks instead of single
                    // bytes: an SSE event only completes at its terminating
                    // newline, so flushing on newlines preserves event timing
                    // while avoiding a decoder call per streamed byte.
                    var lineBuffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        lineBuffer.append(byte)
                        if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                            for event in try decoder.append(lineBuffer) {
                                continuation.yield(event)
                            }
                            lineBuffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !lineBuffer.isEmpty {
                        for event in try decoder.append(lineBuffer) {
                            continuation.yield(event)
                        }
                    }
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

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        // Clamp server-controlled values so downstream Int conversions
        // cannot trap on absurd values like 1e309.
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw), seconds.isFinite else {
            return nil
        }
        return min(max(seconds, 0), 86_400)
    }

    /// Mirrors `AuthSession.isBrowserLoginRedirect`: LibreChat's sign-in page
    /// is served outside the API namespace.
    private static func isBrowserLoginRedirect(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.lastPathComponent == "login" && !url.path.contains("/api/auth/")
    }
}
