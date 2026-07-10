import Foundation

struct RateLimitBucket: Codable, Equatable, Sendable {
    let limitID: String
    let limitName: String?
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
        case planType
    }
}

struct QuotaSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Date?
    let windowDurationMinutes: Int?
    let planType: String?
    let updatedAt: Date

    static func make(from bucket: RateLimitBucket, updatedAt: Date) -> Self {
        let used = min(100, max(0, bucket.usedPercent))
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
            usedPercent: used,
            remainingPercent: 100 - used,
            resetAt: bucket.resetsAt.map(Date.init(timeIntervalSince1970:)),
            windowDurationMinutes: bucket.windowDurationMinutes,
            planType: bucket.planType,
            updatedAt: updatedAt
        )
    }
}
