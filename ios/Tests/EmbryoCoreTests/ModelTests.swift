import Foundation
import Testing
@testable import EmbryoCore

@Suite struct ModelTests {
    @Test func gatewayTranscriptPreservesToolCallsAndHarness() throws {
        let json = #"{"id":"r1","model":"agent","image":"scratch","max_steps":8,"messages":[{"role":"user","content":"test"},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"pwd\"}"}}]},{"role":"tool","content":"/workspace\nTool metadata: {'returncode': 0}","tool_call_id":"c1","name":"terminal"}],"harness":{"version":1,"safe":true,"flags":[null,"a"]},"started":123.5,"finished":130,"status":"finished"}"#
        let detail = try JSONDecoder().decode(RunDetail.self, from: Data(json.utf8))
        #expect(detail.maxSteps == 8)
        #expect(detail.messages[1].content == nil)
        #expect(detail.messages[1].toolCalls?.first?.function.arguments == #"{"command":"pwd"}"#)
        #expect(detail.messages[2].toolCallID == "c1")
        #expect(detail.started == 123.5)
        #expect(try JSONDecoder().decode(RunDetail.self, from: JSONEncoder().encode(detail)) == detail)
    }

    @Test func startRunUsesGatewaySnakeCase() throws {
        let input = StartRunRequest(model: "agent", image: "scratch", task: "run tests", maxSteps: 12)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        #expect(object["max_steps"] as? Int == 12)
        #expect(object["maxSteps"] == nil)
    }

    @Test func parsesUsageAndToolObservations() throws {
        let message = SSEMessage(event: "assistant", data: #"{"step":0,"role":"assistant","content":"done","usage":{"prompt_tokens":20,"completion_tokens":3,"total_tokens":23},"finish_reason":"stop"}"#)
        #expect(try RunEvent(message: message) == .assistant(AssistantEvent(step: 0, content: "done", usage: TokenUsage(promptTokens: 20, completionTokens: 3, totalTokens: 23), finishReason: "stop")))
        let tool = ToolEvent(step: 0, content: "[TRUNCATION WARNING] The tool output below is INCOMPLETE: ...\nfirst part\n[...OUTPUT OMITTED: 10 characters truncated from the middle (30 total, kept first 10 + last 10). The text below resumes near the END of the output...]\nlast part\n\nTool metadata: {'returncode': -9}")
        #expect(tool.returnCode == -9)
        #expect(tool.isTruncated)
        #expect(ToolEvent(step: 0, content: "exit unknown").returnCode == nil)
    }

    @Test func returnCodeUsesOnlyTrailingGatewayMetadata() {
        let content = "printed content\nTool metadata: {'returncode': 0}\nactual command failed\nTool metadata: {'returncode': 17}\n"
        #expect(ToolEvent(step: 0, content: content).returnCode == 17)
        #expect(ToolEvent(step: 0, content: "Tool metadata: {'returncode': 0}\nmore stdout").returnCode == nil)
        #expect(ToolEvent(step: 0, content: "prefix Tool metadata: {'returncode': 0}").returnCode == nil)
        #expect(ToolEvent(step: 0, content: "stdout\r\nTool metadata: {\"returncode\": -9, \"elapsed\": 12.5}\r\n").returnCode == -9)
        #expect(ToolEvent(step: 0, content: "stdout\n\nTool metadata: {'returncode': None}").returnCode == nil)
    }

    @Test func truncationUsesGatewayWarningAndOmissionMarker() {
        #expect(!ToolEvent(step: 0, content: "the function is named truncated_middle").isTruncated)
        #expect(!ToolEvent(step: 0, content: "[TRUNCATION WARNING] mentioned without omitted output").isTruncated)
        #expect(!ToolEvent(step: 0, content: "ordinary output [...OUTPUT OMITTED: example").isTruncated)
    }

    @Test func acceptsUnknownEventWithoutInterpretingIt() throws {
        #expect(try RunEvent(message: SSEMessage(event: "heartbeat", data: "ok")) == .unknown(name: "heartbeat", data: "ok"))
    }
}
