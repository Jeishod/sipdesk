import Foundation
import SIPCore
import SIPRuntime

struct CallSession: Identifiable {
    let id: UInt64
    let nativeID: Int32
    let recordID = UUID()
    let accountID: UUID
    var remoteURI: String
    var displayName: String
    let direction: CallDirection
    let startedAt = Date()
    var connectedAt: Date?
    var state: Int32
    var mediaState: Int32
    var muted = false
    var isEnding = false
    var localDecline = false
    var localHangup = false
    var holdRequestedAt: Date?
    var digits = ""
    var statistics: CallStatistics?

    var isConnected: Bool { state == 5 }
    var isRinging: Bool { direction == .incoming && state < 4 }
    var isHeld: Bool { mediaState == 2 }
    var isRemotelyHeld: Bool { mediaState == 3 }
    var title: String { displayName.isEmpty ? SIPAddress.displayUser(from: remoteURI) : displayName }
    var status: String {
        if isEnding { return L("Ending…") }
        if isHeld { return L("On hold") }
        if isRemotelyHeld { return L("Held by the other party") }
        if isConnected { return L("In call") }
        if isRinging { return L("Incoming call") }
        switch state {
        case 1: return L("Calling…")
        case 3: return L("Waiting for answer…")
        case 4: return L("Connecting call…")
        default: return L("Preparing call…")
        }
    }

    init(previewAccountID: UUID) {
        id = 1
        nativeID = -1
        accountID = previewAccountID
        remoteURI = "sip:1002@pbx.example.com"
        displayName = L("Test call")
        direction = .outgoing
        state = 5
        mediaState = 1
        connectedAt = Date()
    }

    init(event: EngineEvent, accountID: UUID) {
        id = event.callToken
        nativeID = event.callID
        self.accountID = accountID
        remoteURI = event.remoteURI
        displayName = event.displayName
        direction = event.incoming ? .incoming : .outgoing
        state = event.state
        mediaState = event.mediaState
        if event.state == 5 { connectedAt = Date() }
    }
}

enum ConnectionState: Equatable {
    case offline, connecting, online, failed(String)

    var title: String {
        switch self {
        case .offline: L("Not connected")
        case .connecting: L("Connecting…")
        case .online: L("Available")
        case .failed: L("Connection error")
        }
    }
}

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let date = Date()
    var message: String
}

