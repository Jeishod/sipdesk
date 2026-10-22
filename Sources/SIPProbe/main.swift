import Foundation
import Darwin
import SIPCore
import SIPBridge

func emit(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}

func text<Value>(_ value: Value) -> String {
    withUnsafeBytes(of: value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}

func option(_ name: String, default fallback: String) -> String {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[index + 1]
}

func describe(_ status: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    sd_error_message(status, &buffer, 256)
    return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let status = sd_initialize(1)
guard status == 0 else { emit(["event": "fatal", "phase": "initialize", "code": status, "message": describe(status)]); exit(1) }
let transport = SIPTransport(rawValue: option("--transport", default: "udp")) ?? .udp
let username = option("--user", default: "alice")
let serverPort = Int32(option("--registrar-port", default: "0")) ?? 0
let localPort = Int32(option("--port", default: "0")) ?? 0
let localIPv6 = CommandLine.arguments.contains("--ipv6")
let host = localIPv6 ? "[::1]" : "127.0.0.1"
let password = "loopback-test-only"
let identity = "sip:\(username)@\(host)"
let registrar = "sip:\(host):\(serverPort == 0 ? 5060 : serverPort);transport=\(transport.rawValue)"
let connectStatus = identity.withCString { identityPointer in
    registrar.withCString { registrarPointer in
        username.withCString { usernamePointer in
            password.withCString { passwordPointer in
                var config = SDAccountConfig()
                config.generation = 1
                config.identity = identityPointer
                config.registrar = registrarPointer
                config.username = usernamePointer
                config.password = passwordPointer
                config.transport = transport.nativeValue
                config.local_port = localPort
                config.ipv6 = localIPv6 ? 1 : 0
                config.register_account = serverPort > 0 ? 1 : 0
                return sd_connect(&config)
            }
        }
    }
}
guard connectStatus == 0 else {
    emit(["event": "fatal", "phase": "connect", "code": connectStatus, "message": describe(connectStatus)])
    sd_shutdown()
    exit(1)
}
emit(["event": "ready", "port": sd_local_port(), "version": String(cString: sd_version()), "transport": transport.rawValue])
let inputFlags = fcntl(STDIN_FILENO, F_GETFL)
_ = fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK)
var input = Data()
var running = true
let deadline = Date().addingTimeInterval(120)

while running && Date() < deadline {
    sd_poll(20)
    var nativeEvent = SDEvent()
    while sd_next_event(&nativeEvent) != 0 {
        emit(["event": "sip", "type": nativeEvent.type, "call_id": nativeEvent.call_id,
              "token": nativeEvent.call_token, "generation": nativeEvent.generation,
              "code": nativeEvent.code, "state": nativeEvent.state, "incoming": nativeEvent.incoming,
              "media_state": nativeEvent.media_state, "registered": nativeEvent.registered,
              "remote": text(nativeEvent.remote_uri), "message": text(nativeEvent.message)])
    }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
    if count == 0 { break }
    if count > 0 { input.append(contentsOf: bytes.prefix(count)) }
    if input.count > 65536 { emit(["event": "fatal", "message": "Input too long"]); break }
    while let newline = input.firstIndex(of: 10) {
        let line = Data(input[..<newline])
        input.removeSubrange(...newline)
        guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let action = command["action"] as? String else { continue }
        let callID = sd_active_call_id()
        var result: Int32 = 0
        switch action {
        case "dial":
            let port = command["port"] as? Int ?? 0
            let targetUser = command["user"] as? String ?? "bob"
            if port < 1 || port > 65535 { result = -1; break }
            var created: Int32 = -1
            let uri = "sip:\(SIPAddress.escapedUser(targetUser))@\(host):\(port);transport=\(transport.rawValue)"
            result = uri.withCString { sd_dial($0, &created) }
        case "answer": result = sd_answer(callID)
        case "hangup": result = sd_hangup(callID, 0)
        case "reject": result = sd_hangup(callID, 603)
        case "mute": result = sd_set_mute(callID, command["enabled"] as? Bool == true ? 1 : 0)
        case "hold": result = sd_set_hold(callID, command["enabled"] as? Bool == true ? 1 : 0)
        case "dtmf":
            let digits = command["digits"] as? String ?? "5"
            result = digits.withCString { sd_send_dtmf(callID, $0, command["info"] as? Bool == true ? 1 : 0) }
        case "tone": result = sd_probe_tone(callID)
        case "recover_audio": result = sd_recover_sound()
        case "stats":
            var stats = SDCallStatistics()
            result = sd_call_statistics(callID, &stats)
            if result == 0 {
                emit(["event": "stats", "tx": stats.tx_packets, "rx": stats.rx_packets,
                      "loss": stats.rx_lost, "codec": text(stats.codec), "secure": stats.secure_media,
                      "input_level": stats.input_level, "output_level": stats.output_level])
            }
        case "disconnect": result = sd_disconnect(2)
        case "quit": running = false
        default: result = -1
        }
        emit(["event": "command", "action": action, "status": result, "message": result == 0 ? "OK" : describe(result)])
    }
}
sd_shutdown()
emit(["event": "stopped"])

