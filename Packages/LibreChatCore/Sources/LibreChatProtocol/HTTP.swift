import Foundation
import LibreChatDomain

public struct GenerationConflictDetails: Codable, Equatable, Sendable {
    public var code: String?
    public var status: String?
    public var streamID: String?
    public var conversationID: String?
    public var generationCreatedAt: Int64?
    public var predecessorVerified: Bool?
    public var active: Bool?
    public var generationProtocolVersion: Int?
    public var message: String?

    public init(
        code: String? = nil,
        status: String? = nil,
        streamID: String? = nil,
        conversationID: String? = nil,
        generationCreatedAt: Int64? = nil,
        predecessorVerified: Bool? = nil,
        active: Bool? = nil,
        generationProtocolVersion: Int? = nil,
        message: String? = nil
    ) {
        self.code = code
        self.status = status
        self.streamID = streamID
        self.conversationID = conversationID
        self.generationCreatedAt = generationCreatedAt
        self.predecessorVerified = predecessorVerified
        self.active = active
        self.generationProtocolVersion = generationProtocolVersion
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code, status, predecessorVerified, active, generationProtocolVersion
        case streamID = "streamId"
        case conversationID = "conversationId"
        case generationCreatedAt
        case message
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        streamID = try container.decodeIfPresent(String.self, forKey: .streamID)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        generationCreatedAt = try container.decodeIfPresent(Int64.self, forKey: .generationCreatedAt)
        predecessorVerified = try container.decodeIfPresent(Bool.self, forKey: .predecessorVerified)
        active = try container.decodeIfPresent(Bool.self, forKey: .active)
        generationProtocolVersion = try container.decodeIfPresent(Int.self, forKey: .generationProtocolVersion)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? (try container.decodeIfPresent(String.self, forKey: .error))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(streamID, forKey: .streamID)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(generationCreatedAt, forKey: .generationCreatedAt)
        try container.encodeIfPresent(predecessorVerified, forKey: .predecessorVerified)
        try container.encodeIfPresent(active, forKey: .active)
        try container.encodeIfPresent(generationProtocolVersion, forKey: .generationProtocolVersion)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

public enum LibreChatProtocolError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case httpStatus(Int, message: String?, retryAfter: TimeInterval?)
    case serverNotReady(retryAfter: TimeInterval?)
    case generationConflict(GenerationConflictDetails)
    case decoding(String)
    case encoding(String)
    case transport(String)
    case unsupported(String)
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "LibreChat returned an invalid response."
        case .unauthorized:
            "Your LibreChat session is no longer valid."
        case let .httpStatus(status, message, _):
            message?.isEmpty == false ? message : "LibreChat returned HTTP status \(status)."
        case .serverNotReady:
            "LibreChat is still preparing this generation. Please try again shortly."
        case let .generationConflict(details):
            details.message ?? "A newer response already owns this conversation. Your message was not sent."
        case let .decoding(message):
            "LibreChat returned data this app could not read. \(message)"
        case let .encoding(message):
            "The request could not be encoded. \(message)"
        case let .transport(message):
            "Could not reach LibreChat. \(message)"
        case let .unsupported(message):
            message
        case let .keychain(status):
            "Keychain operation failed with status \(status)."
        }
    }
}

public enum HTTPMethod: String, Codable, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public enum AuthorizationRequirement: Codable, Equatable, Sendable {
    case none
    case bearer
}

public enum RequestRetryPolicy: Codable, Equatable, Sendable {
    case never
    case idempotent(maximumAttempts: Int)
}

public struct APIRequest<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    /// Optional raw path segments. When present, transport appends each
    /// segment independently so a value such as `a/b %` is encoded once and
    /// cannot become multiple URL path segments.
    public var pathComponents: [String]?
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    public var authorization: AuthorizationRequirement
    public var retryPolicy: RequestRetryPolicy

    public init(
        method: HTTPMethod = .get,
        path: String,
        pathComponents: [String]? = nil,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        authorization: AuthorizationRequirement = .bearer,
        retryPolicy: RequestRetryPolicy = .idempotent(maximumAttempts: 2)
    ) {
        self.method = method
        self.path = path
        self.pathComponents = pathComponents
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.authorization = authorization
        self.retryPolicy = retryPolicy
    }

    public init<Body: Encodable & Sendable>(
        method: HTTPMethod = .post,
        path: String,
        pathComponents: [String]? = nil,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Body,
        authorization: AuthorizationRequirement = .bearer,
        retryPolicy: RequestRetryPolicy = .never,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.method = method
        self.path = path
        self.pathComponents = pathComponents
        self.queryItems = queryItems
        self.headers = headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        self.body = try encoder.encode(body)
        self.authorization = authorization
        self.retryPolicy = retryPolicy
    }
}

