import Foundation

/// Deliberately separate from profiles, audio and Keychain; can load before model boot.
public struct LanguagePreferenceStore: Sendable {
    private struct Preference: Codable, Sendable { let language: String }
    private let files: LocalStore
    public init(files: LocalStore) { self.files = files }
    public func load() throws -> AppLanguage {
        guard let saved = try files.load(Preference.self, from: "language.json") else { return .system }
        return AppLanguage(rawValue: saved.language) ?? .system
    }
    public func save(_ language: AppLanguage) throws {
        try files.save(Preference(language: language.rawValue), to: "language.json")
    }
}
