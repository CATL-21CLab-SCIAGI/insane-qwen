import Foundation

/// Each operation owns an ephemeral session. Bearer tokens live only in their request.
public struct EmbryoClient: Sendable {
    public let endpoint: EmbryoEndpoint
    private let sessionFactory: @Sendable (TimeInterval) -> URLSession
    private static let queryTimeout: TimeInterval = 30
    private static let runTimeout: TimeInterval = 30 * 60

    public init(endpoint: EmbryoEndpoint = .defaultValue) {
        self.endpoint = endpoint
        self.sessionFactory = { Self.makeSession(timeout: $0) }
    }

    // Tests can install a deterministic URLProtocol without relaxing endpoint validation.
    init(endpoint: EmbryoEndpoint = .defaultValue, sessionFactory: @escaping @Sendable (TimeInterval) -> URLSession) {
        self.endpoint = endpoint
        self.sessionFactory = sessionFactory
    }

    public func health(token: String) async throws -> HealthResponse {
        try await get("healthz", token: token)
    }

    public func images(token: String) async throws -> [String: ImageDescriptor] {
        try await get("images", token: token)
    }

    public func models(token: String) async throws -> [ModelDescriptor] {
        struct Envelope: Decodable { let data: [ModelDescriptor] }
        let envelope: Envelope = try await get("v1/models", token: token)
        return envelope.data
    }

    public func runIDs(token: String) async throws -> [String] {
        try await get("agent/runs", token: token)
    }

    public func run(id: String, token: String) async throws -> RunDetail {
        // IDs are a single URL path segment, never an alternate endpoint or path.
        guard !id.isEmpty, id.utf8.count <= 256,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw GatewayError.invalidRunID
        }
        return try await get("agent/runs/\(id)", token: token)
    }

    /// Consuming-task cancellation closes the network session. A missing `done` event is an error.
    /// The client never retries a POST because doing so can execute the task a second time.
    public func startRun(_ input: StartRunRequest, token: String) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = sessionFactory(Self.runTimeout)
                defer { session.invalidateAndCancel() }
                do {
                    var request = try makeRequest(path: "agent/runs", token: token, timeout: Self.runTimeout)
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(input)
                    try await withTaskCancellationHandler {
                        let (bytes, response) = try await session.bytes(for: request)
                        try Self.validate(response)
                        guard let response = response as? HTTPURLResponse,
                              response.mimeType?.lowercased() == "text/event-stream" else {
                            throw GatewayError.unexpectedContentType
                        }
                        var parser = SSEParser()
                        var chunk = Data()
                        // URLSession.AsyncBytes handles chunking. Flush by line or modest byte count
                        // so event delivery is prompt while preserving arbitrary UTF-8 boundaries.
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            chunk.append(byte)
                            if byte == 10 || byte == 13 || chunk.count >= 4_096 {
                                let messages = try parser.feed(chunk)
                                chunk.removeAll(keepingCapacity: true)
                                for message in messages {
                                    let event = try RunEvent(message: message)
                                    if case .terminated = continuation.yield(event) { throw CancellationError() }
                                    if case .done = event {
                                        continuation.finish()
                                        return
                                    }
                                }
                            }
                        }
                        // A final partial frame is discarded, per SSE framing semantics.
                        throw GatewayError.incompleteStream
                    } onCancel: {
                        session.invalidateAndCancel()
                    }
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Plain chat shares the private endpoint and cancellation policy with agent runs.
    public func chat(_ input: ChatRequest, token: String) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = sessionFactory(Self.runTimeout)
                defer { session.invalidateAndCancel() }
                do {
                    var request = try makeRequest(path: "v1/chat/completions", token: token, timeout: Self.runTimeout)
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(input)
                    try await withTaskCancellationHandler {
                        let (bytes, response) = try await session.bytes(for: request)
                        try Self.validate(response)
                        guard (response as? HTTPURLResponse)?.mimeType?.lowercased() == "text/event-stream" else {
                            throw GatewayError.unexpectedContentType
                        }
                        var parser = SSEParser()
                        var buffer = Data()
                        var sawFinish = false
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            buffer.append(byte)
                            if byte == 10 || byte == 13 || buffer.count >= 4096 {
                                let frames = try parser.feed(buffer)
                                buffer.removeAll(keepingCapacity: true)
                                for frame in frames {
                                    if frame.data == "[DONE]" {
                                        guard sawFinish else { throw GatewayError.incompleteStream }
                                        continuation.finish(); return
                                    }
                                    let chunk = try JSONDecoder().decode(ChatChunk.self, from: Data(frame.data.utf8))
                                    sawFinish = sawFinish || chunk.choices.contains { $0.finish_reason != nil }
                                    if case .terminated = continuation.yield(chunk) { throw CancellationError() }
                                }
                            }
                        }
                        throw GatewayError.incompleteStream
                    } onCancel: { session.invalidateAndCancel() }
                } catch { continuation.finish(throwing: Task.isCancelled ? CancellationError() : error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func get<Value: Decodable>(_ path: String, token: String) async throws -> Value {
        let request = try makeRequest(path: path, token: token, timeout: Self.queryTimeout)
        let session = sessionFactory(Self.queryTimeout)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            do { return try JSONDecoder().decode(Value.self, from: data) }
            catch { throw GatewayError.invalidResponse }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func makeRequest(path: String, token: String, timeout: TimeInterval) throws -> URLRequest {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty || (!trimmed.isEmpty &&
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })) else {
            throw GatewayError.missingToken
        }
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !trimmed.isEmpty { request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw GatewayError.unauthorized
        case 429: throw GatewayError.rateLimited
        case 503: throw GatewayError.unavailable
        default: throw GatewayError.httpStatus(response.statusCode)
        }
    }

    static func makeSession(timeout: TimeInterval = 30, protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
