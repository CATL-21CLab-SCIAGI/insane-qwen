import Foundation
import Testing
@testable import EmbryoCore

@Suite(.serialized) struct ClientTests {
    private func client(mode: ProtocolState.Mode) -> EmbryoClient {
        StubProtocol.state.reset(mode)
        return EmbryoClient(sessionFactory: { timeout in EmbryoClient.makeSession(timeout: timeout, protocolClasses: [StubProtocol.self]) })
    }

    @Test func healthUsesPrivateEndpointAndBearer() async throws {
        let client = client(mode: .health)
        #expect(try await client.health(token: "test-token") == HealthResponse(ok: true, models: ["agent"], sandboxes: 2))
        let snapshot = StubProtocol.state.snapshot
        #expect(snapshot.paths == ["/healthz"])
        #expect(snapshot.authorizationMatches)
        #expect(snapshot.requests == 1)
        #expect(snapshot.timeouts == [30])
    }

    @Test func tailscaleConnectionSendsNoAuthorizationHeader() async throws {
        let client = client(mode: .health)
        _ = try await client.health(token: "")
        #expect(StubProtocol.state.snapshot.authorizationAbsent)
        #expect(StubProtocol.state.snapshot.paths == ["/healthz"])
    }

    @Test(arguments: [(401, GatewayError.unauthorized), (429, GatewayError.rateLimited), (503, GatewayError.unavailable), (302, GatewayError.httpStatus(302))])
    func friendlyHTTPErrors(code: Int, expected: GatewayError) async {
        let client = client(mode: .http(code))
        await #expect(throws: expected) { try await client.health(token: "test-token") }
    }

    @Test func streamDeliversTypedEventsAndEndsOnlyAfterDone() async throws {
        let client = client(mode: .stream("event: run\ndata: {\"id\":\"r1\",\"model\":\"agent\",\"image\":\"scratch\",\"cwd\":\"/workspace\"}\n\nevent: done\ndata: {\"id\":\"r1\",\"status\":\"finished\",\"messages\":2}\n\n"))
        var events: [RunEvent] = []
        for try await event in client.startRun(.init(model: "agent", image: "scratch", task: "hi", maxSteps: 3), token: "test-token") {
            events.append(event)
        }
        #expect(events == [.run(.init(id: "r1", model: "agent", image: "scratch", cwd: "/workspace")), .done(.init(id: "r1", status: "finished", messages: 2))])
        #expect(StubProtocol.state.snapshot.requests == 1)
        #expect(StubProtocol.state.snapshot.paths == ["/agent/runs"])
        #expect(StubProtocol.state.snapshot.timeouts == [1_800])
    }

