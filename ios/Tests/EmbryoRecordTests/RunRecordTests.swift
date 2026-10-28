import Foundation
import Testing
import EmbryoCore
@testable import EmbryoRecords

@Suite struct RunRecordTests {
    private let call = ToolCall(id: "call-1", function: ToolFunction(name: "bash", arguments: #"{"command":"python verify.py"}"#))
    private let usage = TokenUsage(promptTokens: 100, completionTokens: 25, totalTokens: 125)

    private func server(messages: [ChatMessage], status: String = "finished") -> RunDetail {
        RunDetail(id: "run-1", model: "model", image: "science", maxSteps: 10,
                  messages: [.init(role: "user", content: "Verify the calculation")] + messages,
                  started: 100, finished: 120, status: status)
    }

    @Test func historyRecoversMissingObservationAndFinalAnswerAfterDisconnect() {
        var record = RunRecord(model: "model", image: "science", task: "Verify the calculation", maxSteps: 10)
        record.apply(.run(.init(id: "run-1", model: "model", image: "science", cwd: "/tmp")))
        record.apply(.assistant(.init(step: 0, content: "I will verify it.", toolCalls: [call], usage: usage)))
        record.status = "interrupted"
        record.error = "Connection closed before completion."
        record.reconcile(server: server(messages: [
            .init(role: "assistant", content: "I will verify it.", toolCalls: [call]),
            .init(role: "tool", content: "42\n\nTool metadata: {'returncode': 0}", toolCallID: call.id),
            .init(role: "assistant", content: "The calculation is verified: 42.")
        ]))
        #expect(record.status == "finished")
        #expect(record.error == nil)
        #expect(record.steps.count == 2)
        #expect(record.steps[0].tools[0].observation == "42\n\nTool metadata: {'returncode': 0}")
        #expect(record.steps[0].tools[0].returnCode == 0)
        #expect(record.steps[1].text == "The calculation is verified: 42.")
        #expect(record.started == Date(timeIntervalSince1970: 100))
        #expect(record.finished == Date(timeIntervalSince1970: 120))
        #expect(record.serverRecord?.messages.count == 4)
    }

    @Test func reconciliationRetainsAssessmentIdentityEventsAndKnownUsage() {
        let comparison = UUID()
        var record = RunRecord(model: "model", image: "science", task: "task", maxSteps: 10, comparisonID: comparison)
        let identity = record.id
        record.annotation = .init(label: "Partial", failureModes: ["Unverified result"], notes: "Check the final claim.")
        record.isSample = true
        record.apply(.assistant(.init(step: 0, content: "I will verify it.", toolCalls: [call], usage: usage)))
        let priorPayload = record.events.first?.payload
        record.reconcile(server: server(messages: [
            .init(role: "assistant", content: "I will verify it.", toolCalls: [call]),
            .init(role: "tool", content: "result\n\nTool metadata: {'returncode': 0}", toolCallID: call.id)
        ], status: "step_limit"))
        #expect(record.id == identity)
        #expect(record.remoteID == "run-1")
        #expect(record.comparisonID == comparison)
        #expect(record.annotation == .init(label: "Partial", failureModes: ["Unverified result"], notes: "Check the final claim."))
        #expect(record.isSample)
        #expect(record.events.count == 1)
        #expect(record.events.first?.payload == priorPayload)
        #expect(record.steps[0].usage == usage)
        #expect(record.outputTokens == 25)
        #expect(record.totalTokens == 125)
        #expect(record.status == "step_limit")
    }

    @Test func missingUsageStaysUnknownIncludingNewRecoveredSteps() {
        var record = RunRecord(model: "model", image: "science", task: "task", maxSteps: 10)
        record.apply(.assistant(.init(step: 0, content: "First", usage: usage)))
        record.reconcile(server: server(messages: [.init(role: "assistant", content: "First"), .init(role: "assistant", content: "Recovered")]))
        #expect(record.steps[0].usage == usage)
        #expect(record.steps[1].usage == nil)
        #expect(record.outputTokens == nil)
        #expect(record.totalTokens == nil)
        let historyOnly = RunRecord(server: server(messages: [.init(role: "assistant", content: "Only in history")]))
        #expect(historyOnly.steps[0].usage == nil)
        #expect(historyOnly.totalTokens == nil)
    }

    @Test func usageNeverTransfersToDifferentTextOrToolIDs() {
        var changedText = RunRecord(model: "model", image: "science", task: "task", maxSteps: 10)
        changedText.apply(.assistant(.init(step: 0, content: "Old answer", toolCalls: [call], usage: usage)))
        var changedCall = changedText
        changedText.reconcile(server: server(messages: [.init(role: "assistant", content: "Corrected answer", toolCalls: [call])]))
        #expect(changedText.steps[0].usage == nil)
        var replacementCall = call
        replacementCall.id = "different-call"
        changedCall.reconcile(server: server(messages: [.init(role: "assistant", content: "Old answer", toolCalls: [replacementCall])]))
        #expect(changedCall.steps[0].usage == nil)
    }

    @Test func toolBadgesUseFinalGatewayFooterAndRealTruncationMarker() {
        let trace = ToolTrace(id: "c", name: "bash", command: "test", observation: "Tool metadata: {'returncode': 0}\nfailed\n\nTool metadata: {'returncode': 3}")
        #expect(trace.returnCode == 3)
        #expect(!trace.truncated)
        let partial = ToolTrace(id: "c", name: "bash", command: "test", observation: "[TRUNCATION WARNING] The tool output below is INCOMPLETE\nfirst\n[...OUTPUT OMITTED: 200 characters truncated from the middle...]\nlast\n\nTool metadata: {'returncode': 0}")
        #expect(partial.truncated)
        #expect(partial.returnCode == 0)
        #expect(ToolTrace(id: "c", name: "bash", command: "test", observation: "prefix Tool metadata: {'returncode': 0}").returnCode == nil)
    }
}
