import Foundation
import SIPCore
import SIPBridge

public final class DialIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

public final class SIPWorker: @unchecked Sendable {
    public let signals: AsyncStream<EngineSignal>
    private struct Work: Sendable {
        let run: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var queue: [Work] = []
    private var acceptsWork = true
    private var shutdownCompletions: [@Sendable () -> Void] = []
    private var didStop = false
    private var keepRunning = true
    private var thread: Thread?
    private let signalContinuation: AsyncStream<EngineSignal>.Continuation
    private let headless: Bool

    public init(headless: Bool = false) {
        self.headless = headless
        let stream = AsyncStream<EngineSignal>.makeStream()
        signals = stream.stream
        signalContinuation = stream.continuation
        thread = Thread { [weak self] in self?.run() }
        thread?.name = "SIPDesk.PJSIP"
        thread?.qualityOfService = .userInitiated
        thread?.start()
    }

    public func connect(account: SIPAccount, password: String, generation: Int32) async throws {
        let account = try account.validated()
        guard !password.isEmpty, password.utf8.count <= 1024, !password.contains("\0") else {
            throw SIPFailure(message: L("Invalid SIP password."))
        }
        try await perform {
            let strings = CStringStorage()
            var config = SDAccountConfig()
            config.generation = generation
            config.identity = strings.add(account.identityURI)
            config.registrar = strings.add(account.registrarURI)
            config.username = strings.add(account.authenticationUser)
            config.password = strings.add(password)
            config.proxy = strings.add(account.outboundProxy.isEmpty ? "" : try SIPAddress.proxy(account.outboundProxy, transport: account.transport))
            config.stun_server = strings.add(account.stunServer)
            config.transport = account.transport.nativeValue
            config.ipv6 = account.server.hasPrefix("[") ? 1 : 0
            config.local_port = 0
            config.media_encryption = account.mediaEncryption.nativeValue
            config.use_ice = account.useICE ? 1 : 0
            config.register_account = 1
            try Self.check(sd_connect(&config))
            withExtendedLifetime(strings) {}
        }
    }

    public func disconnect(generation: Int32) async throws {
        try await perform { try Self.check(sd_disconnect(generation)) }
    }

    public func placeCall(uri: String, audio: AudioPreferences, intent: DialIntent = DialIntent()) async throws {
        try await perform {
            if intent.isCancelled { throw CancellationError() }
            guard sd_active_call_id() < 0 else { throw SIPFailure(message: L("An active or incoming call already exists.")) }
            try Self.enableSound(audio)
            if intent.isCancelled {
                _ = sd_disable_sound()
                throw CancellationError()
            }
            var callID: Int32 = -1
            let result = uri.withCString { sd_dial($0, &callID) }
            if result != 0 { _ = sd_disable_sound() }
            if intent.isCancelled, result == 0 {
                if sd_active_call_id() == callID { _ = sd_hangup(callID, 0) }
                throw CancellationError()
            }
            try Self.check(result)
        }
    }

    public func answer(callID: Int32, token: UInt64, audio: AudioPreferences) async throws {
        try await perform {
            try Self.validate(callID: callID, token: token)
            try Self.enableSound(audio)
            try Self.check(sd_answer(callID))
        }
    }

    public func hangup(callID: Int32, token: UInt64, reject: Bool) async throws {
        try await perform {
            try Self.validate(callID: callID, token: token)
            try Self.check(sd_hangup(callID, reject ? 603 : 0))
        }
    }

    public func mute(callID: Int32, token: UInt64, muted: Bool) async throws {
        try await perform {
            try Self.validate(callID: callID, token: token)
            try Self.check(sd_set_mute(callID, muted ? 1 : 0))
        }
    }

    public func hold(callID: Int32, token: UInt64, held: Bool) async throws {
        try await perform {
            try Self.validate(callID: callID, token: token)
            try Self.check(sd_set_hold(callID, held ? 1 : 0))
        }
    }

