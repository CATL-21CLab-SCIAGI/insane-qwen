import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct HealthResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var models: [String]
    public var sandboxes: Int
    public init(ok: Bool, models: [String], sandboxes: Int) {
        self.ok = ok; self.models = models; self.sandboxes = sandboxes
    }
}

public struct ImageDescriptor: Codable, Equatable, Sendable {
    public var cwd: String
    public var repo: String?
    public var note: String?
    public init(cwd: String, repo: String? = nil, note: String? = nil) {
        self.cwd = cwd; self.repo = repo; self.note = note
    }
}

public struct ModelDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public let stream = true
    public let temperature = 0.7
    public let top_p = 0.8
    public let max_tokens = 1024
    public let stream_options = ["include_usage": true]
    public let chat_template_kwargs = ["enable_thinking": false]
    public init(model: String, messages: [ChatMessage]) { self.model = model; self.messages = messages }
}

public struct ChatChunk: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Delta: Decodable, Sendable { public let content: String? }
        public let delta: Delta
        public let finish_reason: String?
    }
    public let choices: [Choice]
    public let usage: TokenUsage?
}

public struct StartRunRequest: Codable, Equatable, Sendable {
    public var model: String
    public var image: String
    public var task: String
    public var maxSteps: Int
    public init(model: String, image: String, task: String, maxSteps: Int) {
        self.model = model; self.image = image; self.task = task; self.maxSteps = maxSteps
    }
    enum CodingKeys: String, CodingKey { case model, image, task; case maxSteps = "max_steps" }
}

public struct ToolFunction: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: String
    public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
}

public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var function: ToolFunction
    public init(id: String, type: String = "function", function: ToolFunction) {
        self.id = id; self.type = type; self.function = function
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?
    public var name: String?
    public init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil, name: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls
        self.toolCallID = toolCallID; self.name = name
    }
    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls", toolCallID = "tool_call_id"
    }
}

public struct RunDetail: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var model: String
    public var image: String
    public var maxSteps: Int
    public var messages: [ChatMessage]
    public var harness: JSONValue?
    public var started: Double
    public var finished: Double?
    public var status: String
    public init(id: String, model: String, image: String, maxSteps: Int, messages: [ChatMessage], harness: JSONValue? = nil, started: Double, finished: Double? = nil, status: String) {
        self.id = id; self.model = model; self.image = image; self.maxSteps = maxSteps
        self.messages = messages; self.harness = harness; self.started = started
        self.finished = finished; self.status = status
    }
    enum CodingKeys: String, CodingKey {
        case id, model, image, messages, harness, started, finished, status
        case maxSteps = "max_steps"
    }
}

public struct RunStarted: Codable, Equatable, Sendable {
    public var id: String
    public var model: String
    public var image: String
    public var cwd: String
    public init(id: String, model: String, image: String, cwd: String) {
        self.id = id; self.model = model; self.image = image; self.cwd = cwd
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.totalTokens = totalTokens
    }
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
    }
}

public struct AssistantEvent: Codable, Equatable, Sendable {
    public var step: Int
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var usage: TokenUsage?
    public var finishReason: String?
    public init(step: Int, role: String = "assistant", content: String?, toolCalls: [ToolCall]? = nil, usage: TokenUsage? = nil, finishReason: String? = nil) {
        self.step = step; self.role = role; self.content = content; self.toolCalls = toolCalls
        self.usage = usage; self.finishReason = finishReason
    }
    enum CodingKeys: String, CodingKey {
        case step, role, content, usage
        case toolCalls = "tool_calls", finishReason = "finish_reason"
    }
}

public struct ToolEvent: Codable, Equatable, Sendable {
    public var step: Int
    public var role: String
    public var toolCallID: String?
    public var name: String?
    public var content: String
    public init(step: Int, role: String = "tool", toolCallID: String? = nil, name: String? = nil, content: String) {
        self.step = step; self.role = role; self.toolCallID = toolCallID; self.name = name; self.content = content
    }
    enum CodingKeys: String, CodingKey {
        case step, role, name, content
        case toolCallID = "tool_call_id"
    }

    /// Only the final metadata line is gateway status; tool stdout can contain arbitrary text.
    public var returnCode: Int? {
        let pattern = #"(?:\A|\r?\n)Tool metadata:[\t ]*\{[^\r\n}]*['\"]returncode['\"][\t ]*:[\t ]*(-?\d+)[^\r\n}]*\}[\t \r\n]*\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        return Int(content[range])
    }
    public var isTruncated: Bool {
        content.hasPrefix("[TRUNCATION WARNING]") && content.contains("[...OUTPUT OMITTED:")
    }
}

public struct ServerErrorEvent: Codable, Equatable, Sendable {
    public var error: String
    public init(error: String) { self.error = error }
}

public struct RunDone: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var messages: Int
    public init(id: String, status: String, messages: Int) { self.id = id; self.status = status; self.messages = messages }
}

public enum RunEvent: Equatable, Sendable {
    case run(RunStarted)
    case assistant(AssistantEvent)
    case tool(ToolEvent)
    case error(ServerErrorEvent)
    case done(RunDone)
    case unknown(name: String, data: String)

    public init(message: SSEMessage) throws {
        let data = Data(message.data.utf8)
        let decoder = JSONDecoder()
        do {
            switch message.event {
            case "run": self = .run(try decoder.decode(RunStarted.self, from: data))
            case "assistant": self = .assistant(try decoder.decode(AssistantEvent.self, from: data))
            case "tool": self = .tool(try decoder.decode(ToolEvent.self, from: data))
            case "error": self = .error(try decoder.decode(ServerErrorEvent.self, from: data))
            case "done": self = .done(try decoder.decode(RunDone.self, from: data))
            default: self = .unknown(name: message.event, data: message.data)
            }
        } catch { throw GatewayError.invalidEvent(message.event) }
    }
}
