import AppKit
import AVFoundation
import Combine
import SIPCore
import SIPRuntime

@MainActor
final class SoftphoneModel: ObservableObject {
    enum Section: String, CaseIterable {
        case dialer, history, audio
        var title: String {
            switch self { case .dialer: L("Keypad"); case .history: L("Recents"); case .audio: L("Audio settings") }
        }
        var symbol: String {
            switch self { case .dialer: "circle.grid.3x3.fill"; case .history: "clock.arrow.circlepath"; case .audio: "headphones" }
        }
    }

    @Published private(set) var profiles: [SIPAccount] = []
    @Published var editingAccount: SIPAccount?
    @Published var account: SIPAccount?
    @Published var connection: ConnectionState = .offline
    @Published var call: CallSession?
    @Published var dialTarget = ""
    @Published var section: Section = .dialer
    @Published var history: [CallRecord] = []
    @Published var audio = AudioPreferences()
    @Published var devices: [AudioDevice] = []
    @Published var diagnostics: [DiagnosticEntry] = []
    @Published var showingAccount = false
    @Published var showingCallKeypad = false
    @Published var doNotDisturb = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var engineReady = false
    @Published var preparingCall = false
    @Published var acceptingCall = false
    @Published var configurationBusy = false
    @Published var microphonePermission: AVAuthorizationStatus = .notDetermined
    @Published var requestingMicrophone = false
    @Published var engineVersion = "2.17-dev"
    let isPreview: Bool
    var showMainWindow: (() -> Void)?

    private var profileState = AccountProfiles()
    private var persistence: Persistence?
    private var worker: SIPWorker?
    private let sounds = CallAudio()
    private var generation: Int32 = 0
    private var preparationToken: UUID?
    private var preparationIntent: DialIntent?
    private var statisticsTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var shuttingDown = false
    private var deferredNetworkRefresh = false
    private var displayedLanguage = Localization.language
    private var languageSubscription: AnyCancellable?

    var isOnline: Bool { connection == .online }
    var canConfigure: Bool { call == nil && !preparingCall && !configurationBusy && !shuttingDown }
    var canCall: Bool { engineReady && isOnline && call == nil && !preparingCall && !configurationBusy && !dialTarget.isEmpty && microphonePermission == .authorized }