    public func sendDTMF(callID: Int32, token: UInt64, digits: String, mode: DTMFMode) async throws {
        try await perform {
            try Self.validate(callID: callID, token: token)
            try Self.check(digits.withCString { sd_send_dtmf(callID, $0, mode == .sipInfo ? 1 : 0) })
        }
    }

    public func disableSound() async {
        _ = try? await perform { sd_disable_sound() }
    }

    public func devices(refresh: Bool = true) async throws -> [AudioDevice] {
        try await perform { try Self.readDevices(refresh: refresh) }
    }

    public func statistics(callID: Int32, token: UInt64) async -> CallStatistics? {
        try? await perform {
            try Self.validate(callID: callID, token: token)
            var statistics = SDCallStatistics()
            try Self.check(sd_call_statistics(callID, &statistics))
            return CallStatistics(statistics)
        }
    }

    public func networkChanged() async throws {
        try await perform { try Self.check(sd_network_changed()) }
    }

    public func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if didStop { lock.unlock(); completion(); return }
        shutdownCompletions.append(completion)
        guard acceptsWork else { lock.unlock(); return }
        acceptsWork = false
        let pending = queue
        queue = [Work(run: { [weak self] in self?.keepRunning = false }, cancel: {})]
        lock.unlock()
        pending.forEach { $0.cancel() }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let work = Work(
                run: {
                    do { continuation.resume(returning: try operation()) }
                    catch { continuation.resume(throwing: error) }
                },
                cancel: { continuation.resume(throwing: SIPFailure(message: L("The SIP engine has stopped."))) }
            )
            lock.lock()
            let accepted = acceptsWork
            if accepted { queue.append(work) }
            lock.unlock()
            if !accepted { work.cancel() }
        }
    }

    private func run() {
        let result = sd_initialize(headless ? 1 : 0)
        if result != 0 {
            signalContinuation.yield(.failed(SIPFailure(status: result)))
            finish()
            return
        }
        signalContinuation.yield(.ready(version: String(cString: sd_version())))
        while keepRunning {
            autoreleasepool {
                lock.lock()
                let pending = queue
                queue.removeAll(keepingCapacity: true)
                lock.unlock()
                for work in pending { work.run() }
                if keepRunning {
                    sd_poll(40)
                    var raw = SDEvent()
                    while sd_next_event(&raw) != 0 {
                        if let event = EngineEvent(raw) { signalContinuation.yield(.event(event)) }
                    }
                }
            }
        }
        sd_shutdown()
        signalContinuation.yield(.stopped)
        finish()
    }

    private func finish() {
        lock.lock()
        acceptsWork = false
        didStop = true
        let pending = queue
        let completions = shutdownCompletions
        queue.removeAll()
        shutdownCompletions.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
        completions.forEach { $0() }
        signalContinuation.finish()
    }

    private static func check(_ status: Int32) throws {
        if status != 0 { throw SIPFailure(status: status) }
    }

    private static func validate(callID: Int32, token: UInt64) throws {
        guard callID == sd_active_call_id(), token > 0, token == sd_active_call_token() else {
            throw SIPFailure(message: L("This call has already ended."))
        }
    }

    private static func readDevices(refresh: Bool) throws -> [AudioDevice] {
        var raw = [SDAudioDevice](repeating: SDAudioDevice(), count: 64)
        let count = sd_audio_devices(&raw, Int32(raw.count), refresh ? 1 : 0)
        guard count >= 0 else { throw SIPFailure(message: L("Could not retrieve macOS audio devices.")) }
        return raw.prefix(Int(count)).map(AudioDevice.init)
    }

    private static func enableSound(_ preferences: AudioPreferences) throws {
        let devices = try readDevices(refresh: false)
        let input = devices.first(where: { $0.hasInput && $0.persistentKey == preferences.input })?.id ?? -1
        let output = devices.first(where: { $0.hasOutput && $0.persistentKey == preferences.output })?.id ?? -2
        try check(sd_enable_sound(input, output))
    }
}

private final class CStringStorage {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func add(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for pointer in pointers {
            memset_s(pointer, strlen(pointer), 0, strlen(pointer))
            free(pointer)
        }
    }
}
