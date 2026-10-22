import SwiftUI
import SIPCore

struct AccountSheet: View {
    @EnvironmentObject private var model: SoftphoneModel
    @EnvironmentObject private var language: LanguageSettings
    @Environment(\.dismiss) private var dismiss
    @State var account: SIPAccount
    @State private var password = ""
    @State private var loadingPassword = true
    @State private var saving = false
    @State private var advanced = false
    @State private var connectAfterSaving = true
    @State private var error: String?
    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "network").font(.system(size: 23)).foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46).background(Theme.paleAccent, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("SIP account")).font(.system(size: 22, weight: .semibold))
                    Text(L("Connection details from your provider or PBX.")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(25)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    field(L("Line name")) { TextField(L("My SIP account"), text: $account.name) }
                    field(L("SIP server")) { TextField("sip.example.com", text: $account.server).environment(\.layoutDirection, .leftToRight) }
                    field(L("SIP username")) { TextField("1001", text: $account.username).environment(\.layoutDirection, .leftToRight) }
                    field(L("Password")) {
                        SecureField(loadingPassword ? L("Reading Keychain…") : L("SIP account password"), text: $password)
                            .privacySensitive().disabled(loadingPassword)
                    }
                    HStack(alignment: .center, spacing: 13) {
                        Text(L("Connection")).font(.system(size: 12, weight: .medium)).frame(width: 132, alignment: .leading)
                        Picker(L("Transport"), selection: $account.transport) {
                            ForEach(SIPTransport.allCases, id: \.self) { transport in Text(transport.title).tag(transport) }
                        }.labelsHidden().pickerStyle(.segmented)
                        TextField(L("Port"), value: $account.port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel(L("SIP server port"))
                    }
                    securityNote
                    DisclosureGroup(L("Advanced settings"), isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 17) {
                            field(L("Auth ID")) { TextField(L("Defaults to SIP username"), text: $account.authUsername).environment(\.layoutDirection, .leftToRight) }
                            field(L("Caller name")) { TextField(L("Optional"), text: $account.displayName) }
                            field(L("Outbound proxy")) { TextField("proxy.example.com:5060", text: $account.outboundProxy).environment(\.layoutDirection, .leftToRight) }
                            field(L("STUN server")) { TextField(L("Not used"), text: $account.stunServer).environment(\.layoutDirection, .leftToRight) }
                            field(L("Audio encryption")) {
                                Picker(L("Audio encryption"), selection: $account.mediaEncryption) {
                                    ForEach(MediaEncryption.allCases, id: \.self) { policy in Text(policy.title).tag(policy) }
                                }.labelsHidden()
                            }
                            field("DTMF") {
                                Picker("DTMF", selection: $account.dtmfMode) {
                                    ForEach(DTMFMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                                }.labelsHidden()
                            }
                            Toggle(L("Use ICE (if the PBX supports it)"), isOn: $account.useICE).font(.system(size: 12))
                            Text(L("Use only your own STUN server if required for NAT. Third-party STUN services are not used by default."))
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 17)
                    }.font(.system(size: 12, weight: .medium))
                    Divider()
                    Toggle(L("Connect when SIPDesk starts"), isOn: $account.connectOnLaunch).font(.system(size: 12))
                    Toggle(L("Connect after saving"), isOn: $connectAfterSaving).font(.system(size: 12))
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12))
                            .foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(25).disabled(saving)
            }
            Divider()
            HStack(spacing: 13) {
                if model.profiles.contains(where: { $0.id == account.id }) {
                    Button(L("Delete…"), role: .destructive) { confirmRemoval = true }.disabled(saving)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? L("Saving…") : L("Save")) { save() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(saving || loadingPassword || model.isPreview)
            }.padding(20)
        }
        .frame(width: 594, height: 690).foregroundStyle(Theme.ink).background(Theme.background)
        .environment(\.locale, language.locale)
        .environment(\.layoutDirection, language.direction)
        .interactiveDismissDisabled(saving)
        .onChange(of: account.transport) { oldValue, newValue in
            if account.port == oldValue.defaultPort { account.port = newValue.defaultPort }
        }
        .task {
            do {
                let stored = try await model.loadPassword(for: account)
                if password.isEmpty { password = stored }
            } catch { self.error = error.localizedDescription }
            loadingPassword = false
        }
        .onDisappear { password = "" }
        .confirmationDialog(L("Delete the SIP account and its Keychain password?"), isPresented: $confirmRemoval) {
            Button(L("Delete account"), role: .destructive) {
                saving = true
                Task {
                    do { try await model.removeAccount(profile: account); dismiss() }
                    catch { self.error = error.localizedDescription }
                    saving = false
                }
            }
        } message: { Text(L("Call history will remain on this Mac. You can clear it separately.")) }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Text(label).font(.system(size: 12, weight: .medium)).frame(width: 132, alignment: .leading)
            content().textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: .infinity)
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: account.transport == .tls ? "lock.shield" : "exclamationmark.shield")
            Text(account.transport == .tls
                 ? L("TLS verifies the SIP server certificate. To encrypt voice, select SRTP in advanced settings.")
                 : L("UDP and TCP do not encrypt SIP or voice. Use a trusted network/VPN or TLS + SRTP if the PBX supports them."))
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).foregroundStyle(account.transport == .tls ? Theme.accent : Theme.warning)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((account.transport == .tls ? Theme.accent : Theme.warning).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await model.saveAccount(account, password: password, connectAfterSaving: connectAfterSaving)
                password = ""
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