    init(preview: Bool = false) {
        isPreview = preview
        languageSubscription = NotificationCenter.default.publisher(for: Localization.didChange).sink { [weak self] _ in
            Task { @MainActor in self?.relocalizeMessages() }
        }
        if !preview { microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio) }
        if preview {
            account = SIPAccount(name: L("Work line"), server: "pbx.example.com", username: "1001", transport: .tls)
            account?.port = 5061
            account?.mediaEncryption = .required
            if let account { try? profileState.upsert(account); profiles = profileState.profiles }
            connection = .offline
            notice = L("Demo mode: network and Keychain are disabled.")
            return
        }
        Task { await boot() }
    }

    enum Presence: String, CaseIterable {
        case available, busy, offline
        var title: String {
            switch self { case .available: L("Available"); case .busy: L("Do not disturb"); case .offline: L("Offline") }
        }
    }

    var presence: Presence {
        guard isOnline || connection == .connecting else { return .offline }
        return doNotDisturb ? .busy : .available
    }

    var presenceTitle: String {
        if connection == .connecting { return connection.title }
        if case .failed = connection { return connection.title }
        return presence.title
    }

    func selectPresence(_ status: Presence) {
        guard engineReady, !configurationBusy, !shuttingDown else { return }
        if status == .offline {
            guard canConfigure else { return }
            disconnect()
        } else {
            guard account != nil else { openAccountEditor(profile: nil); return }
            guard isOnline || connection == .connecting || canConfigure else { return }
            doNotDisturb = status == .busy
            if !isOnline && connection != .connecting { connect() }
        }
    }

    func connect() {
        guard let account, let persistence, let worker, engineReady, canConfigure, !isPreview, !shuttingDown else { return }
        generation += 1
        let requestGeneration = generation
        connection = .connecting
        notice = nil
        log(L("Registration · {0}", String(account.transport.title)))
        Task {
            do {
                guard let password = try await persistence.password(for: account) else {
                    throw ConfigurationError(L("No password in Keychain. Open the account settings and save it again."))
                }
                guard requestGeneration == generation, !shuttingDown else { return }
                try await worker.connect(account: account, password: password, generation: requestGeneration)
            } catch {
                guard requestGeneration == generation else { return }
                connection = .failed(error.localizedDescription)
                log(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        guard canConfigure, let worker else { return }
        generation += 1
        let requestGeneration = generation
        connection = .offline
        Task {
            do { try await worker.disconnect(generation: requestGeneration) }
            catch { if generation == requestGeneration { report(error) } }
        }
    }

    private func applyProfiles(_ state: AccountProfiles) {
        profileState = state
        profiles = state.profiles
        account = state.activeAccount
    }

    func openAccountEditor(profile: SIPAccount?) {
        guard canConfigure else { return }
        if let profile {
            guard let saved = profiles.first(where: { $0.id == profile.id }) else { return }
            editingAccount = saved
        } else { editingAccount = nil }
        showingAccount = true
    }

    /// Reserves configuration synchronously so rapid menu clicks cannot queue switches.
    func selectProfile(_ id: UUID) {
        guard canConfigure, !isPreview, let persistence, account?.id != id else { return }
        var next = profileState
        do { try next.select(id) }
        catch { report(error); return }
        let reconnect = isOnline || connection == .connecting
        configurationBusy = true
        generation += 1
        let requestGeneration = generation
        Task {
            defer { configurationBusy = false }
            do {
                if let worker { try await worker.disconnect(generation: requestGeneration) }
                guard !shuttingDown, generation == requestGeneration else { return }
                connection = .offline
                try await persistence.save(profiles: next)
                guard !shuttingDown, generation == requestGeneration else { return }
                applyProfiles(next)
                notice = nil
                configurationBusy = false
                if reconnect { connect() }
            } catch {
                guard !shuttingDown, generation == requestGeneration else { return }
                connection = .failed(error.localizedDescription)
                report(error)
            }
        }
    }

    func saveAccount(_ proposed: SIPAccount, password: String, connectAfterSaving: Bool) async throws {
        guard canConfigure, !isPreview, let persistence else { throw ConfigurationError(L("Settings are currently unavailable.")) }
        if let editingAccount, editingAccount.id != proposed.id {
            throw ConfigurationError(L("The edited SIP profile identifier has changed."))
        }
        let validated = try proposed.validated()
        var next = profileState
        // Editing an inactive profile without connecting must not interrupt the active line.
        let affectsActive = try next.save(validated, activate: connectAfterSaving)
        configurationBusy = true
        defer { configurationBusy = false }
        if affectsActive {
            generation += 1
            if let worker { try await worker.disconnect(generation: generation) }
            connection = .offline
        }
        guard !shuttingDown else { throw ConfigurationError(L("The application is shutting down.")) }
        try await persistence.save(account: validated, password: password, profiles: next)
        guard !shuttingDown else { return }
        applyProfiles(next)
        showingAccount = false
        editingAccount = nil
        notice = nil
        log(L("Profile saved. The password is stored only in Keychain."))
        configurationBusy = false
        if connectAfterSaving { connect() }
    }

    func loadPassword(for profile: SIPAccount) async throws -> String {
        guard let persistence, !isPreview,
              profiles.contains(where: { $0.id == profile.id }) else { return "" }
        return try await persistence.password(for: profile) ?? ""
    }

    func loadPassword() async throws -> String {
        guard let profile = editingAccount ?? account else { return "" }
        return try await loadPassword(for: profile)
    }

    func removeAccount(profile: SIPAccount) async throws {
        guard canConfigure, !isPreview, let persistence else { throw ConfigurationError(L("Settings are currently unavailable.")) }
        guard let saved = profiles.first(where: { $0.id == profile.id }) else { throw ConfigurationError(L("SIP profile not found.")) }
        var next = profileState
        try next.remove(saved.id)
        let affectsActive = account?.id == saved.id
        configurationBusy = true
        defer { configurationBusy = false }
        if affectsActive {
            generation += 1
            if let worker { try await worker.disconnect(generation: generation) }
            connection = .offline
        }
        guard !shuttingDown else { throw ConfigurationError(L("The application is shutting down.")) }
        try await persistence.remove(account: saved, profiles: next)
        guard !shuttingDown else { return }
        applyProfiles(next)
        showingAccount = false
        editingAccount = nil
    }

    func removeAccount() async throws {
        guard let profile = editingAccount ?? account else { return }
        try await removeAccount(profile: profile)
    }

    func makeCall() {
        guard checkMicrophoneBeforeCall() else { return }
        guard canCall, let account, let worker, !isPreview else { return }
        let uri: String
        do { uri = try SIPAddress.destination(dialTarget, account: account) }
        catch { report(error); return }
        let token = UUID()
        let intent = DialIntent()
        let requestGeneration = generation
        preparationToken = token
        preparationIntent = intent
        preparingCall = true
        notice = nil
        Task {
            defer {
                if preparationIntent === intent { preparingCall = false; preparationToken = nil; preparationIntent = nil }
            }
            do {
                try await requireMicrophone()
                guard preparationToken == token, generation == requestGeneration, isOnline, call == nil, !shuttingDown else { return }
                try await worker.placeCall(uri: uri, audio: audio, intent: intent)
            } catch {
                if preparationToken == token { report(error) }
            }
        }
    }

    func cancelPreparation() {
        preparationIntent?.cancel()
        preparationToken = nil
        if preparationIntent == nil { preparingCall = false }
    }

    func answer() {
        guard checkMicrophoneBeforeCall() else { return }
        guard let call, call.isRinging, !acceptingCall, let worker else { return }
        let token = call.id
        acceptingCall = true
        Task {
            defer { acceptingCall = false }
            do {
                try await requireMicrophone()
                guard self.call?.id == token, self.call?.isRinging == true, !shuttingDown else { return }
                try await worker.answer(callID: call.nativeID, token: token, audio: audio)
            } catch {
                if self.call?.id == token { report(error) }
            }
        }
    }

    func hangup() {
        guard var current = call, !current.isEnding, let worker else { return }
        current.localDecline = current.isRinging
        current.localHangup = true
        current.isEnding = true
        call = current
        sounds.stop()
        Task {
            do { try await worker.hangup(callID: current.nativeID, token: current.id, reject: current.localDecline) }
            catch {
                guard call?.id == current.id else { return }
                call?.isEnding = false
                report(error)
            }
        }
    }

    func toggleMute() {
        guard let call, call.isConnected, !call.isEnding, let worker else { return }
        let next = !call.muted
        Task {
            do {
                try await worker.mute(callID: call.nativeID, token: call.id, muted: next)
                if self.call?.id == call.id { self.call?.muted = next }
            } catch { if self.call?.id == call.id { report(error) } }
        }
    }

    func toggleHold() {
        guard let call, call.isConnected, !call.isEnding, call.holdRequestedAt == nil, let worker else { return }
        self.call?.holdRequestedAt = Date()
        Task {
            do { try await worker.hold(callID: call.nativeID, token: call.id, held: !call.isHeld) }
            catch {
                if self.call?.id == call.id { self.call?.holdRequestedAt = nil; report(error) }
            }
        }
    }

    func appendDigit(_ digit: String) {
        if let call {
            guard call.isConnected, !call.isHeld, !call.isEnding, let account, let worker else { return }
            Task {
                do {
                    try await worker.sendDTMF(callID: call.nativeID, token: call.id, digits: digit, mode: account.dtmfMode)
                    if self.call?.id == call.id { self.call?.digits = String(((self.call?.digits ?? "") + digit).suffix(32)) }
                } catch { if self.call?.id == call.id { report(error) } }
            }
        } else if dialTarget.count < 256 { dialTarget += digit }
    }

    func selectRecent(_ record: CallRecord) {
        guard call == nil else { return }
        guard record.accountID == account?.id else {
            notice = L("This call belongs to another account. Dial the number manually on the current line.")
            return
        }
        var uri = record.remoteURI
        if let start = uri.firstIndex(of: "<"), let end = uri.lastIndex(of: ">"), start < end {
            uri = String(uri[uri.index(after: start)..<end])
        }
        dialTarget = uri
        section = .dialer
    }

    func clearHistory() {
        guard let persistence else { return }
        Task {
            do { try await persistence.save(history: []); history = [] }
            catch { report(error) }
        }
    }

    func saveAudio(_ preferences: AudioPreferences) {
        guard call == nil, let persistence else { return }
        audio = preferences
        Task {
            do { try await persistence.save(audio: preferences) }
            catch { report(error) }
        }
    }

    func refreshDevices() {
        guard let worker, call == nil else { return }
        Task {
            do { devices = try await worker.devices() }
            catch { report(error) }
        }
    }

    func handleURL(_ url: URL) {
        guard ["sip", "sips", "tel"].contains(url.scheme?.lowercased() ?? "") else { return }
        guard call == nil else { notice = L("End the current call first."); return }
        dialTarget = url.absoluteString
        section = .dialer
        notice = L("Number from a link. Check it and press Call: there is no automatic dialling.")
        showMainWindow?()
    }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        shuttingDown = true
        let needsFinalCallSave = call != nil
        cancelPreparation()
        sounds.stop()
        statisticsTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let call {
            let outcome = CallRecord.outcome(direction: call.direction, connected: call.connectedAt != nil,
                                             localDecline: call.localDecline || call.isRinging, localHangup: true, statusCode: 0)
            history.insert(CallRecord(id: call.recordID, accountID: call.accountID, remoteURI: call.remoteURI,
                                      displayName: call.displayName, direction: call.direction, startedAt: call.startedAt,
                                      connectedAt: call.connectedAt, endedAt: Date(), outcome: outcome), at: 0)
            history = Array(history.prefix(200))
            self.call = nil
        }
        let snapshot = history
        Task {
            if needsFinalCallSave, let persistence { try? await persistence.save(history: snapshot) }
            if let worker { worker.shutdown(completion: completion) }
            else { completion() }
        }
    }

    private func boot() async {
        do {
            let persistence = try Persistence()
            self.persistence = persistence
            let snapshot = try await persistence.load()
            applyProfiles(snapshot.profiles)
            audio = snapshot.audio
            history = snapshot.history
        } catch { report(error) }
        guard !shuttingDown else { return }
        let engine = SIPWorker()
        worker = engine
        eventTask = Task { [weak self] in
            for await signal in engine.signals { self?.receive(signal) }
        }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        observers.append(wake)
    }

    private func receive(_ signal: EngineSignal) {
        guard !shuttingDown else { return }
        switch signal {
        case .ready(let version):
            engineReady = true
            engineVersion = version
            log(L("PJSIP {0} is ready. The microphone stays closed until a call.", String(version)))
            refreshDevices()
            if account?.connectOnLaunch == true { connect() }
        case .failed(let failure):
            engineReady = false
            connection = .failed(failure.message)
            report(failure)
        case .stopped:
            engineReady = false
            connection = .offline
        case .event(let event):
            guard event.generation == generation else { return }
            handle(event)
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event.kind {
        case .registration:
            if event.registered {
                connection = .online
                notice = nil
                log(L("Registration successful · SIP {0}", String(event.code)))
            } else if (200..<300).contains(event.code) {
                connection = .offline
            } else if event.code != 0 {
                let message = SIPStatus.explanation(code: Int(event.code), fallback: event.message)
                connection = .failed(message)
                log(message)
            } else if connection != .connecting { connection = .offline }
        case .incoming, .call, .media:
            guard let account, event.callToken != 0 else { return }
            if call == nil {
                guard event.state != 6 else { return }
                if event.incoming { cancelPreparation() }
                call = CallSession(event: event, accountID: account.id)
                showingAccount = false
                section = .dialer
                showingCallKeypad = false
                log(event.incoming ? L("Incoming call") : L("Outgoing call"))
                if event.incoming {
                    if doNotDisturb { hangup(); return }
                    showMainWindow?()
                }
            }
            guard call?.id == event.callToken else { return }
            call?.state = event.state
            call?.mediaState = event.mediaState
            if !event.remoteURI.isEmpty { call?.remoteURI = event.remoteURI }
            if !event.displayName.isEmpty { call?.displayName = event.displayName }
            if event.kind == .media { call?.holdRequestedAt = nil }
            if event.state == 5, call?.connectedAt == nil {
                call?.connectedAt = Date()
                beginStatistics()
                log(L("Call connected"))
            }
            if event.state == 6 { finishCall(event); return }
            updateSounds(code: event.code)
        case .warning:
            notice = Localization.engineMessage(event.message)
            log(Localization.engineMessage(event.message))
        case .rejected:
            guard let account else { return }
            addRecord(CallRecord(accountID: account.id, remoteURI: event.remoteURI, displayName: event.displayName,
                                 direction: .incoming, startedAt: Date(), endedAt: Date(), outcome: .missed))
            log(L("Second incoming call rejected: the line is busy."))
        case .dtmf:
            break
        case .audioRecovered:
            log(L("Audio stream recovered after a device or volume change."))
        }
    }

    private func finishCall(_ event: EngineEvent) {
        guard let call else { return }
        sounds.stop()
        statisticsTask?.cancel()
        statisticsTask = nil
        let outcome = CallRecord.outcome(direction: call.direction, connected: call.connectedAt != nil,
                                         localDecline: call.localDecline, localHangup: call.localHangup, statusCode: Int(event.code))
        addRecord(CallRecord(id: call.recordID, accountID: call.accountID, remoteURI: call.remoteURI,
                             displayName: call.displayName, direction: call.direction, startedAt: call.startedAt,
                             connectedAt: call.connectedAt, endedAt: Date(), outcome: outcome))
        if outcome == .failed { notice = SIPStatus.explanation(code: Int(event.code), fallback: event.message) }
        log(L("Call ended · {0} · {1}", String(event.code), String(outcome.title)))
        self.call = nil
        acceptingCall = false
        showingCallKeypad = false
        Task { await worker?.disableSound() }
        if deferredNetworkRefresh { deferredNetworkRefresh = false; networkChanged() }
    }

    private func addRecord(_ record: CallRecord) {
        history.insert(record, at: 0)
        history = Array(history.prefix(200))
        guard let persistence else { return }
        let snapshot = history
        Task {
            do { try await persistence.save(history: snapshot) }
            catch { report(error) }
        }
    }

    private func updateSounds(code: Int32) {
        guard let call, !call.isEnding else { sounds.stop(); return }
        if call.isRinging && audio.ringtoneEnabled { sounds.ring() }
        else if call.direction == .outgoing && call.state == 3 && code == 180 && call.mediaState != 1 { sounds.ringback() }
        else { sounds.stop() }
    }

    private func beginStatistics() {
        statisticsTask?.cancel()
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let call = self.call, let worker = self.worker else { return }
                let statistics = await worker.statistics(callID: call.nativeID, token: call.id)
                if self.call?.id == call.id { self.call?.statistics = statistics }
                if let requested = self.call?.holdRequestedAt, Date().timeIntervalSince(requested) > 10 {
                    self.call?.holdRequestedAt = nil
                    self.notice = L("The server did not confirm the hold change.")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func networkChanged() {
        guard let worker, isOnline || connection == .connecting else { return }
        if call != nil { deferredNetworkRefresh = true; return }
        connection = .connecting
        log(L("Restoring registration after macOS sleep"))
        Task {
            do { try await worker.networkChanged() }
            catch { report(error); connection = .failed(error.localizedDescription) }
        }
    }

    func refreshMicrophonePermission() {
        guard !isPreview else { return }
        microphonePermission = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var microphonePermissionTitle: String {
        switch microphonePermission {
        case .authorized: L("Allowed")
        case .notDetermined: L("Not requested")
        case .denied: L("Denied")
        case .restricted: L("Restricted by the system")
        @unknown default: L("Unavailable")
        }
    }

    func requestMicrophoneFromSettings() {
        refreshMicrophonePermission()
        guard !isPreview, call == nil, !requestingMicrophone else { return }
        if microphonePermission == .notDetermined {
            requestingMicrophone = true
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refreshMicrophonePermission()
                requestingMicrophone = false
            }
        } else if microphonePermission != .authorized,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func checkMicrophoneBeforeCall() -> Bool {
        refreshMicrophonePermission()
        guard microphonePermission == .authorized else {
            section = .audio
            notice = L("Allow microphone access in SIPDesk settings before calling.")
            showMainWindow?()
            return false
        }
        return true
    }

    private func requireMicrophone() async throws {
        refreshMicrophonePermission()
        guard microphonePermission == .authorized else {
            throw ConfigurationError(L("Microphone access has changed. Allow it in settings before calling."))
        }
    }

    private func relocalizeMessages() {
        let source = displayedLanguage
        displayedLanguage = Localization.language
        notice = notice.map { Localization.relocalize($0, from: source) }
        errorMessage = errorMessage.map { Localization.relocalize($0, from: source) }
        if case .failed(let message) = connection { connection = .failed(Localization.relocalize(message, from: source)) }
        diagnostics = diagnostics.map { entry in
            var translated = entry
            translated.message = Localization.relocalize(entry.message, from: source)
            return translated
        }
        if isPreview {
            account?.name = L("Work line")
            if call?.displayName == (try? Localization.catalog(source)["Test call"]) { call?.displayName = L("Test call") }
        }
        objectWillChange.send()
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        log(error.localizedDescription)
    }

    private func log(_ message: String) {
        diagnostics.insert(DiagnosticEntry(message: message), at: 0)
        diagnostics = Array(diagnostics.prefix(100))
    }
}
