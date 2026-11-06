import Foundation

/// The only persisted data are user-authored rules/profile names and a switch.
/// No event stream, application identity, typed characters, or capture history.
struct RemapStore {
    let url: URL
    private let legacyURL: URL?
    static let maximumBytes = 2 * 1_024 * 1_024
    init(url: URL? = nil, legacyURL: URL? = nil) {
        if let url {
            self.url = url
            self.legacyURL = legacyURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KeyDance", isDirectory: true)
            self.url = directory.appendingPathComponent("remapping-v2.json")
            self.legacyURL = directory.appendingPathComponent("remapping.json")
        }
    }
    func load() throws -> RemapConfiguration? {
        if FileManager.default.fileExists(atPath: url.path) { return try Self.read(from: url) }
        guard let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        // Read the previous rules on first use and leave the 3.0 file available
        // for downgrade. Only explicit edits write the new configuration.
        return try Self.read(from: legacyURL)
    }
    func save(_ configuration: RemapConfiguration) throws {
        try Self.write(configuration, to: url)
    }
    static func read(from url: URL) throws -> RemapConfiguration {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw RemapError.invalidConfiguration("请选择普通 JSON 配置文件。") }
        if let size = values.fileSize, size > maximumBytes { throw RemapError.fileTooLarge }
        // Bound the read itself as well, including a file that grows after stat.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RemapError.fileTooLarge }
        var configuration = try JSONDecoder().decode(RemapConfiguration.self, from: data)
        if configuration.version == 1 { configuration.version = RemapConfiguration.schemaVersion }
        try RemapValidation.validate(configuration)
        return configuration
    }
    static func write(_ configuration: RemapConfiguration, to url: URL) throws {
        try RemapValidation.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= maximumBytes else { throw RemapError.fileTooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
