import Foundation
import Testing
@testable import EmbryoCore

@Suite struct EndpointTests {
    @Test func acceptsOnlyPrivateGatewayTransports() throws {
        #expect(try EmbryoEndpoint(rawValue: "http://dsw-evergreen.tail1c6dfa.ts.net:8090/") == .defaultValue)
        #expect(try EmbryoEndpoint(rawValue: "https://dsw-evergreen.tail1c6dfa.ts.net").url.scheme == "https")
        #expect(try EmbryoEndpoint(rawValue: "https://dsw-evergreen.tail1c6dfa.ts.net:443").url.port == 443)
    }

    @Test(arguments: [
        "https://example.com", "http://dsw-evergreen.tail1c6dfa.ts.net", "http://dsw-evergreen.tail1c6dfa.ts.net:80",
        "https://dsw-evergreen.tail1c6dfa.ts.net:8090", "ftp://dsw-evergreen.tail1c6dfa.ts.net:443",
        "http://dsw-evergreen.tail1c6dfa.ts.net:8090/path", "http://dsw-evergreen.tail1c6dfa.ts.net:8090?",
        "http://dsw-evergreen.tail1c6dfa.ts.net:8090#", "http://user@dsw-evergreen.tail1c6dfa.ts.net:8090",
        "http://user:pass@dsw-evergreen.tail1c6dfa.ts.net:8090", "http://dsw-evergreen.tail1c6dfa.ts.net.evil.test:8090",
        "http://dsw-evergreen.tail1c6dfa.ts.net:8090@evil.test", "http://dsw-evergreen.tail1c6dfa.ts.net.:8090"
    ]) func rejectsUnsafeEndpoints(_ value: String) {
        #expect(throws: GatewayError.invalidEndpoint) { try EmbryoEndpoint(rawValue: value) }
    }
}
