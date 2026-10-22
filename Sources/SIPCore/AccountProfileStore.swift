import Foundation

/// The new file is authoritative, including an intentionally empty profile list.
/// Legacy data is retained as a recovery copy; migration never touches Keychain.
public struct AccountProfileStore: Sendable {
    private let files: LocalStore
    public init(files: LocalStore) { self.files = files }

    public func load() throws -> AccountProfiles {
        if let saved = try files.load(AccountProfiles.self, from: "profiles.json") { return saved }
        var migrated = AccountProfiles()
        if let legacy = try files.load(SIPAccount.self, from: "account.json") {
            try migrated.upsert(legacy)
            try save(migrated)
        }
        return migrated
    }

    public func save(_ profiles: AccountProfiles) throws {
        try files.save(profiles, to: "profiles.json")
    }
}