public struct EmptyResponse: Codable, Equatable, Sendable {
    public init() {}
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL

    public init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }
}

/// A disk-backed HTTP response used for user-initiated file transfers. The
/// transport moves Foundation's short-lived download location into an
/// app-private staging directory before returning. Callers own that staging
/// file and must either move it into their cache or remove it.
public struct HTTPDownloadResponse: Sendable {
    public var localURL: URL
    public var statusCode: Int
    public var headers: [String: String]
    public var finalURL: URL

    public init(localURL: URL, statusCode: Int, headers: [String: String], finalURL: URL) {
        self.localURL = localURL
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }
}

/// User-Agent policy shared by every URLSession the app creates.
///
/// LibreChat's `uaParser` middleware treats any User-Agent that ua-parser-js
/// cannot parse as a browser as a NON_BROWSER violation (default score 20 =
/// an instant 2-hour IP + account ban). URLSession's default UA
/// (`LibreChat/1 CFNetwork/... Darwin/...`) triggers it on the first
/// chat/files/agents request, so every build configuration sends a
/// browser-parseable Safari-profile UA. The trailing `LibreChatiOS` token
/// identifies the native client without affecting ua-parser-js's browser
/// detection (its unanchored `Version/… Mobile/… Safari/…` regexes match
/// before the token is considered).
public enum UserAgentPolicy {
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 "
        + "Safari/604.1 LibreChatiOS/1.0"

    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": browserUserAgent]
        return configuration
    }
}

