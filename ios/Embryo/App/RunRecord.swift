import Foundation
#if SWIFT_PACKAGE
import EmbryoCore
#endif

struct RunAnnotation: Codable, Equatable, Sendable {
    var label = "Unrated"
    var failureModes: [String] = []
    var notes = ""
    static let labels = ["Unrated", "Success", "Partial", "Failure"]
    static let modes = ["Wrong tool use", "Loops", "Gave up", "Unverified result", "Ran out of steps", "Environment issue", "Other"]
}

struct ToolTrace: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var command: String
    var observation: String?
    var returnCode: Int? {
        observation.flatMap { ToolEvent(step: 0, content: $0).returnCode }
    }
    var truncated: Bool {
        observation.map { ToolEvent(step: 0, content: $0).isTruncated } ?? false
    }
}

struct TrajectoryStep: Codable, Identifiable, Sendable {
    var id: Int
    var text: String
    var tools: [ToolTrace]
    var usage: TokenUsage?
}

struct SavedEvent: Codable, Sendable { var kind: String; var payload: String }

struct RunRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var remoteID: String?
    var model: String
    var image: String
    var task: String
    var maxSteps: Int
    var started = Date()
    var finished: Date?
    var status = "connecting"
    var steps: [TrajectoryStep] = []
    var events: [SavedEvent] = []
    var serverRecord: RunDetail?
    var annotation = RunAnnotation()
    var error: String?
    var comparisonID: UUID?
    var isSample = false

    var active: Bool { ["connecting", "running"].contains(status) }
    var title: String { task.split(separator: "\n").first.map(String.init) ?? "Untitled task" }
    var outputTokens: Int? { guard !steps.isEmpty, steps.allSatisfy({ $0.usage != nil }) else { return nil }; return steps.compactMap(\.usage?.completionTokens).reduce(0, +) }
    var totalTokens: Int? { guard !steps.isEmpty, steps.allSatisfy({ $0.usage != nil }) else { return nil }; return steps.compactMap(\.usage?.totalTokens).reduce(0, +) }
    var elapsed: TimeInterval { max(0, (finished ?? Date()).timeIntervalSince(started)) }
    var statusTitle: String {
        switch status {
        case "connecting": image == "chat" ? "Connecting" : "Creating sandbox"
        case "running": "Running"
        case "finished": "Finished"
        case "step_limit": "Step limit"
        case "cancelled": "Cancelled locally"
        case "interrupted", "client_disconnected": "Disconnected"
        case "error": "Error"
        default: status.hasPrefix("error") ? "Error" : status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    mutating func apply(_ event: RunEvent) {
        switch event {
        case .run(let value):
            remoteID = value.id; status = "running"; remember("run", value)
        case .assistant(let value):
            let tools = (value.toolCalls ?? []).map(Self.trace)
            let step = TrajectoryStep(id: value.step, text: value.content ?? "", tools: tools, usage: value.usage)
            if let index = steps.firstIndex(where: { $0.id == value.step }) { steps[index] = step } else { steps.append(step) }
            remember("assistant", value)
        case .tool(let value):
            if let index = steps.firstIndex(where: { $0.id == value.step }) {
                if let tool = steps[index].tools.firstIndex(where: { $0.id == value.toolCallID }) {
                    steps[index].tools[tool].observation = value.content
                } else {
                    steps[index].tools.append(ToolTrace(id: value.toolCallID ?? UUID().uuidString, name: value.name ?? "bash", command: "", observation: value.content))
                }
            }
            remember("tool", value)
        case .done(let value):
            remoteID = value.id; status = value.status; finished = Date(); remember("done", value)
        case .error(let value):
            error = value.error; status = "error"; finished = Date(); remember("error", value)
        case .unknown(let name, let data):
            events.append(SavedEvent(kind: name, payload: String(describing: data)))
        }
    }

    mutating func remember<T: Encodable>(_ kind: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) {
            events.append(SavedEvent(kind: kind, payload: json))
        }
    }

    static func trace(_ call: ToolCall) -> ToolTrace {
        let args = call.function.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ToolTrace(id: call.id, name: call.function.name, command: args?["command"] as? String ?? call.function.arguments)
    }

    init(model: String, image: String, task: String, maxSteps: Int, comparisonID: UUID? = nil) {
        self.model = model; self.image = image; self.task = task; self.maxSteps = maxSteps; self.comparisonID = comparisonID
    }

    init(server: RunDetail) {
        self.init(model: server.model, image: server.image,
                  task: server.messages.first(where: { $0.role == "user" })?.content ?? "", maxSteps: server.maxSteps)
        remoteID = server.id; started = Date(timeIntervalSince1970: server.started)
        finished = server.finished.map(Date.init(timeIntervalSince1970:)); status = server.status; serverRecord = server
        for message in server.messages {
            if message.role == "assistant" {
                steps.append(TrajectoryStep(id: steps.count, text: message.content ?? "", tools: (message.toolCalls ?? []).map(Self.trace), usage: nil))
            } else if message.role == "tool" {
                for index in steps.indices {
                    if let toolIndex = steps[index].tools.firstIndex(where: { $0.id == message.toolCallID }) {
                        steps[index].tools[toolIndex].observation = message.content
                    }
                }
            }
        }
    }

    /// Server history fills gaps left by a dropped stream; local assessment and received usage survive.
    mutating func reconcile(server: RunDetail) {
        let previous = self
        self = RunRecord(server: server)
        id = previous.id
        annotation = previous.annotation
        comparisonID = previous.comparisonID
        events = previous.events
        isSample = previous.isSample
        for index in steps.indices {
            if let known = previous.steps.first(where: {
                $0.id == steps[index].id && $0.text == steps[index].text && $0.tools.map(\.id) == steps[index].tools.map(\.id)
            }) {
                steps[index].usage = known.usage
            }
        }
    }
}

