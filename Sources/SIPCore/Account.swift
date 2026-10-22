import Foundation

public enum SIPTransport: String, Codable, CaseIterable, Sendable {
    case udp, tcp, tls

    public var title: String { rawValue.uppercased() }
    public var defaultPort: Int { self == .tls ? 5061 : 5060 }
    public var nativeValue: Int32 {
        switch self {
        case .udp: 0
        case .tcp: 1
        case .tls: 2
        }
    }
}

public enum MediaEncryption: String, Codable, CaseIterable, Sendable {
    case disabled, optional, required

    public var title: String {
        switch self {
        case .disabled: L("No SRTP")
        case .optional: L("SRTP if supported")
        case .required: L("SRTP only")
        }
    }

    public var nativeValue: Int32 {
        switch self {
        case .disabled: 0
        case .optional: 1
        case .required: 2
        }
    }
}

public enum DTMFMode: String, Codable, CaseIterable, Sendable {
    case rfc4733, sipInfo

    public var title: String {
        self == .rfc4733 ? "RTP · RFC 4733 / 2833" : "SIP INFO"
    }
}

public struct SIPAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var displayName: String
    public var server: String
    public var port: Int
    public var username: String
    public var authUsername: String
    public var transport: SIPTransport
    public var outboundProxy: String
    public var stunServer: String
    public var useICE: Bool
    public var mediaEncryption: MediaEncryption
    public var dtmfMode: DTMFMode
    public var connectOnLaunch: Bool

    public init(
        id: UUID = UUID(), name: String = L("My SIP account"),
        displayName: String = "", server: String = "", port: Int = 5060,
        username: String = "", authUsername: String = "",
        transport: SIPTransport = .udp, outboundProxy: String = "",
        stunServer: String = "", useICE: Bool = false,
        mediaEncryption: MediaEncryption = .disabled,
        dtmfMode: DTMFMode = .rfc4733, connectOnLaunch: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.server = server
        self.port = port
        self.username = username
        self.authUsername = authUsername
        self.transport = transport
        self.outboundProxy = outboundProxy
        self.stunServer = stunServer
        self.useICE = useICE
        self.mediaEncryption = mediaEncryption
        self.dtmfMode = dtmfMode
        self.connectOnLaunch = connectOnLaunch
    }

    public var address: String { "\(username)@\(server)" }
    public var authenticationUser: String { authUsername.isEmpty ? username : authUsername }

    public func validated() throws -> SIPAccount {
        var account = self
        account.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.server = try SIPAddress.validatedHost(server)
        account.username = username.trimmingCharacters(in: .whitespaces)
        account.authUsername = authUsername.trimmingCharacters(in: .whitespaces)
        account.outboundProxy = outboundProxy.trimmingCharacters(in: .whitespaces)
        account.stunServer = stunServer.trimmingCharacters(in: .whitespaces)
        guard (1...65535).contains(port) else {
            throw ConfigurationError(L("The port must be between 1 and 65535."))
        }
        guard !account.username.isEmpty, account.username.utf8.count <= 128 else {
            throw ConfigurationError(L("Enter a SIP username (up to 128 bytes)."))
        }
        guard !account.username.contains("@"), !account.username.contains(":"),
              !account.username.contains("/"), !account.username.contains(" ") else {
            throw ConfigurationError(L("Enter only the user, such as 1001, without @server in the username field."))
        }
        for value in [account.username, account.authUsername, account.displayName, account.name] {
            try SIPAddress.rejectControls(value)
            guard value.utf8.count <= 256 else { throw ConfigurationError(L("The field value is too long.")) }
        }
        if account.name.isEmpty { account.name = account.server }
        if !account.outboundProxy.isEmpty {
            _ = try SIPAddress.proxy(account.outboundProxy, transport: transport)
        }
        if !account.stunServer.isEmpty {
            _ = try SIPAddress.hostAndPort(account.stunServer)
        }
        if mediaEncryption != .disabled, transport != .tls {
            throw ConfigurationError(L("Select TLS for SRTP: SDES keys must not be sent over an unencrypted SIP connection."))
        }
        return account
    }

    public var registrarURI: String {
        "sip:\(server):\(port);transport=\(transport.rawValue)"
    }

    public var identityURI: String {
        let address = "sip:\(SIPAddress.escapedUser(username))@\(server)"
        guard !displayName.isEmpty else { return address }
        let safeName = displayName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(safeName)\" <\(address)>"
    }
}

public struct ConfigurationError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

