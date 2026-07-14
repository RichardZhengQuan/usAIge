import Foundation

public enum RemoteQuotaPayloadError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case emptyLimits
    case missingLimitID(index: Int)
    case duplicateLimitID(String)
    case missingUsagePercentage(limitID: String, window: String)
    case conflictingUsagePercentages(limitID: String, window: String)
    case percentageOutOfRange(limitID: String, window: String)
    case invalidWindowDuration(limitID: String, window: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported remote quota schema version \(version)."
        case .emptyLimits:
            return "Remote quota payload contains no limits."
        case let .missingLimitID(index):
            return "Remote quota limit at index \(index) has no ID."
        case let .duplicateLimitID(limitID):
            return "Remote quota payload contains duplicate limit ID \(limitID)."
        case let .missingUsagePercentage(limitID, window):
            return "Limit \(limitID) has no usedPercent or remainingPercent for its \(window) window."
        case let .conflictingUsagePercentages(limitID, window):
            return "Limit \(limitID) has conflicting used and remaining percentages for its \(window) window."
        case let .percentageOutOfRange(limitID, window):
            return "Limit \(limitID) has an out-of-range percentage for its \(window) window."
        case let .invalidWindowDuration(limitID, window):
            return "Limit \(limitID) has an invalid duration for its \(window) window."
        }
    }
}

/// Decodes the stable JSON contract expected from a remote quota adapter.
///
/// `usedPercent` is the preferred wire representation. `remainingPercent` is
/// accepted as an alternative. If both are supplied, they must sum to 100.
/// Reset dates can be ISO-8601 strings or Unix timestamps in seconds.
public struct RemoteQuotaPayloadDecoder: Sendable {
    public static let documentedJSONExample = #"""
    {
      "schemaVersion": 1,
      "limits": [
        {
          "id": "messages",
          "displayName": "Messages",
          "usedPercent": 35.5,
          "resetAt": "2026-07-14T12:00:00Z",
          "windowDurationMinutes": 300,
          "planType": "pro",
          "secondaryWindow": {
            "usedPercent": 18,
            "resetAt": "2026-07-20T00:00:00Z",
            "windowDurationMinutes": 10080
          }
        }
      ]
    }
    """#

    public init() {}

    public func decode(
        _ data: Data,
        for configuration: RemoteToolConfiguration,
        updatedAt: Date = Date()
    ) throws -> [QuotaSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeDate(decoder)
        }
        let payload = try decoder.decode(Payload.self, from: data)

        if let schemaVersion = payload.schemaVersion, schemaVersion != 1 {
            throw RemoteQuotaPayloadError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !payload.limits.isEmpty else {
            throw RemoteQuotaPayloadError.emptyLimits
        }

        var seenLimitIDs = Set<String>()
        return try payload.limits.enumerated().map { index, limit in
            let limitID = limit.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !limitID.isEmpty else {
                throw RemoteQuotaPayloadError.missingLimitID(index: index)
            }
            guard seenLimitIDs.insert(limitID).inserted else {
                throw RemoteQuotaPayloadError.duplicateLimitID(limitID)
            }

            let remainingPercent = try Self.remainingPercent(
                used: limit.usedPercent,
                remaining: limit.remainingPercent,
                limitID: limitID,
                window: "primary"
            )
            try Self.validateDuration(
                limit.windowDurationMinutes,
                limitID: limitID,
                window: "primary"
            )

            let secondaryWindow = try limit.secondaryWindow.map { window in
                let remainingPercent = try Self.remainingPercent(
                    used: window.usedPercent,
                    remaining: window.remainingPercent,
                    limitID: limitID,
                    window: "secondary"
                )
                try Self.validateDuration(
                    window.windowDurationMinutes,
                    limitID: limitID,
                    window: "secondary"
                )
                return QuotaWindowSnapshot(
                    remainingPercent: remainingPercent,
                    resetAt: window.resetAt,
                    windowDurationMinutes: window.windowDurationMinutes
                )
            }

            let displayName = limit.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let planType = limit.planType?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return QuotaSnapshot(
                id: QuotaSnapshot.stableID(toolID: configuration.id, limitID: limitID),
                limitID: limitID,
                toolID: configuration.id,
                toolName: configuration.name,
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? Self.humanized(limitID),
                remainingPercent: remainingPercent,
                resetAt: limit.resetAt,
                updatedAt: updatedAt,
                planType: planType.flatMap { $0.isEmpty ? nil : $0 },
                windowDurationMinutes: limit.windowDurationMinutes,
                secondaryWindow: secondaryWindow
            )
        }
    }

    private static func remainingPercent(
        used: Double?,
        remaining: Double?,
        limitID: String,
        window: String
    ) throws -> Double {
        guard used != nil || remaining != nil else {
            throw RemoteQuotaPayloadError.missingUsagePercentage(
                limitID: limitID,
                window: window
            )
        }

        if let used, !(0...100).contains(used) || !used.isFinite {
            throw RemoteQuotaPayloadError.percentageOutOfRange(
                limitID: limitID,
                window: window
            )
        }
        if let remaining, !(0...100).contains(remaining) || !remaining.isFinite {
            throw RemoteQuotaPayloadError.percentageOutOfRange(
                limitID: limitID,
                window: window
            )
        }
        if let used, let remaining, abs((used + remaining) - 100) > 0.01 {
            throw RemoteQuotaPayloadError.conflictingUsagePercentages(
                limitID: limitID,
                window: window
            )
        }
        return remaining ?? (100 - (used ?? 0))
    }

    private static func validateDuration(
        _ duration: Int?,
        limitID: String,
        window: String
    ) throws {
        if let duration, duration <= 0 {
            throw RemoteQuotaPayloadError.invalidWindowDuration(
                limitID: limitID,
                window: window
            )
        }
    }

    private static func humanized(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let timestamp = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: timestamp)
        }

        let value = try container.decode(String.self)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an ISO-8601 date or Unix timestamp in seconds."
        )
    }
}

private extension RemoteQuotaPayloadDecoder {
    struct Payload: Decodable {
        let schemaVersion: Int?
        let limits: [Limit]
    }

    struct Limit: Decodable {
        let id: String
        let displayName: String?
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetAt: Date?
        let windowDurationMinutes: Int?
        let planType: String?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case name
            case usedPercent
            case remainingPercent
            case resetAt
            case windowDurationMinutes
            case windowMinutes
            case planType
            case plan
            case secondaryWindow
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                ?? container.decodeIfPresent(String.self, forKey: .name)
            usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
            remainingPercent = try container.decodeIfPresent(
                Double.self,
                forKey: .remainingPercent
            )
            resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
            windowDurationMinutes = try container.decodeIfPresent(
                Int.self,
                forKey: .windowDurationMinutes
            ) ?? container.decodeIfPresent(Int.self, forKey: .windowMinutes)
            planType = try container.decodeIfPresent(String.self, forKey: .planType)
                ?? container.decodeIfPresent(String.self, forKey: .plan)
            secondaryWindow = try container.decodeIfPresent(
                Window.self,
                forKey: .secondaryWindow
            )
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let remainingPercent: Double?
        let resetAt: Date?
        let windowDurationMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent
            case remainingPercent
            case resetAt
            case windowDurationMinutes
            case windowMinutes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
            remainingPercent = try container.decodeIfPresent(
                Double.self,
                forKey: .remainingPercent
            )
            resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
            windowDurationMinutes = try container.decodeIfPresent(
                Int.self,
                forKey: .windowDurationMinutes
            ) ?? container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        }
    }
}
