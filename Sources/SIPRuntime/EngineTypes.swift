import Foundation
import SIPBridge

public struct EngineEvent: Sendable {
    public enum Kind: Int32, Sendable {
        case registration = 1, incoming, call, media, dtmf, warning, rejected, audioRecovered
    }

    public let kind: Kind
    public let generation: Int32
    public let callID: Int32
    public let callToken: UInt64
    public let state: Int32
    public let code: Int32
    public let incoming: Bool
    public let mediaState: Int32
    public let registered: Bool
    public let remoteURI: String
    public let displayName: String
    public let message: String

    init?(_ raw: SDEvent) {
        guard let kind = Kind(rawValue: raw.type) else { return nil }
        self.kind = kind
        generation = raw.generation
        callID = raw.call_id
        callToken = raw.call_token
        state = raw.state
        code = raw.code
        incoming = raw.incoming != 0
        mediaState = raw.media_state
        registered = raw.registered != 0
        remoteURI = nativeString(raw.remote_uri)
        displayName = nativeString(raw.display_name)
        message = nativeString(raw.message)
    }
}

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let name: String
    public let driver: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public var persistentKey: String { "\(driver)|\(name)" }

    init(_ raw: SDAudioDevice) {
        id = raw.device_id
        name = nativeString(raw.name)
        driver = nativeString(raw.driver)
        hasInput = raw.input_channels > 0
        hasOutput = raw.output_channels > 0
    }
}

public struct CallStatistics: Sendable {
    public let txPackets: UInt32
    public let rxPackets: UInt32
    public let rxLost: UInt32
    public let rttMilliseconds: Double
    public let jitterMilliseconds: Double
    public let secureMedia: Bool
    public let codec: String
    public let inputLevel: Double
    public let outputLevel: Double

    public var lossPercent: Double {
        let total = Double(rxPackets) + Double(rxLost)
        return total == 0 ? 0 : Double(rxLost) / total * 100
    }

    init(_ raw: SDCallStatistics) {
        txPackets = raw.tx_packets
        rxPackets = raw.rx_packets
        rxLost = raw.rx_lost
        rttMilliseconds = raw.rtt_ms
        jitterMilliseconds = raw.jitter_ms
        secureMedia = raw.secure_media != 0
        codec = nativeString(raw.codec)
        inputLevel = min(1, max(0, Double(raw.input_level) / 255))
        outputLevel = min(1, max(0, Double(raw.output_level) / 255))
    }
}

public enum EngineSignal: Sendable {
    case ready(version: String)
    case event(EngineEvent)
    case failed(SIPFailure)
    case stopped
}

public struct SIPFailure: LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { message }

    public init(code: Int32 = -1, message: String) {
        self.code = code
        self.message = message
    }

    init(status: Int32) {
        code = status
        var buffer = [CChar](repeating: 0, count: 256)
        sd_error_message(status, &buffer, Int32(buffer.count))
        message = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

func nativeString<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { bytes in
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

