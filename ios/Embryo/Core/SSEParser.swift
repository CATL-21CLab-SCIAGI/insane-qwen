import Foundation

public struct SSEMessage: Equatable, Sendable {
    public let event: String
    public let data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}

/// Incremental UTF-8 SSE decoder. Only blank-line-terminated messages are dispatched.
/// It deliberately does not implement reconnect or Last-Event-ID: POST runs must not be replayed.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var event = "message"
    private var previousWasCR = false
    private var isFirstLine = true
    private var eventByteCount = 0
    private let maximumEventBytes: Int

    public init(maximumEventBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumEventBytes = maximumEventBytes
    }

    public mutating func feed(_ data: Data) throws -> [SSEMessage] {
        var messages: [SSEMessage] = []
        for byte in data {
            if previousWasCR {
                previousWasCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let message = try finishLine() { messages.append(message) }
                previousWasCR = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventByteCount <= maximumEventBytes else { throw GatewayError.eventTooLarge }
            }
        }
        return messages
    }

    private mutating func finishLine() throws -> SSEMessage? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw GatewayError.invalidEvent("UTF-8") }
        if text.isEmpty {
            let message = dataLines.isEmpty ? nil : SSEMessage(event: event, data: dataLines.joined(separator: "\n"))
            event = "message"
            dataLines.removeAll(keepingCapacity: true)
            eventByteCount = 0
            return message
        }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value.removeFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event":
            event = value.isEmpty ? "message" : String(value)
            eventByteCount += bytes.count
        case "data":
            dataLines.append(String(value))
            eventByteCount += bytes.count + 1
        default: break
        }
        guard eventByteCount <= maximumEventBytes else { throw GatewayError.eventTooLarge }
        return nil
    }
}
