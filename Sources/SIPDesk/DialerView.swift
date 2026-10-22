import SwiftUI
import SIPCore

struct DialerView: View {
    @EnvironmentObject private var model: SoftphoneModel
    @FocusState private var targetFocused: Bool

    var body: some View {
        Card(padding: 28) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "phone.arrow.up.right").font(.system(size: 12, weight: .medium))
                    Text(L("NEW CALL")).font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    Spacer()
                }.foregroundStyle(Theme.muted)
                VStack(spacing: 10) {
                    if model.isPreview {
                        Text(model.dialTarget.isEmpty ? L("Number or SIP address") : model.dialTarget)
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(model.dialTarget.isEmpty ? Theme.muted : Theme.ink)
                    } else {
                        TextField(L("Number or SIP address"), text: $model.dialTarget)
                        .textFieldStyle(.plain).font(.system(size: model.dialTarget.count > 16 ? 19 : 26, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center).focused($targetFocused)
                        .onSubmit { model.makeCall() }.disabled(model.preparingCall)
                        .accessibilityIdentifier("dialTarget")
                    }
                    HStack(spacing: 4) {
                        Text(model.dialTarget.isEmpty ? L("For example, 1002 or user@domain.com") : L("Via {0}", String(model.account?.server ?? L("Your SIP server"))))
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                        if !model.dialTarget.isEmpty {
                            Button { model.dialTarget.removeLast() } label: { Image(systemName: "delete.left").font(.system(size: 12)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted).disabled(model.preparingCall).help(L("Delete last character"))
                        }
                    }
                }.frame(height: 99).padding(.top, 15).padding(.bottom, 13)
                DialPad { model.appendDigit($0) }.disabled(model.preparingCall)
                Group {
                    if model.preparingCall {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L("Preparing call…")).font(.system(size: 12))
                            Spacer()
                            Button(L("Cancel")) { model.cancelPreparation() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        }.frame(height: 46)
                    } else if model.account == nil {
                        Button { model.showingAccount = true } label: { Label(L("Connect a SIP account"), systemImage: "plus") }
                            .buttonStyle(ActionButtonStyle()).disabled(!model.canConfigure)
                    } else {
                        Button { model.makeCall() } label: { Label(L("Call"), systemImage: "phone.fill") }
                            .buttonStyle(ActionButtonStyle()).disabled(!model.canCall)
                            .accessibilityIdentifier("callButton")
                    }
                }.padding(.top, 22)
                Text(model.isOnline ? L("Enter — call") : L("Connect to the SIP server to make calls"))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 12)
            }
        }
    }
}

struct DialPad: View {
    @Environment(\.isEnabled) private var enabled
    let action: (String) -> Void
    var compact = false
    private let keys = [("1", ""), ("2", "ABC"), ("3", "DEF"), ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
                        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"), ("*", ""), ("0", "+"), ("#", "")]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 8 : 11), count: 3), spacing: compact ? 5 : 10) {
            ForEach(keys, id: \.0) { digit, letters in
                FullAreaButton(identifier: "digit-\(digit)", enabled: enabled, action: { _ in action(digit) }, longPressAction: digit == "0" ? { action("+") } : nil) {
                    VStack(spacing: 2) {
                        Text(digit).font(.system(size: compact ? 22 : 26, weight: .regular, design: .rounded))
                        Text(letters.isEmpty ? " " : letters).font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity).frame(height: compact ? 45 : 57).contentShape(RoundedRectangle(cornerRadius: 8))
                }.frame(height: compact ? 45 : 57).accessibilityLabel("\(digit) \(letters)")
                    .contextMenu { if digit == "0" { Button(L("Insert +")) { action("+") } } }
            }
        }.environment(\.layoutDirection, .leftToRight)
    }
}

private struct DialKeyStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.4))
            .background(configuration.isPressed ? Theme.paleAccent : Theme.background, in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

