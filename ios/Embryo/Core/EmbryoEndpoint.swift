import Foundation

/// The app only connects to the private Evergreen gateway, never an arbitrary host.
public struct EmbryoEndpoint: Hashable, Sendable {
    public static let allowedHost = "dsw-evergreen.tail1c6dfa.ts.net"
    public static let defaultValue = try! EmbryoEndpoint(rawValue: "http://dsw-evergreen.tail1c6dfa.ts.net:8090")

    public let url: URL
    public var rawValue: String { url.absoluteString }

    public init(rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.host?.lowercased() == Self.allowedHost,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" && components.port == 8090)
                || (scheme == "https" && (components.port == nil || components.port == 443)),
              var normalized = URLComponents(string: value) else {
            throw GatewayError.invalidEndpoint
        }
        normalized.scheme = scheme
        normalized.host = Self.allowedHost
        normalized.path = ""
        guard let url = normalized.url else { throw GatewayError.invalidEndpoint }
        self.url = url
    }
}

public enum GatewayError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case missingToken
    case invalidRunID
    case unauthorized
    case rateLimited
    case unavailable
    case httpStatus(Int)
    case invalidResponse
    case unexpectedContentType
    case invalidEvent(String)
    case eventTooLarge
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Use the private dsw-evergreen.tail1c6dfa.ts.net gateway: HTTP port 8090 or HTTPS port 443. Paths, credentials, queries, and fragments are not allowed."
        case .missingToken: "Enter the gateway bearer token to connect."
        case .invalidRunID: "The run identifier is invalid."
        case .unauthorized: "The gateway rejected this token. Check your token and try again."
        case .rateLimited: "The gateway is busy or rate limited. Wait before starting another run."
        case .unavailable: "The model service is unavailable. Check the gateway and model server."
        case .httpStatus(let code): "The gateway returned HTTP \(code)."
        case .invalidResponse: "The gateway returned an invalid response."
        case .unexpectedContentType: "The gateway did not return an event stream."
        case .invalidEvent(let name): "The gateway sent an invalid \(name) event."
        case .eventTooLarge: "A gateway event exceeded the supported size."
        case .incompleteStream: "The connection ended before the run reported completion. Check run history before starting again."
        }
    }
}
