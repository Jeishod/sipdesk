import SwiftUI

enum Theme {
    static let ink = Color(hex: 0xECEEF0)
    static let muted = Color(hex: 0x899198)
    static let accent = Color(hex: 0x7BD7AE)
    static let paleAccent = Color(hex: 0x19382E)
    static let background = Color(hex: 0x141719)
    static let border = Color(hex: 0x303639)
    static let sidebar = Color(hex: 0x202527)
    static let sidebarText = Color(hex: 0xA7B1B4)
    static let danger = Color(hex: 0xEA7E7E)
    static let warning = Color(hex: 0xD9AF76)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }
}

struct ActionButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? Color(hex: 0x102019) : Theme.muted)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.8 : 1) : Theme.border,
                        in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct ConnectionBadge: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .online: Theme.accent
        case .connecting: Theme.warning
        case .failed: Theme.danger
        case .offline: Theme.muted
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 8)
        .background(color.opacity(0.075), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(Theme.muted)
                .frame(width: 56, height: 56).background(Theme.background, in: RoundedRectangle(cornerRadius: 17))
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 15)
    }
}

