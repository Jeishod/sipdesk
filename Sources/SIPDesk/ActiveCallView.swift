import SwiftUI
import SIPCore
import SIPCore

struct ActiveCallView: View {
    @EnvironmentObject private var model: SoftphoneModel
    let call: CallSession

    var body: some View {
        Card(padding: 27) {
            VStack(spacing: 19) {
                Text(call.status.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(call.isRinging ? Theme.accent : Theme.muted)
                ZStack {
                    Circle().fill(Theme.paleAccent).frame(width: 91, height: 91)
                    Image(systemName: call.isRinging ? "phone.arrow.down.left.fill" : "person.fill")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                }.padding(.top, 5)
                VStack(spacing: 7) {
                    Text(call.title).font(.system(size: 27, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.7)
                    Text(call.remoteURI).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(call.connectedAt.map { CallRecord.formattedDuration(timeline.date.timeIntervalSince($0)) } ?? "— : —")
                            .font(.system(size: 26, weight: .light, design: .monospaced)).foregroundStyle(Theme.accent)
                    }.padding(.top, 5)
                }.multilineTextAlignment(.center)
                if call.isRinging {
                    Text(L("Caller ID was supplied by the SIP server."))
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    HStack(spacing: 13) {
                        Button { model.hangup() } label: { Label(L("Decline"), systemImage: "phone.down.fill") }
                            .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(call.isEnding)
                        Button { model.answer() } label: {
                            Label(model.acceptingCall ? L("Microphone…") : L("Answer"), systemImage: "phone.fill")
                        }.buttonStyle(ActionButtonStyle()).disabled(model.acceptingCall || call.isEnding)
                    }.padding(.top, 8)
                } else {
                    HStack(spacing: 22) {
                        control(call.muted ? L("Mic off") : L("Microphone"), symbol: call.muted ? "mic.slash.fill" : "mic.fill", selected: call.muted) { model.toggleMute() }
                            .disabled(!call.isConnected || call.isEnding)
                        control(call.isHeld ? L("Resume") : L("Hold"), symbol: call.isHeld ? "play.fill" : "pause.fill", selected: call.isHeld) { model.toggleHold() }
                            .disabled(!call.isConnected || call.isEnding || call.holdRequestedAt != nil)
                        control(L("Keypad"), symbol: "circle.grid.3x3.fill", selected: model.showingCallKeypad) { model.showingCallKeypad.toggle() }
                            .disabled(!call.isConnected || call.isEnding)
                    }.padding(.vertical, 8)
                    if model.showingCallKeypad {
                        Text(call.digits.isEmpty ? "DTMF" : call.digits).font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.muted)
                        DialPad { model.appendDigit($0) }.disabled(call.isHeld || call.isEnding)
                    }
                    Button { model.hangup() } label: { Label(L("End call"), systemImage: "phone.down.fill") }
                        .buttonStyle(ActionButtonStyle(color: Theme.danger)).disabled(call.isEnding)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 13)
        }
    }

    private func control(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 19)).frame(width: 55, height: 51)
                    .foregroundStyle(selected ? Theme.accent : Theme.ink)
                    .background(selected ? Theme.paleAccent : Theme.background, in: RoundedRectangle(cornerRadius: 15))
                Text(title).font(.system(size: 9)).foregroundStyle(Theme.muted)
            }
        }.buttonStyle(.plain)
    }
}

struct CallDetailsCard: View {
    let call: CallSession
    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("About the call")).font(.system(size: 12, weight: .semibold))
                if let stats = call.statistics {
                    row(L("Codec"), stats.codec)
                    row(L("Audio"), stats.secureMedia ? "SRTP" : L("RTP · unencrypted"))
                    row(L("RTP received"), "\(stats.rxPackets)")
                    row(L("RTP sent"), "\(stats.txPackets)")
                    row(L("Packet loss"), String(format: "%.1f %%", stats.lossPercent))
                    row("RTT", stats.rttMilliseconds > 0 ? String(format: L("%.0f ms"), stats.rttMilliseconds) : L("No RTCP"))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(call.muted ? L("Microphone muted") : L("Microphone level")).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ProgressView(value: stats.inputLevel).tint(Theme.accent)
                    }
                } else {
                    Text(L("Audio stream details will appear after connecting.")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.system(size: 10))
    }
}
