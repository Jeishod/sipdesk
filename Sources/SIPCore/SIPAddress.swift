import Foundation
import Darwin

public enum SIPAddress {
    public static func rejectControls(_ value: String) throws {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError(L("Addresses and settings must not contain control characters."))
        }
    }

    public static func validatedHost(_ rawValue: String) throws -> String {
        try rejectControls(rawValue)
        let value = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, value.utf8.count <= 253 else {
            throw ConfigurationError(L("Enter the SIP server host name or IP address, without sip:// or a port."))
        }
        if value.contains(":") {
            let literal = value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
            var address = in6_addr()
            guard inet_pton(AF_INET6, literal, &address) == 1 else {
                throw ConfigurationError(L("Invalid server address. Enter the port separately."))
            }
            return "[\(literal)]"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
              }) else {
            throw ConfigurationError(L("The server address must be a host name or IP without a scheme, path or spaces."))
        }
        if value.allSatisfy({ $0.isNumber || $0 == "." }), value.contains(".") {
            var address = in_addr()
            guard inet_pton(AF_INET, value, &address) == 1 else { throw ConfigurationError(L("Invalid IPv4 address.")) }
        }
        return value
    }

    public static func hostAndPort(_ rawValue: String) throws -> (host: String, port: Int?) {
        try rejectControls(rawValue)
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let bracket = value.firstIndex(of: "]") {
            let host = try validatedHost(String(value[...bracket]))
            let suffix = String(value[value.index(after: bracket)...])
            if suffix.isEmpty { return (host, nil) }
            guard suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()), (1...65535).contains(port) else {
                throw ConfigurationError(L("Invalid port after the IPv6 address."))
            }
            return (host, port)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ConfigurationError(L("Enter IPv6 with a port as [::1]:5060.")) }
        let host = try validatedHost(String(parts.first ?? ""))
        guard parts.count == 2 else { return (host, nil) }
        guard let port = Int(parts[1]), (1...65535).contains(port) else { throw ConfigurationError(L("Invalid server port.")) }
        return (host, port)
    }

    public static func escapedUser(_ user: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()+&=$,")
        return user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user
    }

    public static func destination(_ rawValue: String, account: SIPAccount) throws -> String {
        try rejectControls(rawValue)
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.count < 900 else { throw ConfigurationError(L("Enter a number or SIP address.")) }
        guard !value.contains("<"), !value.contains(">"), !value.contains("\""), !value.contains("\\") else {
            throw ConfigurationError(L("Enter the address without a contact name, quotes or angle brackets."))
        }
        let scheme: String
        let body: String
        if value.lowercased().hasPrefix("sips:") {
            guard account.transport == .tls else { throw ConfigurationError(L("sips: requires an account using TLS.")) }
            scheme = "sips"
            body = String(value.dropFirst(5))
        } else if value.lowercased().hasPrefix("sip:") {
            scheme = "sip"
            body = String(value.dropFirst(4))
        } else if value.lowercased().hasPrefix("tel:") {
            return try destination(String(value.dropFirst(4)), account: account)
        } else {
            scheme = "sip"
            body = value
        }
        guard !body.contains("?"), !body.contains("/"), !body.contains("://") else {
            throw ConfigurationError(L("SIP headers and URL paths are not supported in addresses."))
        }
        let components = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let address = components[0]
        var phoneParameter = false
        var seenParameters = Set<String>()
        for parameter in components.dropFirst() {
            let lower = parameter.lowercased()
            let key = String(lower.split(separator: "=").first ?? "")
            guard seenParameters.insert(key).inserted else { throw ConfigurationError(L("Duplicate SIP address parameter.")) }
            if lower == "user=phone" { phoneParameter = true }
            else if lower != "transport=\(account.transport.rawValue)" {
                throw ConfigurationError(L("The address transport must match the account; user=phone is also allowed."))
            }
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { throw ConfigurationError(L("Invalid SIP address.")) }
        var user = parts[0]
        let dialCharacters = CharacterSet(charactersIn: "+0123456789*# ()-.")
        if user.unicodeScalars.allSatisfy({ dialCharacters.contains($0) }) {
            user.removeAll(where: { " ()-.".contains($0) })
        }
        if let decoded = user.removingPercentEncoding { user = decoded }
        else { throw ConfigurationError(L("Invalid percent encoding in the SIP username.")) }
        try rejectControls(user)
        guard !user.isEmpty, !user.contains(" "), !user.contains("@"), !user.contains(":"), user.utf8.count <= 128 else {
            throw ConfigurationError(L("Invalid number or SIP user."))
        }
        let host: String
        let port: Int?
        if parts.count == 2 {
            (host, port) = try hostAndPort(parts[1])
        } else {
            host = try validatedHost(account.server)
            port = account.port
        }
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(scheme):\(escapedUser(user))@\(host)\(portSuffix);transport=\(account.transport.rawValue)\(phoneParameter ? ";user=phone" : "")"
    }

    public static func proxy(_ rawValue: String, transport: SIPTransport) throws -> String {
        try rejectControls(rawValue)
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("sips:") {
            guard transport == .tls else { throw ConfigurationError(L("A SIPS proxy requires TLS.")) }
            value = String(value.dropFirst(5))
        } else if value.lowercased().hasPrefix("sip:") {
            value = String(value.dropFirst(4))
        }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        for parameter in parts.dropFirst() {
            guard parameter.lowercased() == "lr" || parameter.lowercased() == "transport=\(transport.rawValue)" else {
                throw ConfigurationError(L("Enter the proxy as host:port; its transport must match the account."))
            }
        }
        let (host, port) = try hostAndPort(parts[0])
        return "sip:\(host):\(port ?? transport.defaultPort);transport=\(transport.rawValue);lr"
    }

    public static func displayUser(from uri: String) -> String {
        var value = uri
        if let start = value.firstIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end {
            value = String(value[value.index(after: start)..<end])
        }
        if value.lowercased().hasPrefix("sips:") { value = String(value.dropFirst(5)) }
        else if value.lowercased().hasPrefix("sip:") { value = String(value.dropFirst(4)) }
        let user = String(value.split(separator: "@", maxSplits: 1).first ?? "")
        return user.removingPercentEncoding ?? user
    }
}

