import AppKit
import SIPCore

@MainActor
final class PresenceMenu: NSMenu {
    private let model: SoftphoneModel
    init(model: SoftphoneModel) {
        self.model = model
        super.init(title: L("Status"))
        autoenablesItems = false
        for (index, status) in SoftphoneModel.Presence.allCases.enumerated() {
            let item = NSMenuItem(title: status.title, action: #selector(select(_:)), keyEquivalent: "")
            let color: NSColor
            switch status {
            case .available: color = NSColor(srgbRed: 0.48, green: 0.84, blue: 0.68, alpha: 1)
            case .busy: color = NSColor(srgbRed: 0.85, green: 0.69, blue: 0.46, alpha: 1)
            case .offline: color = NSColor(srgbRed: 0.54, green: 0.57, blue: 0.60, alpha: 1)
            }
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
                return true
            }
            dot.isTemplate = false
            item.image = dot
            item.target = self
            item.tag = index
            item.state = model.presence == status ? .on : .off
            item.isEnabled = status != .offline || model.canConfigure
            addItem(item)
        }
    }
    required init(coder: NSCoder) { fatalError("Not used") }
    @objc private func select(_ item: NSMenuItem) {
        model.selectPresence(SoftphoneModel.Presence.allCases[item.tag])
    }
}
