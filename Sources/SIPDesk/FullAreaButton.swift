import AppKit
import SwiftUI

/// One native hit target covers the whole SwiftUI label, including empty padding.
struct FullAreaButton<Label: View>: NSViewRepresentable {
    @Environment(\.layoutDirection) private var direction
    @Environment(\.locale) private var locale
    let identifier: String
    let enabled: Bool
    let action: (NSButton) -> Void
    var longPressAction: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label

    func makeNSView(context: Context) -> FullHitButton {
        let button = FullHitButton()
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.title = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.invoke(_:))
        let host = NSHostingView(rootView: AnyView(label().environment(\.layoutDirection, direction).environment(\.locale, locale)))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        button.isEnabled = enabled
        button.longPressAction = longPressAction
        return button
    }

    func updateNSView(_ button: FullHitButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = enabled
        button.longPressAction = longPressAction
        (button.subviews.first as? NSHostingView<AnyView>)?.rootView = AnyView(label().environment(\.layoutDirection, direction).environment(\.locale, locale))
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    final class Coordinator: NSObject {
        var action: (NSButton) -> Void
        init(action: @escaping (NSButton) -> Void) { self.action = action }
        @objc func invoke(_ button: NSButton) { action(button) }
    }
}

final class FullHitButton: NSButton {
    var longPressAction: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let longPressAction else { super.mouseDown(with: event); return }
        let deadline = Date().addingTimeInterval(0.5)
        var held = false
        while true {
            if let next = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: held ? .distantFuture : deadline, inMode: .eventTracking, dequeue: true) {
                if next.type == .leftMouseUp {
                    if !held && bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                    return
                }
            } else {
                held = true
                longPressAction()
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let parent = superview else { return nil }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }
}
