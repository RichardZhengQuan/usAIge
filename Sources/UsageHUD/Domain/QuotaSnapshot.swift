import Foundation

struct RateLimitBucket: Codable, Equatable, Sendable {
    let limitID: String
    let limitName: String?
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?
    let planType: String?
    var secondaryUsedPercent: Double? = nil
    var secondaryWindowDurationMinutes: Int? = nil
    var secondaryResetsAt: TimeInterval? = nil

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
        case planType
        case secondaryUsedPercent
        case secondaryWindowDurationMinutes
        case secondaryResetsAt
    }
}

struct QuotaWindowSnapshot: Codable, Equatable, Sendable {
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?

    var typeTag: String {
        guard let minutes = windowDurationMinutes, minutes > 0 else { return "LIMIT" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)D" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }

    static func make(
        usedPercent: Double,
        windowDurationMinutes: Int?,
        resetsAt: TimeInterval?
    ) -> Self {
        let used = min(100, max(0, usedPercent))
        return Self(
            usedPercent: used,
            remainingPercent: 100 - used,
            resetAt: resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowDurationMinutes: windowDurationMinutes
        )
    }
}

struct QuotaSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var toolID: AIToolID = .chatGPT
    var toolName: String? = nil
    var toolWebURL: URL? = nil
    var toolSystemImage: String? = nil
    let displayName: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?
    let planType: String?
    let updatedAt: Date
    var availableResetCount: Int? = nil
    var resetCreditExpiresAt: Date? = nil
    var secondaryWindow: QuotaWindowSnapshot? = nil

    var typeTag: String {
        primaryWindow.typeTag
    }

    var primaryWindow: QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes
        )
    }

    var combinedTypeTag: String {
        guard let secondaryWindow else { return typeTag }
        return "\(typeTag) + \(secondaryWindow.typeTag)"
    }

    static func make(from bucket: RateLimitBucket, updatedAt: Date) -> Self {
        let primary = QuotaWindowSnapshot.make(
            usedPercent: bucket.usedPercent,
            windowDurationMinutes: bucket.windowDurationMinutes,
            resetsAt: bucket.resetsAt
        )
        let secondary = bucket.secondaryUsedPercent.map {
            QuotaWindowSnapshot.make(
                usedPercent: $0,
                windowDurationMinutes: bucket.secondaryWindowDurationMinutes,
                resetsAt: bucket.secondaryResetsAt
            )
        }
        let fallbackName = bucket.limitID
            .split(separator: "_")
            .map { part in
                guard let first = part.first else { return "" }
                return first.uppercased() + part.dropFirst()
            }
            .joined(separator: " ")

        return Self(
            id: bucket.limitID,
            displayName: bucket.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            usedPercent: primary.usedPercent,
            remainingPercent: primary.remainingPercent,
            resetAt: primary.resetAt,
            windowDurationMinutes: primary.windowDurationMinutes,
            planType: bucket.planType,
            updatedAt: updatedAt,
            secondaryWindow: secondary
        )
    }
}
