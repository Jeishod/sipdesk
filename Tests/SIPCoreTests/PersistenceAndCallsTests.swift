import Foundation
import Testing
@testable import SIPCore

@Test func accountRoundTripContainsNoPassword() throws {
    let account = SIPAccount(server: "pbx.example.com", username: "1001", authUsername: "auth1001")
    let encoded = try JSONEncoder().encode(account)
    #expect(!String(decoding: encoded, as: UTF8.self).lowercased().contains("password"))
    #expect(try JSONDecoder().decode(SIPAccount.self, from: encoded) == account)
}

@Test func atomicLocalStorageUsesPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SIPDeskTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalStore(directory: directory)
    #expect(try store.load(SIPAccount.self, from: "account.json") == nil)
    let account = SIPAccount(server: "pbx.example.com", username: "1001")
    try store.save(account, to: "account.json")
    #expect(try store.load(SIPAccount.self, from: "account.json") == account)
    try store.save(account, to: "account.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("account.json").path)[.posixPermissions] as? NSNumber
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(directoryPermissions?.intValue == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["account.json"])
    #expect(throws: ConfigurationError.self) { try store.save(account, to: "../escape.json") }
    try store.delete("account.json")
    #expect(try store.load(SIPAccount.self, from: "account.json") == nil)
}

@Test func corruptDataIsReportedWithoutDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SIPDeskTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LocalStore(directory: directory)
    let location = directory.appendingPathComponent("account.json")
    let corrupted = Data("{broken".utf8)
    try corrupted.write(to: location)
    #expect(throws: (any Error).self) { try store.load(SIPAccount.self, from: "account.json") }
    #expect(try Data(contentsOf: location) == corrupted)
}

@Test func tracksAnsweredMissedAndDeclinedCallsSeparately() {
    #expect(CallRecord.outcome(direction: .incoming, connected: false, localDecline: false, localHangup: false, statusCode: 487) == .missed)
    #expect(CallRecord.outcome(direction: .incoming, connected: false, localDecline: true, localHangup: true, statusCode: 603) == .declined)
    #expect(CallRecord.outcome(direction: .outgoing, connected: false, localDecline: false, localHangup: true, statusCode: 487) == .cancelled)
    #expect(CallRecord.outcome(direction: .outgoing, connected: false, localDecline: false, localHangup: false, statusCode: 486) == .failed)
    #expect(CallRecord.outcome(direction: .incoming, connected: true, localDecline: false, localHangup: true, statusCode: 200) == .answered)
}

@Test func callDurationsNeverGoNegative() {
    let now = Date()
    let record = CallRecord(accountID: UUID(), remoteURI: "sip:1002@example.com", direction: .incoming,
                            startedAt: now, connectedAt: now, endedAt: now.addingTimeInterval(-1), outcome: .answered)
    #expect(record.duration == 0)
    #expect(CallRecord.formattedDuration(-1) == "00:00")
    #expect(CallRecord.formattedDuration(65) == "01:05")
    #expect(CallRecord.formattedDuration(3661) == "1:01:01")
}

@Test func sipErrorsHaveActionableMessages() {
    #expect(SIPStatus.explanation(code: 403, fallback: "Forbidden") == L("The server denied the connection. Check the account and IP restrictions."))
    #expect(SIPStatus.explanation(code: 408, fallback: "Timeout").contains("VPN"))
    #expect(SIPStatus.explanation(code: 488, fallback: "Not acceptable").contains("SRTP"))
}
