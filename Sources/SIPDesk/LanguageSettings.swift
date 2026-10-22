import Foundation
import Combine
import SwiftUI
import SIPCore

/// Independent UI preference: switching never touches the worker or call state.
@MainActor
final class LanguageSettings: ObservableObject {
    @Published private(set) var selection: AppLanguage
    @Published private(set) var resolved: AppLanguage
    @Published private(set) var revision = 0
    private let store: LanguagePreferenceStore?
    private let isPreview: Bool
    private var observer: NSObjectProtocol?

    init(preview: Bool = false, preferredLanguages: [String] = Locale.preferredLanguages, previewLanguage: String? = nil) {
        isPreview = preview
        store = preview ? nil : (try? LanguagePreferenceStore(files: LocalStore()))
        let initial = preview ? (AppLanguage(rawValue: previewLanguage ?? "system") ?? .system) : ((try? store?.load()) ?? .system)
        selection = initial
        resolved = AppLanguage.resolve(selection: initial, preferredLanguages: preferredLanguages)
        Localization.setLanguage(resolved)
        observer = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemLanguage() }
        }
    }
    func select(_ language: AppLanguage) throws {
        if let store { try store.save(language) }
        else if !isPreview { throw CocoaError(.fileWriteUnknown) }
        selection = language
        refreshSystemLanguage()
    }
    func refreshSystemLanguage() {
        resolved = AppLanguage.resolve(selection: selection)
        Localization.setLanguage(resolved)
        revision += 1
    }
    var direction: LayoutDirection { resolved.isRightToLeft ? .rightToLeft : .leftToRight }
    var locale: Locale { Localization.locale }
}

struct LocalizedRoot: View {
    @ObservedObject var language: LanguageSettings
    let model: SoftphoneModel
    var body: some View {
        ContentView().environmentObject(model).environmentObject(language)
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.direction)
    }
}
