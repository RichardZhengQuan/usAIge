import Foundation

public struct WatchQuotaWindowSnapshot: Codable, Hashable, Sendable {
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetAt: Date?
    public let windowDurationSeconds: Int?

    public init(remainingPercent: Double, resetAt: Date?, windowDurationSeconds: Int?) {
        let finite = remainingPercent.isFinite ? remainingPercent : 0
        let clamped = min(100, max(0, finite))
        self.usedPercent = 100 - clamped
        self.remainingPercent = clamped
        self.resetAt = resetAt
        self.windowDurationSeconds = windowDurationSeconds
    }
}

public struct WatchQuotaSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let primary: WatchQuotaWindowSnapshot
    public let secondary: WatchQuotaWindowSnapshot?
    public let planType: String?

    public init(
        id: String,
        displayName: String,
        primary: WatchQuotaWindowSnapshot,
        secondary: WatchQuotaWindowSnapshot? = nil,
        planType: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

public struct WatchToolQuotaSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let sourceUpdatedAt: Date
    public let receivedAt: Date
    public let limits: [WatchQuotaSnapshot]
    public let symbolName: String?

    public init(
        id: String,
        displayName: String,
        sourceUpdatedAt: Date,
        receivedAt: Date,
        limits: [WatchQuotaSnapshot],
        symbolName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceUpdatedAt = sourceUpdatedAt
        self.receivedAt = receivedAt
        self.limits = limits
        self.symbolName = symbolName
    }
}

public struct WatchUsageSnapshotEnvelope: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let tools: [WatchToolQuotaSnapshot]

    public init(
        schemaVersion: Int = WatchUsageSnapshotEnvelope.currentSchemaVersion,
        generatedAt: Date,
        tools: [WatchToolQuotaSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.tools = tools
    }
}

public enum WatchUsageSnapshotCodec {
    public enum CodecError: Error {
        case unsupportedSchemaVersion(Int)
    }

    public static func encode(_ envelope: WatchUsageSnapshotEnvelope) throws -> Data {
        guard envelope.schemaVersion == WatchUsageSnapshotEnvelope.currentSchemaVersion else {
            throw CodecError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> WatchUsageSnapshotEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(WatchUsageSnapshotEnvelope.self, from: data)
        guard envelope.schemaVersion == WatchUsageSnapshotEnvelope.currentSchemaVersion else {
            throw CodecError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        return envelope
    }
}

public enum WatchMessageKey {
    public static let command = "command"
    public static let refresh = "refresh"
    public static let snapshot = "snapshot"
}
