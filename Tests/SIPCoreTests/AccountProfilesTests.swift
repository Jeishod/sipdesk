import Foundation
import Testing
@testable import SIPCore

struct AccountProfilesTests {
    private func account(_ name: String = "First") -> SIPAccount {
        SIPAccount(name: name, server: "pbx.example.com", username: "1001")
    }

    @Test func selectionRejectsBusyAndUnknownProfilesWithoutMutation() throws {
        let first = account()
        let second = account("Second")
        var profiles = AccountProfiles()
        try profiles.upsert(first)
        try profiles.upsert(second)
        for busy in [ProfileActivity.inCall, .preparingCall, .configuring, .shuttingDown] {
            #expect(throws: ConfigurationError.self) { try profiles.select(second.id, activity: busy) }
            #expect(profiles.activeAccount == first)
        }
        #expect(throws: ConfigurationError.self) { try profiles.select(UUID()) }
        try profiles.select(second.id)
        #expect(profiles.activeAccount == second)
        try profiles.remove(second.id)
        #expect(profiles.activeAccount == first)
        try profiles.remove(first.id)
        #expect(profiles.profiles.isEmpty)
        #expect(profiles.activeAccount == nil)
    }

    private func temporaryStore() throws -> LocalStore {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
        return try LocalStore(directory: root.appendingPathComponent("profile-tests-\(UUID().uuidString)"))
    }

    @Test func migratesLegacyWithoutChangingUUIDOrDeletingSource() throws {
        let files = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let legacy = account()
        try files.save(legacy, to: "account.json")
        let original = try Data(contentsOf: files.directory.appendingPathComponent("account.json"))
        let store = AccountProfileStore(files: files)
        let migrated = try store.load()
        #expect(migrated.profiles == [legacy])
        #expect(migrated.activeProfileID == legacy.id)
        #expect(try files.load(AccountProfiles.self, from: "profiles.json") == migrated)
        #expect(try Data(contentsOf: files.directory.appendingPathComponent("account.json")) == original)
        var empty = migrated
        try empty.remove(legacy.id)
        try store.save(empty)
        #expect(try store.load().profiles.isEmpty)
    }

    @Test func rejectsInvalidProfileDocumentsWithoutFallingBackToLegacy() throws {
        let files = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try files.save(account(), to: "account.json")
        let encoder = JSONEncoder()
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(account()))
        for document: [String: Any] in [
            ["profiles": [encoded, encoded], "activeProfileID": account().id.uuidString],
            ["profiles": [encoded], "activeProfileID": UUID().uuidString],
            ["profiles": [encoded]],
            ["profiles": [], "activeProfileID": UUID().uuidString]
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: document)
            let url = files.directory.appendingPathComponent("profiles.json")
            try bytes.write(to: url)
            #expect(throws: ConfigurationError.self) { try AccountProfileStore(files: files).load() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func saveInactiveProfileWithoutActivationPreservesCurrentLine() throws {
        let first = account()
        let second = account("Second")
        var profiles = AccountProfiles()
        try profiles.upsert(first)
        #expect(try profiles.save(second, activate: false) == false)
        #expect(profiles.activeAccount == first)
        #expect(try profiles.save(second, activate: true) == true)
        #expect(profiles.activeAccount == second)
        #expect(try profiles.save(second, activate: false) == true)
        let original = profiles
        var invalid = first
        invalid.server = ""
        #expect(throws: ConfigurationError.self) { try profiles.save(invalid, activate: true) }
        #expect(profiles == original)
    }

    @Test func roundTripPreservesSelectionAndPrivateFilePermissions() throws {
        let files = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var profiles = AccountProfiles()
        let first = account()
        let second = account("Second")
        try profiles.upsert(first)
        try profiles.upsert(second)
        try profiles.select(second.id)
        let store = AccountProfileStore(files: files)
        try store.save(profiles)
        #expect(try store.load() == profiles)
        let url = files.directory.appendingPathComponent("profiles.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(Set(document.keys) == ["profiles", "activeProfileID"])
        let encodedProfiles = document["profiles"] as! [[String: Any]]
        #expect(encodedProfiles.allSatisfy { !$0.keys.contains("password") })
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func failedMigrationLeavesLegacyUntouched() throws {
        let files = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try files.save(account(), to: "account.json")
        let legacyURL = files.directory.appendingPathComponent("account.json")
        let original = try Data(contentsOf: legacyURL)
        // Prevent creation of the migration destination, leaving legacy readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path) }
        #expect(throws: (any Error).self) { try AccountProfileStore(files: files).load() }
        #expect(try Data(contentsOf: legacyURL) == original)
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("profiles.json").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.directory.path)
        #expect(try AccountProfileStore(files: files).load().activeAccount?.id == files.load(SIPAccount.self, from: "account.json")?.id)
    }

    @Test func malformedLegacyIsNotReplacedWithEmptyProfiles() throws {
        let files = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let url = files.directory.appendingPathComponent("account.json")
        let bytes = Data("not json".utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try AccountProfileStore(files: files).load() }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("profiles.json").path))
    }

    @Test func upsertPreservesIdentityAndOtherProfiles() throws {
        let first = account()
        let second = account("Second")
        var profiles = AccountProfiles()
        try profiles.upsert(first)
        try profiles.upsert(second)
        var edited = first
        edited.name = "Edited"
        try profiles.upsert(edited)
        #expect(profiles.profiles == [edited, second])
        #expect(profiles.activeAccount?.id == first.id)
    }
}
