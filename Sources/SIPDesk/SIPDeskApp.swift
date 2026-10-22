import AppKit
import Combine
import AVFoundation
import SwiftUI
import SIPCore

@main
enum SIPDeskApp {
    @MainActor static func main() {
        let preview = CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--preview")
        let args = CommandLine.arguments
        let languageIndex = args.firstIndex(of: "--preview-language")
        let previewLanguage = languageIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let language = LanguageSettings(preview: preview, previewLanguage: previewLanguage)
        let phone = SoftphoneModel(preview: preview)
        AppDelegate.sharedLanguage = language
        AppDelegate.sharedModel = phone
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime((phone, delegate, language)) { application.run() }
    }
}

@MainActor
final class TrayController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private let model: SoftphoneModel
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    init(model: SoftphoneModel, language: LanguageSettings) {
        self.model = model
        super.init()
        popover.contentSize = NSSize(width: 360, height: 580)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: LocalizedRoot(language: AppDelegate.sharedLanguage!, model: model))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateIcon()
        model.showMainWindow = { [weak self] in self?.show() }
        NotificationCenter.default.publisher(for: Localization.didChange).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &subscriptions)
        model.$call.combineLatest(model.$connection).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &subscriptions)
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show() {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissFromOutsideClick() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.item.button?.window,
               !self.model.showingAccount { self.close() }
            return event
        }
    }

    func dismissFromOutsideClick() {
        guard !model.showingAccount else { return }
        popover.contentViewController?.view.window?.endEditing(for: nil)
        close()
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    func close() { popover.close() }
    var isShown: Bool { popover.isShown }
    var contentView: NSView? { popover.contentViewController?.view }

    private func updateIcon() {
        let symbol = model.call?.isRinging == true ? "phone.arrow.down.left.fill" : model.call == nil ? "phone" : "phone.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SIPDesk")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "SIPDesk · \(model.call?.status ?? model.connection.title)"
        item.button?.setAccessibilityLabel("SIPDesk: \(model.call?.status ?? model.connection.title)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedModel: SoftphoneModel?
    static var sharedLanguage: LanguageSettings?
    private var languageSubscription: AnyCancellable?
    weak var model: SoftphoneModel?
    private var tray: TrayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Self.sharedModel
        guard let model else { return }
        tray = TrayController(model: model, language: Self.sharedLanguage!)
        languageSubscription = NotificationCenter.default.publisher(for: Localization.didChange).sink { [weak self] _ in
            Task { @MainActor in self?.buildEditMenu() }
        }
        buildEditMenu()
        if CommandLine.arguments.contains("--render-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.renderPreview(using: model) }
        }
    }

    private func buildEditMenu() {
        // AppKit responder-chain shortcuts need an Edit menu in an accessory app.
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            let item = NSMenuItem(title: L(title), action: NSSelectorFromString(selector), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.handleURL(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder/LaunchServices may send a reopen event during first launch.
        // Keep all launches tray-only; the status icon explicitly opens the popover.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func renderPreview(using model: SoftphoneModel) {
        guard let argument = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(argument + 1) else { return }
        if CommandLine.arguments.contains("--verify-i18n") {
            verifyLocalization(using: model)
        }
        if CommandLine.arguments.contains("--preview-history") { model.section = .history }
        if CommandLine.arguments.contains("--preview-account") { model.showingAccount = true }
        if CommandLine.arguments.contains("--verify-tray-ui") {
            model.showMainWindow?()
            guard tray?.isShown == true else { fputs("Tray did not open.\n", stderr); exit(1) }
            tray?.close()
            model.handleURL(URL(string: "tel:1002")!)
            guard tray?.isShown == true, model.dialTarget == "tel:1002", model.call == nil else { exit(1) }
            tray?.close()
            model.dialTarget = ""
            print("Tray lifecycle verified")
        }
        if CommandLine.arguments.contains("--verify-presence") {
            model.engineReady = true
            model.connection = .online
            model.selectPresence(.busy)
            guard model.doNotDisturb, model.presence == .busy, model.isOnline else { exit(1) }
            model.selectPresence(.available)
            guard !model.doNotDisturb, model.presence == .available else { exit(1) }
            model.connection = .connecting
            model.selectPresence(.busy)
            guard model.doNotDisturb, model.connection == .connecting else { exit(1) }
            model.configurationBusy = true
            model.selectPresence(.available)
            guard model.doNotDisturb else { exit(1) }
            model.configurationBusy = false
            model.connection = .offline
            guard model.presence == .offline else { exit(1) }
            model.account = nil
            model.selectPresence(.available)
            guard model.showingAccount, model.connection == .offline else { exit(1) }
            model.showingAccount = false
            print("Presence selection verified")
        }
        if CommandLine.arguments.contains("--verify-hit-targets") || CommandLine.arguments.contains("--verify-dial-focus") {
            guard NSApp.activationPolicy() == .accessory else { fputs("Not accessory.\n", stderr); exit(1) }
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) else { for w in NSApp.windows where w.isVisible { print("Visible:", w.className, w.title) }; fputs("Unexpected visible window at launch.\n", stderr); exit(1) }
            model.engineReady = true
            model.notice = nil
            tray?.show()
            guard let root = tray?.contentView else { exit(1) }
            root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            root.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(root).compactMap { $0 as? FullHitButton }
            if CommandLine.arguments.contains("--verify-hit-targets") {
                for id in ["presenceMenu", "tab-dialer", "tab-history", "tab-audio"] {
                    guard let button = buttons.first(where: { $0.identifier?.rawValue == id }),
                          let parent = button.superview, button.bounds.height >= 34,
                          button.bounds.width >= 70, button.focusRingType == .none, !button.isBordered else {
                        fputs("Missing or undersized target: \(id)\n", stderr); exit(1)
                    }
                    for corner in [NSPoint(x: 2, y: 2), NSPoint(x: button.bounds.maxX - 2, y: button.bounds.maxY - 2)] {
                        guard button.hitTest(button.convert(corner, to: parent)) === button else { exit(1) }
                    }
                }
                guard let history = buttons.first(where: { $0.identifier?.rawValue == "tab-history" }) else { exit(1) }
                history.performClick(nil)
                guard model.section == .history else { exit(1) }
                model.section = .dialer
                print("Full hit targets and tray-only launch verified")
            }
            if CommandLine.arguments.contains("--verify-dial-focus") {
                guard let digit = buttons.first(where: { $0.identifier?.rawValue == "digit-2" }) else { print("Buttons:", buttons.map { $0.identifier?.rawValue ?? "?" }); exit(1) }
                digit.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let editor = root.window?.firstResponder as? NSTextView,
                          model.dialTarget == "2" else { fputs("Digit did not focus field.\n", stderr); exit(1) }
                    editor.insertText("3", replacementRange: editor.selectedRange())
                    editor.deleteBackward(nil)
                    guard editor.string == "2" else { print("Keyboard result:", editor.string, "selection:", editor.selectedRange()); exit(1) }
                    print("Digit click keyboard focus verified")
                    self.tray?.close()
                    let args = CommandLine.arguments
                    // Finish by rendering the same live content after exercising keyboard editing.
                    let host = NSHostingView(rootView: LocalizedRoot(language: AppDelegate.sharedLanguage!, model: model).frame(width: 360, height: 580))
                    host.frame = NSRect(x: 0, y: 0, width: 360, height: 580)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                    try! data.write(to: URL(fileURLWithPath: args[argument + 1]))
                    exit(0)
                }
                return
            }
            tray?.close()
        }
        if CommandLine.arguments.contains("--verify-call-layout") {
            model.notice = nil
            model.engineReady = true
            model.call = CallSession(previewAccountID: model.account!.id)
            model.showingCallKeypad = true
            tray?.show()
            guard let root = tray?.contentView else { exit(1) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            root.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let buttons = descendants(root).compactMap { $0 as? FullHitButton }
            for id in ["presenceMenu", "tab-dialer", "tab-history", "tab-audio", "digit-1", "digit-#"] {
                guard let button = buttons.first(where: { $0.identifier?.rawValue == id }) else { print("Missing", id); exit(1) }
                let rect = button.convert(button.bounds, to: root)
                guard root.bounds.contains(rect) else { print("Clipped", id, rect, root.bounds); exit(1) }
            }
            guard root.bounds.height == 580 else { exit(1) }
            print("Call keypad layout verified")
            tray?.close()
        }
        if CommandLine.arguments.contains("--verify-colleague-input") {
            model.engineReady = true
            model.notice = nil
            tray?.show()
            guard let root = tray?.contentView else { exit(1) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
            guard let zero = descendants(root).compactMap({ $0 as? FullHitButton }).first(where: { $0.identifier?.rawValue == "digit-0" }),
                  let hold = zero.longPressAction else { exit(1) }
            hold()
            guard model.dialTarget == "+" else { exit(1) }
            model.dialTarget = ""
            zero.performClick(nil)
            guard model.dialTarget == "0" else { print("Short zero:", model.dialTarget); exit(1) }
            guard let paste = NSApp.mainMenu?.items.first(where: { $0.title == L("Edit") })?.submenu?.items.first(where: { $0.keyEquivalent == "v" }),
                  paste.action == NSSelectorFromString("paste:"), paste.keyEquivalentModifierMask == .command else { exit(1) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            tray?.dismissFromOutsideClick()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard tray?.contentView?.window?.isVisible != true else { fputs("Outside dismiss failed.\n", stderr); exit(1) }
            print("Colleague interactions verified")
        }
        if CommandLine.arguments.contains("--verify-permissions") {
            model.engineReady = true
            model.connection = .online
            model.dialTarget = "1002"
            for status in [AVAuthorizationStatus.notDetermined, .denied, .restricted] {
                model.microphonePermission = status
                guard !model.canCall else { exit(1) }
                model.makeCall()
                model.answer()
                guard model.call == nil, !model.preparingCall, !model.acceptingCall,
                      !model.requestingMicrophone, model.section == .audio else { exit(1) }
            }
            model.microphonePermission = .authorized
            guard model.canCall, model.checkMicrophoneBeforeCall() else { exit(1) }
            model.notice = nil
            print("Microphone preflight verified")
        }
        if CommandLine.arguments.contains("--verify-status-colors") {
            let menu = PresenceMenu(model: model)
            guard menu.items.count == 3 else { exit(1) }
            var colors: [NSColor] = []
            for item in menu.items {
                guard let image = item.image, !image.isTemplate,
                      let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!),
                      let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { exit(1) }
                colors.append(color)
            }
            guard colors[0].greenComponent > colors[0].redComponent,
                  colors[1].redComponent > colors[1].blueComponent,
                  abs(colors[2].redComponent - colors[2].blueComponent) < 0.1,
                  menu.items.filter({ $0.state == .on }).count == 1 else { exit(1) }
            print("Status colors verified")
        }
        if CommandLine.arguments.contains("--preview-settings") { model.section = .audio }
        let output = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
        let host = NSHostingView(rootView: LocalizedRoot(language: AppDelegate.sharedLanguage!, model: model).frame(width: 360, height: 580))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 580)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: output); print("Preview: \(output.path)"); exit(0) }
        catch { fputs("Could not write preview.\n", stderr); exit(1) }
    }

    private func verifyLocalization(using model: SoftphoneModel) {
        guard let language = Self.sharedLanguage else { exit(1) }
        let original = language.selection
        let initial = language.resolved
        let catalog = try! Localization.catalog(initial)
        guard catalog.count >= 200, L("Call") == catalog["Call"] else { exit(1) }
        model.engineReady = true
        model.connection = .online
        model.notice = L("End the current call first.")
        model.dialTarget = "+351123456789"
        model.call = CallSession(previewAccountID: model.account!.id)
        let token = model.call!.id
        model.showingCallKeypad = true
        try! language.select(.ar)
        guard language.direction == .rightToLeft, model.call?.id == token, model.connection == .online else { exit(1) }
        try! language.select(.en)
        guard language.direction == .leftToRight, L("Call") == "Call", model.call?.id == token else { exit(1) }
        try! language.select(original)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard model.notice == L("End the current call first."), model.dialTarget == "+351123456789" else { exit(1) }
        model.notice = nil
        tray?.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let root = tray?.contentView else { exit(1) }
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(root).compactMap { $0 as? FullHitButton }
        guard let one = buttons.first(where: { $0.identifier?.rawValue == "digit-1" }),
              let three = buttons.first(where: { $0.identifier?.rawValue == "digit-3" }),
              one.convert(one.bounds, to: root).midX < three.convert(three.bounds, to: root).midX else { fputs("Telephone keypad reversed.\n", stderr); exit(1) }
        for id in ["presenceMenu", "tab-dialer", "tab-history", "tab-audio", "digit-1", "digit-#"] {
            guard let button = buttons.first(where: { $0.identifier?.rawValue == id }), root.bounds.contains(button.convert(button.bounds, to: root)) else { print("Localized control clipped", id); exit(1) }
        }
        guard let dial = buttons.first(where: { $0.identifier?.rawValue == "tab-dialer" }),
              let settings = buttons.first(where: { $0.identifier?.rawValue == "tab-audio" }) else { exit(1) }
        let mirrored = dial.convert(dial.bounds, to: root).midX > settings.convert(settings.bounds, to: root).midX
        guard mirrored == initial.isRightToLeft else { fputs("Main layout direction incorrect.\n", stderr); exit(1) }
        guard NSApp.mainMenu?.items.first?.title == L("Edit") else { exit(1) }
        tray?.close()
        model.call = nil
        model.showingCallKeypad = false
        model.section = .audio
        tray?.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        root.layoutSubtreeIfNeeded()
        let settingsControls = descendants(root).compactMap { $0 as? NSControl }
        guard !settingsControls.isEmpty else { exit(1) }
        for control in settingsControls where !control.isHidden {
            let rect = control.convert(control.bounds, to: root)
            guard root.bounds.contains(rect) else { print("Settings control clipped", control.className, rect); exit(1) }
        }
        tray?.close()
        print("Localization verified: \(initial.rawValue)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.call != nil {
            let alert = NSAlert()
            alert.messageText = L("End the call and quit?")
            alert.informativeText = L("SIPDesk cannot receive incoming calls after quitting.")
            alert.addButton(withTitle: L("End call and quit"))
            alert.addButton(withTitle: L("Stay"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model.shutdown {
            Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
