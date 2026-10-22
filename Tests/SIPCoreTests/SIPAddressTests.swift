import Foundation
import Testing
@testable import SIPCore

private let account = SIPAccount(server: "pbx.example.com", username: "1001")

@Test(arguments: [
    ("1002", "sip:1002@pbx.example.com:5060;transport=udp"),
    ("+1 (415) 555-0123", "sip:+14155550123@pbx.example.com:5060;transport=udp"),
    ("*98", "sip:*98@pbx.example.com:5060;transport=udp"),
    ("1002#", "sip:1002%23@pbx.example.com:5060;transport=udp"),
    ("alice.smith", "sip:alice.smith@pbx.example.com:5060;transport=udp"),
    ("alice@example.org", "sip:alice@example.org;transport=udp"),
    ("sip:alice@example.org:5070", "sip:alice@example.org:5070;transport=udp"),
    ("sip:alice@example.org;user=phone", "sip:alice@example.org;transport=udp;user=phone"),
    ("sip:alice@example.org;transport=udp", "sip:alice@example.org;transport=udp"),
    ("tel:+44 (20) 1234-5678", "sip:+442012345678@pbx.example.com:5060;transport=udp"),
    ("sip:1002%23@example.org", "sip:1002%23@example.org;transport=udp"),
    ("sip:alice@[::1]:5070", "sip:alice@[::1]:5070;transport=udp")
])
func normalizesDestination(input: String, expected: String) throws {
    #expect(try SIPAddress.destination(input, account: account) == expected)
}

@Test(arguments: ["", " ", "sip://example.com", "sip:alice@example.com?Subject=hello", "alice\r\nVia: bad",
                  "sip:alice%0d%0aFrom@example.com", "sip:alice%00@example.com", "sip:alice%@example.com",
                  "sip:alice@@example.com", "sip:alice@evil.example/path", "\"Name\" <sip:a@example.com>",
                  "sip:alice@example.com:0", "sip:alice@example.com:65536", "sip:alice@example.com;transport=tcp",
                  "sip:a@example.com;transport=udp;transport=udp", "sip:a@example.com;maddr=elsewhere",
                  "sips:alice@example.com", "sip:user:password@example.com", "sip:@example.com", "( ) - ."])
func rejectsUnsafeDestinations(input: String) {
    #expect(throws: ConfigurationError.self) { try SIPAddress.destination(input, account: account) }
}

@Test func supportsTLSWithoutDowngrade() throws {
    let secure = SIPAccount(server: "pbx.example.com", port: 5061, username: "alice", transport: .tls, mediaEncryption: .required)
    #expect(try SIPAddress.destination("sips:bob@example.org", account: secure) == "sips:bob@example.org;transport=tls")
    #expect(throws: ConfigurationError.self) { try SIPAddress.destination("sip:bob@example.org;transport=udp", account: secure) }
    #expect(try secure.validated().registrarURI == "sip:pbx.example.com:5061;transport=tls")
}

@Test(arguments: [("pbx.example.com", "pbx.example.com"), (" PBX.EXAMPLE.COM ", "pbx.example.com"),
                  ("localhost", "localhost"), ("127.0.0.1", "127.0.0.1"), ("::1", "[::1]"), ("[2001:db8::1]", "[2001:db8::1]")])
func validatesHost(input: String, expected: String) throws {
    #expect(try SIPAddress.validatedHost(input) == expected)
}

@Test(arguments: ["", "sip:pbx.example.com", "pbx.example.com:5060", "https://example.com", "foo..bar", "bad host",
                  "bad\nhost", "-host.example", "host-.example", "[not-ipv6]", "999.999.999.999", "host/path", "host@example.com"])
func rejectsInvalidHost(input: String) {
    #expect(throws: ConfigurationError.self) { try SIPAddress.validatedHost(input) }
}

@Test func supportsProxyAndStunPorts() throws {
    #expect(try SIPAddress.proxy("sip:proxy.example.com:5080;lr", transport: .tcp) == "sip:proxy.example.com:5080;transport=tcp;lr")
    #expect(try SIPAddress.proxy("sips:proxy.example.com", transport: .tls) == "sip:proxy.example.com:5061;transport=tls;lr")
    #expect(try SIPAddress.hostAndPort("stun.example.com:3478").port == 3478)
    #expect(try SIPAddress.hostAndPort("[::1]:3478").host == "[::1]")
    #expect(throws: ConfigurationError.self) { try SIPAddress.proxy("sips:proxy.example.com", transport: .udp) }
    #expect(throws: ConfigurationError.self) { try SIPAddress.hostAndPort("stun.example.com:") }
    #expect(throws: ConfigurationError.self) { try SIPAddress.proxy("proxy.example.com;transport=udp", transport: .tls) }
}

@Test func normalizesAndEscapesAccount() throws {
    var draft = SIPAccount(name: "", displayName: "Alice \"Ops\"", server: " PBX.EXAMPLE.COM ", username: "1001")
    draft = try draft.validated()
    #expect(draft.name == "pbx.example.com")
    #expect(draft.authenticationUser == "1001")
    #expect(draft.identityURI == "\"Alice \\\"Ops\\\"\" <sip:1001@pbx.example.com>")
    draft.authUsername = "authentication-user"
    #expect(draft.authenticationUser == "authentication-user")
}

@Test func rejectsUnsafeAccountSettings() {
    var draft = account
    draft.username = "1001@example.com"
    #expect(throws: ConfigurationError.self) { try draft.validated() }
    draft = account
    draft.mediaEncryption = .optional
    #expect(throws: ConfigurationError.self) { try draft.validated() }
    draft = account
    draft.port = 0
    #expect(throws: ConfigurationError.self) { try draft.validated() }
    draft = account
    draft.displayName = "Alice\r\nContact: attacker"
    #expect(throws: ConfigurationError.self) { try draft.validated() }
}

@Test func callerIDDisplayHandlesNamesAndEscapes() {
    #expect(SIPAddress.displayUser(from: "\"Alice\" <sip:1002%23@pbx.example.com>") == "1002#")
    #expect(SIPAddress.displayUser(from: "sips:bob@example.com") == "bob")
}

