import Foundation

public enum CallDirection: String, Codable, Sendable {
    case incoming, outgoing
    public var title: String { self == .incoming ? L("Incoming") : L("Outgoing") }
}

public enum CallOutcome: String, Codable, Sendable {
    case answered, missed, declined, cancelled, failed

    public var title: String {
        switch self {
        case .answered: L("Completed")
        case .missed: L("Missed")
        case .declined: L("Declined")
        case .cancelled: L("Cancelled")
        case .failed: L("Failed")
        }
    }
}

public struct CallRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var remoteURI: String
    public var displayName: String
    public var direction: CallDirection
    public var startedAt: Date
    public var connectedAt: Date?
    public var endedAt: Date
    public var outcome: CallOutcome

    public init(
        id: UUID = UUID(), accountID: UUID, remoteURI: String, displayName: String = "",
        direction: CallDirection, startedAt: Date, connectedAt: Date? = nil,
        endedAt: Date, outcome: CallOutcome
    ) {
        self.id = id
        self.accountID = accountID
        self.remoteURI = remoteURI
        self.displayName = displayName
        self.direction = direction
        self.startedAt = startedAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }

    public var duration: TimeInterval {
        guard let connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }

    public var title: String { displayName.isEmpty ? SIPAddress.displayUser(from: remoteURI) : displayName }

    public static func outcome(direction: CallDirection, connected: Bool, localDecline: Bool, localHangup: Bool, statusCode: Int) -> CallOutcome {
        if connected { return .answered }
        if localDecline { return .declined }
        if direction == .incoming { return .missed }
        if localHangup || statusCode == 487 { return .cancelled }
        return .failed
    }

    public static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

public struct AudioPreferences: Codable, Equatable, Sendable {
    public var input: String?
    public var output: String?
    public var ringtoneEnabled: Bool

    public init(input: String? = nil, output: String? = nil, ringtoneEnabled: Bool = true) {
        self.input = input
        self.output = output
        self.ringtoneEnabled = ringtoneEnabled
    }
}

public enum SIPStatus {
    public static func explanation(code: Int, fallback: String) -> String {
        switch code {
        case 401, 407, 171100: L("The server rejected the credentials. Check the username, auth ID and password.")
        case 403: L("The server denied the connection. Check the account and IP restrictions.")
        case 404: L("The number or SIP account was not found on the server.")
        case 408: L("The server did not respond. Check the address, port, transport and VPN.")
        case 480: L("The recipient is temporarily unavailable.")
        case 486, 600: L("The recipient is busy.")
        case 488, 606: L("The audio codec or SRTP mode could not be negotiated. Check the server settings.")
        case 500...599: L("SIP server error ({0}). {1}", String(code), String(fallback))
        case 603: L("The recipient declined the call.")
        default: fallback.isEmpty ? L("SIP error ({0}).", String(code)) : fallback
        }
    }
}

