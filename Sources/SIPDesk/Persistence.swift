import Foundation
import Security
import SIPCore

actor Persistence {
    struct Snapshot: Sendable {
        let profiles: AccountProfiles
        var account: SIPAccount? { profiles.activeAccount }
        let audio: AudioPreferences
        let history: [CallRecord]
    }

    private let files: LocalStore
    private let profileStore: AccountProfileStore
    private let credentials = KeychainCredentials()
    private var loaded = false

    init() throws {
        let files = try LocalStore()
        self.files = files
        profileStore = AccountProfileStore(files: files)
    }

    func load() throws -> Snapshot {
        loaded = false
        let snapshot = try Snapshot(
            profiles: profileStore.load(),
            audio: files.load(AudioPreferences.self, from: "audio.json") ?? AudioPreferences(),
            history: Array((files.load([CallRecord].self, from: "history.json") ?? []).prefix(200))
        )
        loaded = true
        return snapshot
    }

    private func requireLoaded() throws {
        guard loaded else { throw ConfigurationError(L("Settings have not loaded. The original files will not be overwritten.")) }
    }

    func password(for account: SIPAccount) throws -> String? { try credentials.read(id: account.id) }

    func save(account: SIPAccount, password: String, profiles: AccountProfiles) throws {
        try requireLoaded()
        guard profiles.profiles.contains(account) else { throw ConfigurationError(L("SIP profile not found.")) }
        guard !password.isEmpty, password.utf8.count <= 1024, !password.contains("\0") else {
            throw ConfigurationError(L("Enter a password (up to 1024 bytes, without NUL). It will be stored in macOS Keychain."))
        }
        let previous = try credentials.read(id: account.id)
        try credentials.write(password, id: account.id)
        do { try profileStore.save(profiles) }
        catch {
            if let previous { try? credentials.write(previous, id: account.id) }
            else { try? credentials.remove(id: account.id) }
            throw error
        }
    }

    func save(profiles: AccountProfiles) throws {
        try requireLoaded()
        try profileStore.save(profiles)
    }

    func remove(account: SIPAccount, profiles: AccountProfiles) throws {
        try requireLoaded()
        guard !profiles.profiles.contains(where: { $0.id == account.id }) else {
            throw ConfigurationError(L("The SIP profile is still in use."))
        }
        let previous = try credentials.read(id: account.id)
        try credentials.remove(id: account.id)
        do { try profileStore.save(profiles) }
        catch {
            if let previous { try? credentials.write(previous, id: account.id) }
            throw error
        }
    }

    func save(audio: AudioPreferences) throws { try files.save(audio, to: "audio.json") }
    func save(history: [CallRecord]) throws { try files.save(Array(history.prefix(200)), to: "history.json") }
}

private struct KeychainCredentials: Sendable {
    // Predates the io.github.jeishod.sipdesk bundle ID; kept so saved passwords still resolve.
    private let service = "local.sipdesk.accounts"

    func read(id: UUID) throws -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ConfigurationError(L("Could not read the password from Keychain."))
        }
        return password
    }

    func write(_ password: String, id: UUID) throws {
        let query = baseQuery(id: id)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrLabel as String] = "SIPDesk · SIP password"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove(id: UUID) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func baseQuery(id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ConfigurationError("Keychain: \(detail)")
        }
    }
}