public actor HTTPTransport {
    public let baseURL: URL
    private let session: URLSession
    private let cookieJar: ProfileCookieJar
    private let observability: ProtocolObservability

    public init(
        baseURL: URL,
        session: URLSession,
        cookieJar: ProfileCookieJar,
        observability: ProtocolObservability = .disabled
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieJar = cookieJar
        self.observability = observability
    }

    public static func live(
        baseURL: URL,
        cookieJar: ProfileCookieJar,
        observability: ProtocolObservability = .disabled
    ) -> HTTPTransport {
        let configuration = UserAgentPolicy.makeConfiguration()
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 30
        return HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: cookieJar,
            observability: observability
        )
    }

    public func request(
        method: HTTPMethod,
        path: String,
        pathComponents: [String]? = nil,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        baseURL: URL? = nil
    ) async throws -> URLRequest {
        var url = baseURL ?? self.baseURL
        if let pathComponents {
            for component in pathComponents {
                url = try Self.appendingEncodedPathComponent(component, to: url)
            }
        } else {
            for component in path.split(separator: "/") {
                url.append(path: String(component))
            }
        }
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let cookie = await cookieJar.cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private static func appendingEncodedPathComponent(_ component: String, to url: URL) throws -> URL {
        // Dot-only segments survive the percent-encoding allowlist unchanged
        // and normalize to parent routes on the server; identifiers are
        // opaque data and may never act as traversal.
        guard component != ".", component != ".." else {
            throw LibreChatProtocolError.encoding("The request path component is not usable.")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw LibreChatProtocolError.encoding("The request path could not be encoded safely.")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LibreChatProtocolError.encoding("The request URL could not be constructed safely.")
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + encoded
        guard let result = components.url else {
            throw LibreChatProtocolError.encoding("The request URL could not be constructed safely.")
        }
        return result
    }

    /// Largest REST response body that may be buffered in memory. Real API
    /// payloads (DTOs, search pages) sit far below this; the cap only exists
    /// so a hostile or misconfigured server cannot exhaust the process
    /// before validation runs.
    static let maximumBufferedResponseBytes = 64 * 1_048_576

    /// Streams the response body to a staged file, enforcing the byte cap
    /// while bytes arrive — `URLSession.download(for:)` would only surface
    /// an oversized body after it had already been written in full.
    private func boundedDownload(
        request: URLRequest
    ) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LibreChatProtocolError.invalidResponse
        }
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatHTTPDownloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let stagedURL = stagingDirectory.appending(path: UUID().uuidString)
        try Data().write(to: stagedURL)
        let fileHandle = try FileHandle(forWritingTo: stagedURL)
        do {
            var buffered = Data()
            buffered.reserveCapacity(256 * 1_024)
            var written = 0
            for try await byte in bytes {
                buffered.append(byte)
                written += 1
                if buffered.count >= 256 * 1_024 {
                    try fileHandle.write(contentsOf: buffered)
                    buffered.removeAll(keepingCapacity: true)
                }
                if written > Self.maximumStagedDownloadBytes {
                    try? fileHandle.close()
                    try? FileManager.default.removeItem(at: stagedURL)
                    throw LibreChatProtocolError.unsupported(
                        "That download exceeds the \(Self.maximumStagedDownloadBytes) byte limit."
                    )
                }
            }
            if !buffered.isEmpty {
                try fileHandle.write(contentsOf: buffered)
            }
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return (stagedURL, http)
    }

    /// Buffers the response body incrementally so oversized bodies are
    /// rejected without ever materializing them, including when the server
    /// omits `Content-Length`.
    private func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(256 * 1_024)
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumBufferedResponseBytes {
                throw LibreChatProtocolError.unsupported(
                    "The server response exceeded \(Self.maximumBufferedResponseBytes) bytes."
                )
            }
        }
        return (data, response)
    }

    public func execute(_ request: URLRequest, attempt: Int = 1) async throws -> HTTPResponse {
        let route = ProtocolRoute.classify(path: request.url?.path ?? "")
        let method = HTTPMethod(rawValue: request.httpMethod ?? "") ?? .get
        observability.record(.transportStarted(route: route, method: method, attempt: attempt))
        do {
            let (data, response) = try await boundedData(for: request)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw LibreChatProtocolError.invalidResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            await cookieJar.absorb(responseHeaders: headers, for: finalURL)
            observability.record(.transportResponded(
                route: route,
                method: method,
                status: response.statusCode,
                attempt: attempt
            ))
            return HTTPResponse(
                data: data,
                statusCode: response.statusCode,
                headers: headers,
                finalURL: finalURL
            )
        } catch let error as LibreChatProtocolError {
            let failure: ProtocolTransportFailure = switch error {
            case .invalidResponse: .invalidResponse
            case .transport: .connectivity
            default: .protocolFailure
            }
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: failure
            ))
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                observability.record(.transportFailed(
                    route: route,
                    method: method,
                    attempt: attempt,
                    failure: .cancelled
                ))
                throw CancellationError()
            }
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .connectivity
            ))
            throw LibreChatProtocolError.transport(error.localizedDescription)
        } catch is CancellationError {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .cancelled
            ))
            throw CancellationError()
        } catch {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .protocolFailure
            ))
            throw LibreChatProtocolError.transport(error.localizedDescription)
        }
    }

    /// Downloads bytes without materializing the complete response in memory.
    /// The returned URL has a random name and contains no server/profile/file
    /// identifiers. Error bodies are interpreted later by `RESTClient` and the
    /// staging file is removed on every failed or retried attempt.
    /// Largest body a file download may stage. The composer accepts 200 MiB
    /// imports and the upload contract allows 512 MiB server-side, so the
    /// bound must cover files the app itself accepts, not just images.
    static let maximumStagedDownloadBytes = 256 * 1_048_576

    public func executeDownload(
        _ request: URLRequest,
        attempt: Int = 1
    ) async throws -> HTTPDownloadResponse {
        let route = ProtocolRoute.classify(path: request.url?.path ?? "")
        let method = HTTPMethod(rawValue: request.httpMethod ?? "") ?? .get
        observability.record(.transportStarted(route: route, method: method, attempt: attempt))
        do {
            let (stagedURL, response) = try await boundedDownload(request: request)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw LibreChatProtocolError.invalidResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            await cookieJar.absorb(responseHeaders: headers, for: finalURL)

            observability.record(.transportResponded(
                route: route,
                method: method,
                status: response.statusCode,
                attempt: attempt
            ))
            return HTTPDownloadResponse(
                localURL: stagedURL,
                statusCode: response.statusCode,
                headers: headers,
                finalURL: finalURL
            )
        } catch let error as LibreChatProtocolError {
            let failure: ProtocolTransportFailure = switch error {
            case .invalidResponse: .invalidResponse
            case .transport: .connectivity
            default: .protocolFailure
            }
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: failure
            ))
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                observability.record(.transportFailed(
                    route: route,
                    method: method,
                    attempt: attempt,
                    failure: .cancelled
                ))
                throw CancellationError()
            }
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .connectivity
            ))
            throw LibreChatProtocolError.transport(error.localizedDescription)
        } catch is CancellationError {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .cancelled
            ))
            throw CancellationError()
        } catch {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .protocolFailure
            ))
            throw LibreChatProtocolError.transport(error.localizedDescription)
        }
    }

    /// Uploads `body` while reporting real byte-level send progress. The
    /// request must already carry its Cookie and Authorization headers (built
    /// through `request(...)` + the caller's bearer step); response cookies are
    /// absorbed exactly like `execute`. Progress is delivered on an arbitrary
    /// queue and clamped to 0…1 of the expected byte count.
    public func executeUpload(
        _ request: URLRequest,
        body: Data,
        attempt: Int = 1,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPResponse {
        let route = ProtocolRoute.classify(path: request.url?.path ?? "")
        let method = HTTPMethod(rawValue: request.httpMethod ?? "") ?? .post
        observability.record(.transportStarted(route: route, method: method, attempt: attempt))
        let delegate = UploadTaskDelegate(progress: progress)
        return try await executeUploadWithDelegate(
            delegate,
            request: request,
            route: route,
            method: method,
            attempt: attempt,
            progress: progress,
            body: body,
            bodyFileURL: nil
        )
    }

    /// Streams the upload body from disk; near-ceiling attachments never
    /// materialize the multipart request in memory.
    public func executeUpload(
        _ request: URLRequest,
        bodyFileURL: URL,
        attempt: Int = 1,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPResponse {
        let route = ProtocolRoute.classify(path: request.url?.path ?? "")
        let method = HTTPMethod(rawValue: request.httpMethod ?? "") ?? .post
        observability.record(.transportStarted(route: route, method: method, attempt: attempt))
        let delegate = UploadTaskDelegate(progress: progress)
        return try await executeUploadWithDelegate(
            delegate,
            request: request,
            route: route,
            method: method,
            attempt: attempt,
            progress: progress,
            body: nil,
            bodyFileURL: bodyFileURL
        )
    }

    private func executeUploadWithDelegate(
        _ delegate: UploadTaskDelegate,
        request: URLRequest,
        route: ProtocolRoute,
        method: HTTPMethod,
        attempt: Int,
        progress: @escaping @Sendable (Double) -> Void,
        body: Data?,
        bodyFileURL: URL?
    ) async throws -> HTTPResponse {
        // A delegate-bearing session is required for `didSendBodyData`. It is
        // cloned from the transport's own configuration — same stubbed
        // URLProtocols, cookies policy, and User-Agent — and created per
        // upload so no other task pays the delegate cost.
        let session = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        do {
            let data: Data
            if let bodyFileURL {
                data = try await delegate.upload(
                    session: session,
                    request: request,
                    bodyFileURL: bodyFileURL
                )
            } else if let body {
                data = try await delegate.upload(
                    session: session,
                    request: request,
                    body: body
                )
            } else {
                throw LibreChatProtocolError.encoding("An upload requires a request body.")
            }
            guard let response = delegate.response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw LibreChatProtocolError.invalidResponse
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                result[String(describing: pair.key)] = String(describing: pair.value)
            }
            await cookieJar.absorb(responseHeaders: headers, for: finalURL)
            observability.record(.transportResponded(
                route: route,
                method: method,
                status: response.statusCode,
                attempt: attempt
            ))
            return HTTPResponse(
                data: data,
                statusCode: response.statusCode,
                headers: headers,
                finalURL: finalURL
            )
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .cancelled
            ))
            throw CancellationError()
        } catch is CancellationError {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: .cancelled
            ))
            throw CancellationError()
        } catch {
            observability.record(.transportFailed(
                route: route,
                method: method,
                attempt: attempt,
                failure: error is LibreChatProtocolError ? .protocolFailure : .connectivity
            ))
            if let protocolError = error as? LibreChatProtocolError { throw protocolError }
            throw LibreChatProtocolError.transport(error.localizedDescription)
        }
    }

    public func clearCookies() async throws {
        try await cookieJar.clear()
    }
}

