import Foundation

enum JSONFileStorage {
    static func load<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic replacement ensures the widget sees either the previous complete
        // document or the new complete document, never a partially-written file.
        try data.write(to: url, options: .atomic)
    }

    static func applicationSupportDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("usAIge", isDirectory: true)
    }
}
