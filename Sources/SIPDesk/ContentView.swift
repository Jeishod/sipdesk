import AppKit
import SwiftUI
import SIPCore

/// The entire everyday interface lives in the menu-bar panel.
struct ContentView: View {
    @EnvironmentObject private var model: SoftphoneModel
    @EnvironmentObject private var language: LanguageSettings
    @State private var historyQuery = ""
    @State private var confirmClear = false
    @FocusState private var dialFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.call == nil, let message = notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(L("Dismiss notification"))
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .padding(10).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider().overlay(Theme.border)
            Group {
                if let call = model.call { callPanel(call) }
                else {
                    switch model.section {
                    case .dialer: dialer
                    case .history: history
                    case .audio: settings
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().overlay(Theme.border)
            bottomBar
        }
        .frame(width: 360, height: 580)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshMicrophonePermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshMicrophonePermission() }
        .sheet(isPresented: $model.showingAccount) {
            AccountSheet(account: model.editingAccount ?? SIPAccount()).environmentObject(model).environmentObject(language)
                .preferredColorScheme(.dark)
        }
        .alert("SIPDesk", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("OK"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(L("Clear call history on this Mac?"), isPresented: $confirmClear) {
            Button(L("Clear history"), role: .destructive) { model.clearHistory() }
        } message: { Text(L("The SIP server log will not change.")) }
    }

    private var notice: String? {
        if let notice = model.notice { return notice }
        if case .failed(let message) = model.connection { return message }
        return nil
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: model.call?.isRinging == true ? "phone.arrow.down.left.fill" : "phone.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32).background(Theme.paleAccent, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("SIPDesk").font(.system(size: 14, weight: .semibold))
                Text(model.account?.name ?? L("No line configured"))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            FullAreaButton(identifier: "presenceMenu", enabled: model.engineReady && !model.configurationBusy, action: { button in
                let menu = PresenceMenu(model: model)
                // Open under the trailing edge, where the status label sits.
                let x = button.userInterfaceLayoutDirection == .rightToLeft ? 0 : button.bounds.maxX - menu.size.width
                menu.popUp(positioning: nil, at: NSPoint(x: x, y: button.bounds.maxY + 4), in: button)
            }) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(model.presenceTitle).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.muted).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.muted)
                }.padding(.leading, 8).padding(.trailing, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
            }.frame(width: 136, height: 40)
                .accessibilityLabel(L("Status: {0}", String(model.presenceTitle)))
        }.padding(.horizontal, 16).frame(height: 59)
    }

    private var statusColor: Color {
        switch model.connection {
        case .online: model.doNotDisturb ? Theme.warning : Theme.accent
        case .connecting: Theme.warning
        case .failed: Theme.danger
        case .offline: Theme.muted
        }
    }

    private var dialer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("NEW CALL")).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                Spacer()

            }.padding(.top, 19)
            HStack(spacing: 8) {
                TextField(L("Number or SIP address"), text: $model.dialTarget)
                    .environment(\.layoutDirection, .leftToRight)
                    .focused($dialFocused)
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .rounded))
                    .onSubmit { model.makeCall() }.disabled(model.preparingCall)
                    .accessibilityIdentifier("dialTarget")
                if !model.dialTarget.isEmpty {
                    Button { model.dialTarget.removeLast() } label: { Image(systemName: "delete.left") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(model.preparingCall)
                        .accessibilityLabel(L("Delete last character"))
                }
            }.frame(height: 48).padding(.horizontal, 12)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .padding(.top, 17)
            DialPad(action: { digit in
                model.appendDigit(digit)
                dialFocused = true
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                    }
                }
            }, compact: true)
                .disabled(model.preparingCall).padding(.top, 12)
            Spacer(minLength: 8)
            if model.preparingCall {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Preparing call…")).font(.system(size: 11))
                    Spacer()
                    Button(L("Cancel")) { model.cancelPreparation() }.buttonStyle(.plain)
                }.frame(height: 42)
            } else if model.account == nil {
                Button(L("Set up SIP line")) { model.openAccountEditor(profile: nil) }
                    .buttonStyle(ActionButtonStyle()).disabled(!model.canConfigure)
            } else {
                Button { model.makeCall() } label: { Label(L("Call"), systemImage: "phone.fill") }
                    .buttonStyle(ActionButtonStyle()).disabled(!model.canCall)
                    .accessibilityIdentifier("callButton")
                if model.microphonePermission != .authorized {
                    Button(L("Allow microphone before calling")) { model.section = .audio }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.warning).padding(.top, 8)
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 19)
    }

    private func callPanel(_ call: CallSession) -> some View {
        VStack(spacing: 0) {
            Text(call.status.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(call.isRinging ? Theme.accent : Theme.muted).padding(.top, model.showingCallKeypad ? 12 : 52)
            if !model.showingCallKeypad { Image(systemName: call.isRinging ? "phone.arrow.down.left" : "waveform")
                .font(.system(size: 27, weight: .light)).foregroundStyle(Theme.accent)
                .frame(width: model.showingCallKeypad ? 38 : 68, height: model.showingCallKeypad ? 38 : 68)
                .background(Theme.paleAccent, in: Circle()).padding(.top, 25) }
            Text(call.title).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                .padding(.top, model.showingCallKeypad ? 8 : 23)
            if !model.showingCallKeypad { Text(call.remoteURI).environment(\.layoutDirection, .leftToRight).font(.system(size: 10)).foregroundStyle(Theme.muted)
                .lineLimit(1).textSelection(.enabled).padding(.top, 6) }
            if !call.isRinging {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(call.connectedAt.map { CallRecord.formattedDuration(timeline.date.timeIntervalSince($0)) } ?? "—:—")
                        .font(.system(size: 19, design: .monospaced)).foregroundStyle(Theme.muted)
                }.padding(.top, model.showingCallKeypad ? 0 : 14)
            }
            Spacer()
            if call.isRinging {
                HStack(spacing: 10) {
                    Button { model.hangup() } label: { Label(L("Decline"), systemImage: "phone.down.fill") }
                        .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(call.isEnding)
                    Button { model.answer() } label: { Label(model.acceptingCall ? L("Microphone…") : L("Answer"), systemImage: "phone.fill") }
                        .buttonStyle(ActionButtonStyle()).disabled(model.acceptingCall || call.isEnding)
                        .accessibilityIdentifier("answerButton")
                }
            } else {
                HStack(spacing: 12) {
                    callControl(call.muted ? "mic.slash" : "mic", title: call.muted ? L("Unmute") : L("Microphone")) { model.toggleMute() }
                        .disabled(!call.isConnected || call.isEnding)
                    callControl(call.isHeld ? "play" : "pause", title: call.isHeld ? L("Resume") : L("Hold call")) { model.toggleHold() }
                        .disabled(!call.isConnected || call.isEnding || call.holdRequestedAt != nil)
                    callControl("circle.grid.3x3", title: L("Keypad")) { model.showingCallKeypad.toggle() }
                        .disabled(!call.isConnected || call.isEnding)
                }.padding(.bottom, 12)
                if model.showingCallKeypad {
                    Text(call.digits.isEmpty ? "DTMF" : call.digits).environment(\.layoutDirection, .leftToRight).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    DialPad(action: { model.appendDigit($0) }, compact: true).disabled(call.isHeld || call.isEnding)
                        .padding(.top, 8).padding(.bottom, 12)
                }
                Button { model.hangup() } label: { Label(L("End call"), systemImage: "phone.down.fill") }
                    .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(call.isEnding)
                    .accessibilityIdentifier("hangupButton")
            }
        }.padding(.horizontal, 20).padding(.bottom, 19)
    }

    private func callControl(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).frame(maxWidth: .infinity).frame(height: 38)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("CALL HISTORY")).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(Theme.muted)
                Spacer()
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(model.history.isEmpty).help(L("Clear history"))
            }.padding(.top, 19).padding(.bottom, 15)
            TextField(L("Search by number or name"), text: $historyQuery)
                .textFieldStyle(.plain).font(.system(size: 12)).padding(11)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            let records = model.history.filter { historyQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(historyQuery) || $0.remoteURI.localizedCaseInsensitiveContains(historyQuery) }
            if records.isEmpty {
                EmptyState(symbol: "clock", title: L("No calls yet"), detail: L("History stays on this Mac."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            Button { model.selectRecent(record) } label: { RecentCallRow(record: record, compact: true).padding(.vertical, 12) }
                                .buttonStyle(.plain).disabled(model.call != nil)
                                .help(L("Insert number without calling automatically"))
                            Divider().overlay(Theme.border)
                        }
                    }
                }.scrollIndicators(.hidden).padding(.top, 8)
            }
        }.padding(.horizontal, 20)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("SETTINGS")).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(Theme.muted)
            Picker(L("Language"), selection: Binding(get: { language.selection }, set: { value in
                do { try language.select(value) } catch { model.errorMessage = L("Could not save the language preference.") }
            })) {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    Text(option == .system ? L("System") : option.nativeName).tag(option)
                }
            }.accessibilityIdentifier("languageSelector")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Microphone access"))
                    Text(model.microphonePermissionTitle).font(.system(size: 10))
                        .foregroundStyle(model.microphonePermission == .authorized ? Theme.accent : Theme.warning)
                }
                Spacer()
                if model.microphonePermission != .authorized {
                    Button(model.microphonePermission == .notDetermined ? L("Allow") : L("macOS Settings")) {
                        model.requestMicrophoneFromSettings()
                    }.disabled(model.requestingMicrophone || model.call != nil)
                } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            HStack {
                Text(L("Connection profiles")).fontWeight(.medium)
                Spacer()
                Button { model.openAccountEditor(profile: nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(!model.canConfigure).help(L("Add SIP profile"))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.profiles) { profile in
                        let active = model.account?.id == profile.id
                        HStack(spacing: 8) {
                            FullAreaButton(identifier: "profile-\(profile.id.uuidString)", enabled: model.canConfigure, action: { _ in model.selectProfile(profile.id) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(active ? Theme.accent : Theme.muted)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).fontWeight(.medium).lineLimit(1)
                                        HStack(spacing: 5) {
                                            Text(profile.username).lineLimit(1).truncationMode(.middle)
                                            Text("·")
                                            if active { Circle().fill(statusColor).frame(width: 6, height: 6) }
                                            Text(active ? model.presenceTitle : L("Inactive")).lineLimit(1).layoutPriority(1)
                                        }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }.frame(height: 48)
                            Button { model.openAccountEditor(profile: profile) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain).disabled(!model.canConfigure).help(L("Edit profile"))
                                .padding(.trailing, 10)
                        }
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1))
                    }
                }.padding(1)
            }.frame(height: CGFloat(max(min(model.profiles.count, 2) * 56 - 6, 0)))
            Divider().overlay(Theme.border)
            Toggle(L("Do not disturb"), isOn: $model.doNotDisturb)
                .help(L("Decline incoming calls"))
            Toggle(L("Ringtone"), isOn: Binding(
                get: { model.audio.ringtoneEnabled },
                set: { value in var audio = model.audio; audio.ringtoneEnabled = value; model.saveAudio(audio) }
            )).disabled(model.call != nil)
            Divider().overlay(Theme.border)
            Picker(L("Microphone"), selection: audioDeviceBinding(input: true)) {
                Text(L("System default")).tag("")
                ForEach(model.devices.filter(\.hasInput)) { device in Text(device.name).tag(device.persistentKey) }
            }.disabled(model.call != nil)
            Picker(L("Speakers"), selection: audioDeviceBinding(input: false)) {
                Text(L("System speakers")).tag("")
                ForEach(model.devices.filter(\.hasOutput)) { device in Text(device.name).tag(device.persistentKey) }
            }.disabled(model.call != nil)
            Spacer()
            Text(L("Calls are received while SIPDesk is running. The password is stored in Keychain."))
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).padding(20).onAppear { model.refreshDevices(); model.refreshMicrophonePermission() }
    }

    private func audioDeviceBinding(input: Bool) -> Binding<String> {
        Binding(get: { (input ? model.audio.input : model.audio.output) ?? "" }, set: { value in
            var audio = model.audio
            if input { audio.input = value.isEmpty ? nil : value }
            else { audio.output = value.isEmpty ? nil : value }
            model.saveAudio(audio)
        })
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tab(.dialer, L("Dial"), "circle.grid.3x3")
            tab(.history, L("History"), "clock.arrow.circlepath")
            tab(.audio, L("Settings"), "gearshape")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 33, height: 38) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).help(L("Quit SIPDesk"))
                .accessibilityLabel(L("Quit SIPDesk"))
        }.padding(.horizontal, 12).frame(height: 50)
    }

    private func tab(_ section: SoftphoneModel.Section, _ title: String, _ symbol: String) -> some View {
        FullAreaButton(identifier: "tab-\(section.rawValue)", enabled: model.call == nil, action: { _ in model.section = section }) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(model.section == section ? Theme.ink : Theme.muted)
                .background(model.section == section ? Theme.sidebar : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.frame(maxWidth: .infinity).frame(height: 38)
    }
}