/// Bridges URLSession's delegate callbacks onto async/await for one upload
/// task, forwarding `didSendBodyData` as 0…1 progress.
private final class UploadTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private(set) var response: URLResponse?
    /// URLSession deliver responses/cookies on its queue; serializing every
    /// access through one queue keeps the buffer and continuation safe without
    /// locking.
    private let queue = DispatchQueue(label: "librechat.upload.delegate")

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func upload(
        session: URLSession,
        request: URLRequest,
        body: Data
    ) async throws -> Data {
        let task = session.uploadTask(with: request, from: body)
        return try await awaitUpload(task)
    }

    /// Streams the multipart body from a staged file so large uploads never
    /// materialize the request body in memory.
    func upload(
        session: URLSession,
        request: URLRequest,
        bodyFileURL: URL
    ) async throws -> Data {
        let task = session.uploadTask(with: request, fromFile: bodyFileURL)
        return try await awaitUpload(task)
    }

    private func awaitUpload(_ task: URLSessionUploadTask) async throws -> Data {
        // A cancelled awaiting task must cancel the underlying upload task,
        // otherwise the request runs to completion server-side and the
        // completion handler resurrects a state the caller already tore down.
        return try await withTaskCancellationHandler {
            // The continuation is registered before `resume` so a completion that
            // races the suspension can never be dropped.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    self.continuation = continuation
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Attachment-upload responses are tiny JSON envelopes; anything larger
    /// is hostile or misconfigured and must not buffer indefinitely.
    static let maximumResponseBytes = 16 * 1_048_576

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let oversized = response.expectedContentLength > Self.maximumResponseBytes
        queue.async {
            self.response = response
        }
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        queue.async {
            self.buffer.append(data)
            guard self.buffer.count <= Self.maximumResponseBytes else {
                self.buffer.removeAll()
                dataTask.cancel()
                return
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: self.buffer)
            }
            self.buffer.removeAll()
        }
    }
}

