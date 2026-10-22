import SwiftUI
import SIPCore
import SIPCore

struct AudioSettingsView: View {
    @EnvironmentObject private var model: SoftphoneModel

    var body: some View {
        VStack(spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Label(L("Audio devices"), systemImage: "waveform").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button { model.refreshDevices() } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                            .font(.system(size: 11)).disabled(model.call != nil || !model.engineReady)
                    }
                    Picker(L("Microphone"), selection: inputBinding) {
                        Text(L("System microphone")).tag("")
                        ForEach(model.devices.filter(\.hasInput)) { device in Text(device.name).tag(device.persistentKey) }
                        if let selected = model.audio.input, !model.devices.contains(where: { $0.persistentKey == selected && $0.hasInput }) {
                            Text(L("Unavailable → system default")).tag(selected)
                        }
                    }.disabled(model.call != nil)
                    Picker(L("Speakers"), selection: outputBinding) {
                        Text(L("System output device")).tag("")
                        ForEach(model.devices.filter(\.hasOutput)) { device in Text(device.name).tag(device.persistentKey) }
                        if let selected = model.audio.output, !model.devices.contains(where: { $0.persistentKey == selected && $0.hasOutput }) {
                            Text(L("Unavailable → system output")).tag(selected)
                        }
                    }.disabled(model.call != nil)
                    Toggle(L("Incoming call sound"), isOn: ringtoneBinding).font(.system(size: 12)).disabled(model.call != nil)
                    Text(L("The microphone opens only for an outgoing call or after you press Answer. No recording occurs during registration or while waiting for calls. The ringtone uses the system output."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button(L("Microphone permissions…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                        }
                        Button(L("macOS sound settings…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 17) {
                    Label(L("About the connection"), systemImage: "network").font(.system(size: 16, weight: .semibold))
                    Text(L("G.711 μ-law / A-law and G.722 codecs. DTMF uses RTP (RFC 4733) or SIP INFO. Signalling uses TLS encryption; voice uses SRTP/SDES if supported by the server."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Text(L("SIPDesk must stay running to receive calls. Closing the window does not disconnect the line: the app remains in the menu bar."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L("Session diagnostics · no SIP packets or passwords")) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(model.diagnostics.prefix(30)) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(entry.date, format: .dateTime.hour().minute().second()).foregroundStyle(Theme.muted)
                                    Text(entry.message).textSelection(.enabled)
                                }.font(.system(size: 10, design: .monospaced))
                            }
                        }.padding(.top, 15).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11))
                }
            }
        }.onAppear { model.refreshDevices() }
    }

    private var inputBinding: Binding<String> {
        Binding(get: { model.audio.input ?? "" }, set: { value in
            var audio = model.audio; audio.input = value.isEmpty ? nil : value; model.saveAudio(audio)
        })
    }
    private var outputBinding: Binding<String> {
        Binding(get: { model.audio.output ?? "" }, set: { value in
            var audio = model.audio; audio.output = value.isEmpty ? nil : value; model.saveAudio(audio)
        })
    }
    private var ringtoneBinding: Binding<Bool> {
        Binding(get: { model.audio.ringtoneEnabled }, set: { value in
            var audio = model.audio; audio.ringtoneEnabled = value; model.saveAudio(audio)
        })
    }
}

