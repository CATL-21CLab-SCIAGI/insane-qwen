import Foundation
import Testing
@testable import EmbryoCore

@Suite struct SSEParserTests {
    @Test func everyByteBoundaryPreservesUnicodeAndCRLF() throws {
        let input = Data("\u{FEFF}: keepalive\r\nevent: assistant\r\ndata: {\"content\":\"你好 👋\",\r\ndata: \"step\":0,\"role\":\"assistant\"}\r\n\r\nevent: done\ndata: {\"id\":\"r1\",\"status\":\"finished\",\"messages\":2}\n\n".utf8)
        for boundary in 0...input.count {
            var parser = SSEParser()
            let first = try parser.feed(input.prefix(boundary))
            let second = try parser.feed(input.suffix(input.count - boundary))
            let messages = first + second
            #expect(messages.count == 2)
            #expect(try RunEvent(message: messages[0]) == .assistant(AssistantEvent(step: 0, content: "你好 👋")))
            #expect(try RunEvent(message: messages[1]) == .done(RunDone(id: "r1", status: "finished", messages: 2)))
        }
    }

    @Test func bytewiseCRAndMultipleDataLines() throws {
        var parser = SSEParser()
        var result: [SSEMessage] = []
        for byte in Data("event: custom\rdata: one\rdata:  two\rdata\r\rid: ignored\nretry: 0\n\ndata: next\n\n".utf8) {
            result += try parser.feed(Data([byte]))
        }
        #expect(result == [SSEMessage(event: "custom", data: "one\n two\n"), SSEMessage(event: "message", data: "next")])
    }

    @Test func incompleteFramesAndCommentsDoNotDispatch() throws {
        var parser = SSEParser()
        #expect(try parser.feed(Data(": heartbeat\n\nevent: done\ndata: {}\n".utf8)).isEmpty)
    }

    @Test func emptyEventNameDefaultsToMessage() throws {
        var parser = SSEParser()
        #expect(try parser.feed(Data("event:\ndata:\n\n".utf8)) == [SSEMessage(event: "message", data: "")])
    }

    @Test func malformedUTF8AndOversizedEventsFail() throws {
        var invalid = SSEParser()
        #expect(throws: GatewayError.invalidEvent("UTF-8")) { try invalid.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3A, 0xFF, 0x0A])) }
        var huge = SSEParser(maximumEventBytes: 30)
        #expect(throws: GatewayError.eventTooLarge) { try huge.feed(Data("data: 1234567890\ndata: 1234567890\n\n".utf8)) }
    }

    @Test func knownMalformedEventFailsWithoutLeakingPayload() {
        #expect(throws: GatewayError.invalidEvent("run")) { try RunEvent(message: SSEMessage(event: "run", data: "private-output")) }
    }
}