public actor RESTClient {
    private let transport: HTTPTransport
    private let authSession: AuthSession
    private let decoder: JSONDecoder
    private let observability: ProtocolObservability

    public init(
        transport: HTTPTransport,
        authSession: AuthSession,
        decoder: JSONDecoder = JSONDecoder(),
        observability: ProtocolObservability = .disabled
    ) {
        self.transport = transport
        self.authSession = authSession
        self.decoder = decoder
        self.observability = observability
    }

    /// Sends a multipart upload request while streaming real byte progress.
    /// Uploads are single-attempt (`retryPolicy: .never`); a rejected bearer
    /// credential is refreshed exactly once before the request replays, and a
    /// 401 response fails without a second body submission.
    public func sendUpload<Response>(
        _ request: APIRequest<Response>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Response {
        precondition(request.retryPolicy == .never, "Uploads are single-attempt requests.")
        let route = ProtocolRoute.classify(path: request.path)
        observability.record(.transportStarted(route: route, method: request.method, attempt: 1))
        guard let body = request.body else {
            throw LibreChatProtocolError.encoding("An upload request is missing its body.")
        }
        var refreshed = false
        while true {
            var urlRequest = try await transport.request(
                method: request.method,
                path: request.path,
                pathComponents: request.pathComponents,
                queryItems: request.queryItems,
                headers: request.headers,
                body: nil
            )
            if request.authorization == .bearer {
                do {
                    let credential = try await authSession.authorizationCredential()
                    urlRequest.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
                } catch LibreChatProtocolError.unauthorized where !refreshed {
                    _ = try await authSession.refresh(ifRejected: nil)
                    refreshed = true
                    continue
                }
            }
            let response = try await transport.executeUpload(
                urlRequest,
                body: body,
                progress: progress
            )
            // A 401 after the body was submitted is surfaced as-is: the
            // request is non-idempotent and must never be replayed, because
            // the first submission may already have committed server-side.
            try Self.validate(response)
            do {
                return try decoder.decode(Response.self, from: response.data)
            } catch {
                throw LibreChatProtocolError.decoding(error.localizedDescription)
            }
        }
    }

    /// Streams a file-backed multipart upload with the same single-attempt,
    /// pre-dispatch-credential semantics as `sendUpload`.
    public func sendUploadFile<Response>(
        _ request: APIRequest<Response>,
        bodyFileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Response {
        precondition(request.retryPolicy == .never, "Uploads are single-attempt requests.")
        let route = ProtocolRoute.classify(path: request.path)
        observability.record(.transportStarted(route: route, method: request.method, attempt: 1))
        var refreshed = false
        while true {
            var urlRequest = try await transport.request(
                method: request.method,
                path: request.path,
                pathComponents: request.pathComponents,
                queryItems: request.queryItems,
                headers: request.headers,
                body: nil
            )
            if request.authorization == .bearer {
                do {
                    let credential = try await authSession.authorizationCredential()
                    urlRequest.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
                } catch LibreChatProtocolError.unauthorized where !refreshed {
                    _ = try await authSession.refresh(ifRejected: nil)
                    refreshed = true
                    continue
                }
            }
            let response = try await transport.executeUpload(
                urlRequest,
                bodyFileURL: bodyFileURL,
                progress: progress
            )
            // A 401 after the body was submitted is surfaced as-is: the
            // request is non-idempotent and must never be replayed.
            try Self.validate(response)
            do {
                return try decoder.decode(Response.self, from: response.data)
            } catch {
                throw LibreChatProtocolError.decoding(error.localizedDescription)
            }
        }
    }

    public func send<Response>(_ request: APIRequest<Response>) async throws -> Response {        let maximumAttempts: Int = switch request.retryPolicy {
        case .never: 1
        case let .idempotent(maximumAttempts): max(1, maximumAttempts)
        }

        var attempt = 0
        var refreshed = false
        var authorizationRecoveryPending = false
        let route = ProtocolRoute.classify(path: request.path)
        while true {
            attempt += 1
            do {
                var credential: AuthorizationCredential?
                var urlRequest = try await transport.request(
                    method: request.method,
                    path: request.path,
                    pathComponents: request.pathComponents,
                    queryItems: request.queryItems,
                    headers: request.headers,
                    body: request.body
                )
                if request.authorization == .bearer {
                    do {
                        let currentCredential = try await authSession.authorizationCredential()
                        credential = currentCredential
                        urlRequest.setValue(currentCredential.headerValue, forHTTPHeaderField: "Authorization")
                    } catch LibreChatProtocolError.unauthorized where !refreshed {
                        _ = try await authSession.refresh(ifRejected: nil)
                        refreshed = true
                        continue
                    }
                }

                let response = try await transport.execute(urlRequest, attempt: attempt)
                if request.authorization == .bearer,
                   (response.statusCode == 401 || Self.isBrowserLoginRedirect(response.finalURL)),
                   !refreshed,
                   Self.allowsAuthorizationReplay(
                       method: request.method,
                       retryPolicy: request.retryPolicy
                   ) {
                    observability.record(.authorizationRecoveryStarted(
                        route: route,
                        method: request.method
                    ))
                    do {
                        _ = try await authSession.refresh(ifRejected: credential)
                    } catch {
                        observability.record(.authorizationRecoveryCompleted(
                            route: route,
                            method: request.method,
                            outcome: .failed
                        ))
                        throw error
                    }
                    refreshed = true
                    authorizationRecoveryPending = true
                    continue
                }
                try Self.validate(response)
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: request.method,
                        outcome: .succeeded
                    ))
                    authorizationRecoveryPending = false
                }
                if Response.self == EmptyResponse.self, response.data.isEmpty {
                    return EmptyResponse() as! Response
                }
                do {
                    return try decoder.decode(Response.self, from: response.data)
                } catch {
                    throw LibreChatProtocolError.decoding(error.localizedDescription)
                }
            } catch is CancellationError {
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: request.method,
                        outcome: .failed
                    ))
                }
                throw CancellationError()
            } catch let error as LibreChatProtocolError {
                if case .transport = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: request.method,
                        nextAttempt: attempt + 1
                    ))
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                    continue
                }
                if case let .serverNotReady(retryAfter) = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: request.method,
                        nextAttempt: attempt + 1
                    ))
                    let delay = Self.boundedRetryDelay(retryAfter, fallback: TimeInterval(attempt))
                    try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                    continue
                }
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: request.method,
                        outcome: .failed
                    ))
                }
                throw error
            }
        }
    }

    public func rawResponse(
        method: HTTPMethod,
        path: String,
        pathComponents: [String]? = nil,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool,
        retryPolicy: RequestRetryPolicy = .never
    ) async throws -> HTTPResponse {
        let maximumAttempts: Int = switch retryPolicy {
        case .never: 1
        case let .idempotent(maximumAttempts): max(1, maximumAttempts)
        }
        var attempt = 0
        var refreshed = false
        var authorizationRecoveryPending = false
        let route = pathComponents.map {
            ProtocolRoute.classify(path: $0.joined(separator: "/"))
        } ?? ProtocolRoute.classify(path: path)

        while true {
            attempt += 1
            do {
                var credential: AuthorizationCredential?
                var request = try await transport.request(
                    method: method,
                    path: path,
                    pathComponents: pathComponents,
                    queryItems: queryItems,
                    headers: headers,
                    body: body
                )
                if authorized {
                    do {
                        let current = try await authSession.authorizationCredential()
                        credential = current
                        request.setValue(current.headerValue, forHTTPHeaderField: "Authorization")
                    } catch LibreChatProtocolError.unauthorized where !refreshed {
                        _ = try await authSession.refresh(ifRejected: nil)
                        refreshed = true
                        continue
                    }
                }

                let response = try await transport.execute(request, attempt: attempt)
                if authorized,
                   (response.statusCode == 401 || Self.isBrowserLoginRedirect(response.finalURL)),
                   !refreshed,
                   Self.allowsAuthorizationReplay(method: method, retryPolicy: retryPolicy) {
                    observability.record(.authorizationRecoveryStarted(route: route, method: method))
                    do {
                        _ = try await authSession.refresh(ifRejected: credential)
                    } catch {
                        observability.record(.authorizationRecoveryCompleted(
                            route: route,
                            method: method,
                            outcome: .failed
                        ))
                        throw error
                    }
                    refreshed = true
                    authorizationRecoveryPending = true
                    continue
                }
                try Self.validate(response)
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .succeeded
                    ))
                    authorizationRecoveryPending = false
                }
                return response
            } catch is CancellationError {
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .failed
                    ))
                }
                throw CancellationError()
            } catch let error as LibreChatProtocolError {
                if case .transport = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: method,
                        nextAttempt: attempt + 1
                    ))
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                    continue
                }
                if case let .serverNotReady(retryAfter) = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: method,
                        nextAttempt: attempt + 1
                    ))
                    let delay = Self.boundedRetryDelay(retryAfter, fallback: TimeInterval(attempt))
                    try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                    continue
                }
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .failed
                    ))
                }
                throw error
            }
        }
    }

    /// Performs an authenticated disk-backed transfer with the same explicit
    /// cookie jar and single refresh coordination used by JSON requests. A
    /// successful response is never retried automatically unless its request
    /// descriptor explicitly opts into an idempotent retry policy.
    public func downloadResponse(
        method: HTTPMethod,
        path: String,
        pathComponents: [String]? = nil,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool,
        retryPolicy: RequestRetryPolicy = .never,
        baseURL: URL? = nil
    ) async throws -> HTTPDownloadResponse {
        let maximumAttempts: Int = switch retryPolicy {
        case .never: 1
        case let .idempotent(maximumAttempts): max(1, maximumAttempts)
        }
        var attempt = 0
        var refreshed = false
        var authorizationRecoveryPending = false
        let route = pathComponents.map {
            ProtocolRoute.classify(path: $0.joined(separator: "/"))
        } ?? ProtocolRoute.classify(path: path)

        while true {
            attempt += 1
            do {
                var credential: AuthorizationCredential?
                var request = try await transport.request(
                    method: method,
                    path: path,
                    pathComponents: pathComponents,
                    queryItems: queryItems,
                    headers: headers,
                    body: body,
                    baseURL: baseURL
                )
                if authorized {
                    do {
                        let current = try await authSession.authorizationCredential()
                        credential = current
                        request.setValue(current.headerValue, forHTTPHeaderField: "Authorization")
                    } catch LibreChatProtocolError.unauthorized where !refreshed {
                        _ = try await authSession.refresh(ifRejected: nil)
                        refreshed = true
                        continue
                    }
                }

                let response = try await transport.executeDownload(request, attempt: attempt)
                if authorized,
                   (response.statusCode == 401 || Self.isBrowserLoginRedirect(response.finalURL)),
                   !refreshed,
                   Self.allowsAuthorizationReplay(method: method, retryPolicy: retryPolicy) {
                    try? FileManager.default.removeItem(at: response.localURL)
                    observability.record(.authorizationRecoveryStarted(route: route, method: method))
                    do {
                        _ = try await authSession.refresh(ifRejected: credential)
                    } catch {
                        observability.record(.authorizationRecoveryCompleted(
                            route: route,
                            method: method,
                            outcome: .failed
                        ))
                        throw error
                    }
                    refreshed = true
                    authorizationRecoveryPending = true
                    continue
                }

                do {
                    try Self.validateDownload(response)
                    try Task.checkCancellation()
                } catch {
                    try? FileManager.default.removeItem(at: response.localURL)
                    throw error
                }
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .succeeded
                    ))
                    authorizationRecoveryPending = false
                }
                return response
            } catch is CancellationError {
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .failed
                    ))
                }
                throw CancellationError()
            } catch let error as LibreChatProtocolError {
                if case .transport = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: method,
                        nextAttempt: attempt + 1
                    ))
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                    continue
                }
                if case let .serverNotReady(retryAfter) = error, attempt < maximumAttempts {
                    observability.record(.transportRetryScheduled(
                        route: route,
                        method: method,
                        nextAttempt: attempt + 1
                    ))
                    let delay = Self.boundedRetryDelay(retryAfter, fallback: TimeInterval(attempt))
                    try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                    continue
                }
                if authorizationRecoveryPending {
                    observability.record(.authorizationRecoveryCompleted(
                        route: route,
                        method: method,
                        outcome: .failed
                    ))
                }
                throw error
            }
        }
    }

    private static func validateDownload(_ response: HTTPDownloadResponse) throws {
        guard (200..<300).contains(response.statusCode),
              !isBrowserLoginRedirect(response.finalURL) else {
            let errorData = (try? boundedErrorData(at: response.localURL)) ?? Data()
            try validate(HTTPResponse(
                data: errorData,
                statusCode: response.statusCode,
                headers: response.headers,
                finalURL: response.finalURL
            ))
            throw LibreChatProtocolError.invalidResponse
        }
    }

    private static func boundedErrorData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 65_536) ?? Data()
    }

    private static func validate(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode), !isBrowserLoginRedirect(response.finalURL) else {
            if response.statusCode == 401 || isBrowserLoginRedirect(response.finalURL) {
                throw LibreChatProtocolError.unauthorized
            }
            if response.statusCode == 409,
               let details = try? JSONDecoder().decode(GenerationConflictDetails.self, from: response.data),
               (details.code == "GENERATION_PREDECESSOR_MISMATCH"
                    || details.status == "predecessor_mismatch"
                    || details.code?.isEmpty == false) {
                throw LibreChatProtocolError.generationConflict(details)
            }
            if response.statusCode == 503,
               let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: response.data),
               envelope.code == "SERVER_NOT_READY" {
                throw LibreChatProtocolError.serverNotReady(retryAfter: retryAfter(response.headers))
            }
            throw LibreChatProtocolError.httpStatus(
                response.statusCode,
                message: message(from: response.data),
                retryAfter: retryAfter(response.headers)
            )
        }
    }

    private struct ServerErrorEnvelope: Decodable {
        var code: String?
    }

    private static func isBrowserLoginRedirect(_ url: URL) -> Bool {
        url.lastPathComponent == "login" && !url.path.contains("/api/auth/")
    }

    private static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
            .flatMap { TimeInterval($0.value) }
    }

    private static func boundedRetryDelay(
        _ requested: TimeInterval?,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard let requested, requested.isFinite else { return fallback }
        return min(max(0, requested), 120)
    }

    /// A bearer credential may be refreshed before dispatch without risking
    /// duplicate mutation. After a request has reached the server, however,
    /// `.never` means its 401/redirect response must be surfaced rather than
    /// replaying the same body under a new credential. This keeps the retry
    /// policy truthful for non-idempotent creates, edits, deletes, resumes,
    /// and generation-control requests.
    private static func allowsAuthorizationReplay(
        method: HTTPMethod,
        retryPolicy: RequestRetryPolicy
    ) -> Bool {
        if method == .get { return true }
        if case .idempotent = retryPolicy { return true }
        return false
    }

    private static func message(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return object["message"]?.stringValue ?? object["error"]?.stringValue
        }
        return String(data: data, encoding: .utf8)
    }
}
