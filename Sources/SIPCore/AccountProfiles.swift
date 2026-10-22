import Foundation

public enum ProfileActivity: Sendable {
    case idle, inCall, preparingCall, configuring, shuttingDown

    public func requireIdle() throws {
        guard self == .idle else { throw ConfigurationError(L("End the call or finish configuring the line first.")) }
    }
}

/// Password-free connection profiles; exactly one saved profile is selected when nonempty.
public struct AccountProfiles: Codable, Equatable, Sendable {
    public private(set) var profiles: [SIPAccount] = []
    public private(set) var activeProfileID: UUID?

    public init() {}

    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decode([SIPAccount].self, forKey: .profiles).map { try $0.validated() }
        activeProfileID = try values.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        guard Set(profiles.map(\.id)).count == profiles.count,
              profiles.isEmpty ? activeProfileID == nil : profiles.contains(where: { $0.id == activeProfileID }) else {
            throw ConfigurationError(L("The SIP profile list is damaged. The original file was left unchanged."))
        }
    }

    public var activeAccount: SIPAccount? { profiles.first { $0.id == activeProfileID } }

    public mutating func select(_ id: UUID, activity: ProfileActivity = .idle) throws {
        try activity.requireIdle()
        guard profiles.contains(where: { $0.id == id }) else { throw ConfigurationError(L("SIP profile not found.")) }
        activeProfileID = id
    }

    public mutating func remove(_ id: UUID, activity: ProfileActivity = .idle) throws {
        try activity.requireIdle()
        guard profiles.contains(where: { $0.id == id }) else { throw ConfigurationError(L("SIP profile not found.")) }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = profiles.first?.id }
    }

    /// Returns whether saving requires disconnecting the current engine account.
    @discardableResult
    public mutating func save(_ proposed: SIPAccount, activate: Bool, activity: ProfileActivity = .idle) throws -> Bool {
        try activity.requireIdle()
        let affectsActive = activeAccount == nil || activeProfileID == proposed.id || activate
        try upsert(proposed)
        if affectsActive { try select(proposed.id) }
        return affectsActive
    }

    public mutating func upsert(_ proposed: SIPAccount) throws {
        let account = try proposed.validated()
        if let index = profiles.firstIndex(where: { $0.id == account.id }) { profiles[index] = account }
        else { profiles.append(account) }
        if activeProfileID == nil { activeProfileID = account.id }
    }
}
