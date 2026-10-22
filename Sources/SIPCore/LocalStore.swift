import Foundation

public struct LocalStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIPDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }

    public func load<Value: Decodable & Sendable>(_ type: Value.Type, from filename: String) throws -> Value? {
        let location = try fileURL(filename)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: location))
    }

    public func save<Value: Encodable & Sendable>(_ value: Value, to filename: String) throws {
        let location = try fileURL(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError(L("Could not create the settings file."))
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let result = temporary.path.withCString { source in
            location.path.withCString { destination in rename(source, destination) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func delete(_ filename: String) throws {
        let location = try fileURL(filename)
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
    }

    private func fileURL(_ filename: String) throws -> URL {
        guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else {
            throw ConfigurationError(L("Invalid settings file name."))
        }
        return directory.appendingPathComponent(filename)
    }
}