struct TaskTemplate: Identifiable, Sendable {
    var id: String
    var symbol: String
    var text: String
    var image: String
    static let all = [
        TaskTemplate(id: "Data analysis", symbol: "chart.xyaxis.line", text: "Generate a reproducible synthetic dataset of 200 observations with a nonlinear trend and noise. Compare a linear fit with a quadratic fit using held-out error, inspect residuals, and explain which model is supported by the evidence. Use Python and show the numerical results.", image: "science-py312"),
        TaskTemplate(id: "Model fitting", symbol: "function", text: "Simulate noisy exponential decay with known parameters. Fit the parameters with scipy, estimate uncertainty by bootstrap, and check whether the true values are covered. Use a fixed random seed and report limitations.", image: "science-py312"),
        TaskTemplate(id: "Simulation", symbol: "waveform.path", text: "Simulate a damped harmonic oscillator numerically. Check the zero-damping case against its analytical solution, study the effect of time-step size, and report evidence that the result converges.", image: "science-py312"),
        TaskTemplate(id: "Reproduce a result", symbol: "checkmark.seal", text: "Reproduce this result using code and verify it independently:\n\nThe variance of the mean of n independent standard normal samples is 1/n. Check n = 10, 100, and 1000 with Monte Carlo experiments, report uncertainty, and explain any deviations.", image: "science-py312"),
        TaskTemplate(id: "Code repair", symbol: "chevron.left.forwardslash.chevron.right", text: "Fix the following issue:\n\nDescribe the bug, expected behavior, and reproduction steps here. Select the matching repository sandbox before running.", image: "")
    ]
}

func modelTitle(_ id: String) -> String {
    switch id {
    case "qwen35-4b-rl-v3c80": "Trained · v3c80"
    case "qwen35-4b-native": "Qwen3.5 4B · Original"
    case "qwen35-4b-steered": "Qwen3.5 4B · Steered"
    case "qwen35-9b-native": "Qwen3.5 9B · Original"
    case "qwen35-9b-rl-step50": "Qwen3.5 9B · RL step 50"
    default: id
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds))
    return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s"
}