    @Test func truncatedStreamFailsAndNeverRetriesPOST() async {
        let client = client(mode: .stream("event: error\ndata: {\"error\":\"model stopped\"}\n\nevent: done\ndata: {\"id\":\"r1\"}"))
        var events: [RunEvent] = []
        await #expect(throws: GatewayError.incompleteStream) {
            for try await event in client.startRun(.init(model: "agent", image: "scratch", task: "hi", maxSteps: 3), token: "test-token") { events.append(event) }
        }
        #expect(events == [.error(.init(error: "model stopped"))])
        #expect(StubProtocol.state.snapshot.requests == 1)
    }

    @Test func chatRequiresFinishedEventAndDoneMarker() async throws {
        let client = client(mode: .stream("data: {\"choices\":[{\"delta\":{\"content\":\"Hello 世界\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\ndata: [DONE]\n\n"))
        var chunks: [ChatChunk] = []
        for try await chunk in client.chat(.init(model: "original", messages: [.init(role: "user", content: "hello")]), token: "test-token") { chunks.append(chunk) }
        #expect(chunks.first?.choices.first?.delta.content == "Hello 世界")
        #expect(chunks.last?.usage?.totalTokens == 5)
        #expect(StubProtocol.state.snapshot.paths == ["/v1/chat/completions"])
        #expect(StubProtocol.state.snapshot.requests == 1)
    }

    @Test(arguments: ["data: [DONE]\n\n", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"])
    func incompleteChatNeverSucceedsOrRetries(_ body: String) async {
        let client = client(mode: .stream(body))
        await #expect(throws: GatewayError.incompleteStream) {
            for try await _ in client.chat(.init(model: "original", messages: [.init(role: "user", content: "hello")]), token: "test-token") { }
        }
        #expect(StubProtocol.state.snapshot.requests == 1)
    }

    @Test func cancellationActivelyClosesHangingConnection() async throws {
        let client = client(mode: .stall)
        let task = Task {
            for try await _ in client.startRun(.init(model: "agent", image: "scratch", task: "hi", maxSteps: 3), token: "test-token") { }
        }
        for _ in 0..<100 where StubProtocol.state.snapshot.requests == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(StubProtocol.state.snapshot.requests == 1)
        task.cancel()
        _ = await task.result
        for _ in 0..<100 where StubProtocol.state.snapshot.stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(StubProtocol.state.snapshot.stopped == 1)
        #expect(StubProtocol.state.snapshot.requests == 1)
    }

    @Test func badTokenOrRunIDMakesNoRequest() async {
        let client = client(mode: .health)
        await #expect(throws: GatewayError.missingToken) { try await client.health(token: "\n ") }
        await #expect(throws: GatewayError.missingToken) { try await client.health(token: "injected\r\nHeader:value") }
        await #expect(throws: GatewayError.invalidRunID) { try await client.run(id: "../healthz", token: "test-token") }
        #expect(StubProtocol.state.snapshot.requests == 0)
    }

    @Test func redirectsAreRefusedEvenWhenSameOrigin() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = EmbryoEndpoint.defaultValue.url
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        for destination in ["https://example.com/collect", original.appendingPathComponent("new").absoluteString] {
            var request = URLRequest(url: try #require(URL(string: destination)))
            request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
            let redirected: URLRequest? = await withCheckedContinuation { continuation in
                NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { request in
                    continuation.resume(returning: request)
                }
            }
            #expect(redirected == nil)
        }
    }

    @Test func sessionTimeoutsBoundBothInactivityAndTotalTransferTime() {
        for timeout: TimeInterval in [30, 1_800] {
            let session = EmbryoClient.makeSession(timeout: timeout)
            #expect(session.configuration.timeoutIntervalForRequest == timeout)
            #expect(session.configuration.timeoutIntervalForResource == timeout)
            session.invalidateAndCancel()
        }
    }
}

private final class ProtocolState: @unchecked Sendable {
    enum Mode { case health, http(Int), stream(String), stall }
    struct Snapshot {
        var requests = 0
        var stopped = 0
        var paths: [String] = []
        var timeouts: [TimeInterval] = []
        var authorizationMatches = true
        var authorizationAbsent = true
    }
    private let lock = NSLock()
    private var storedMode: Mode = .health
    private var storedSnapshot = Snapshot()
    var snapshot: Snapshot { lock.withLock { storedSnapshot } }
    func reset(_ mode: Mode) { lock.withLock { storedMode = mode; storedSnapshot = Snapshot() } }
    func started(_ request: URLRequest) -> Mode {
        lock.withLock {
            storedSnapshot.requests += 1
            storedSnapshot.paths.append(request.url?.path ?? "")
            storedSnapshot.timeouts.append(request.timeoutInterval)
            storedSnapshot.authorizationMatches = storedSnapshot.authorizationMatches && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            storedSnapshot.authorizationAbsent = storedSnapshot.authorizationAbsent && request.value(forHTTPHeaderField: "Authorization") == nil
            return storedMode
        }
    }
    func stopped() { lock.withLock { storedSnapshot.stopped += 1 } }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.started(request)
        let status: Int
        let mime: String
        let body: String
        let finishes: Bool
        switch mode {
        case .health: status = 200; mime = "application/json"; body = #"{"ok":true,"models":["agent"],"sandboxes":2}"#; finishes = true
        case .http(let code): status = code; mime = "application/json"; body = "{}"; finishes = true
        case .stream(let input): status = 200; mime = "text/event-stream"; body = input; finishes = true
        case .stall: status = 200; mime = "text/event-stream"; body = ""; finishes = false
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        if finishes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stopped() }
}
