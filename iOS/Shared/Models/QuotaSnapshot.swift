import Foundation

public enum QuotaSeverity: Equatable, Sendable {
    case abundant
    case healthy
    case caution
    case low
    case critical

    public init(remainingPercent: Double) {
        if remainingPercent <= 10 {
            self = .critical
        } else if remainingPercent <= 20 {
            self = .low
        } else if remainingPercent <= 40 {
            self = .caution
        } else if remainingPercent <= 60 {
            self = .healthy
        } else {
            self = .abundant
        }
    }
}

public enum CodexSessionPhase: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case thinking
    case complete
    case needsInput
    case error
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .complete: "Complete"
        case .needsInput: "Needs input"
        case .error: "Error"
        }
    }

    public var showsLight: Bool { self != .idle }
}

public struct CodexSessionStatus: Codable, Equatable, Hashable, Sendable {
    public let phase: CodexSessionPhase
    public let updatedAt: Date

    public init(phase: CodexSessionPhase, updatedAt: Date) {
        self.phase = phase
        self.updatedAt = updatedAt
    }
}

public struct QuotaWindowSnapshot: Codable, Equatable, Hashable, Sendable {
    public let remainingPercent: Double
    public let resetAt: Date?
    public let windowDurationMinutes: Int?

    public init(
        remainingPercent: Double,
        resetAt: Date?,
        windowDurationMinutes: Int?
    ) {
        self.remainingPercent = Self.clamp(remainingPercent)
        self.resetAt = resetAt
        self.windowDurationMinutes = windowDurationMinutes.flatMap { $0 > 0 ? $0 : nil }
    }

    public var usedPercent: Double {
        100 - remainingPercent
    }

    public var typeTag: String {
        guard let minutes = windowDurationMinutes else { return "LIMIT" }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)D"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)H"
        }
        return "\(minutes)M"
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

public struct ResetCreditSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let expiresAt: Date?
    public let detail: String?

    public init(id: String, title: String, expiresAt: Date? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.expiresAt = expiresAt
        self.detail = detail
    }
}

public struct QuotaSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable compound identifier made from the tool UUID and remote limit ID.
    public let id: String
    public let limitID: String
    public let toolID: UUID
    public let toolName: String
    public let displayName: String
    public let remainingPercent: Double
    public let resetAt: Date?
    public let updatedAt: Date
    public let planType: String?
    public let windowDurationMinutes: Int?
    public let availableResetCount: Int?
    public let resetCreditExpiresAt: Date?
    public let resetCredits: [ResetCreditSnapshot]
    public let secondaryWindow: QuotaWindowSnapshot?
    public let sessionStatus: CodexSessionStatus?
    /// The SF Symbol the Mac chose for this limit's tool, when the relay sent one.
    public let toolSymbolName: String?

    public init(
        id: String,
        limitID: String,
        toolID: UUID,
        toolName: String,
        displayName: String,
        remainingPercent: Double,
        resetAt: Date?,
        updatedAt: Date,
        planType: String? = nil,
        windowDurationMinutes: Int? = nil,
        availableResetCount: Int? = nil,
        resetCreditExpiresAt: Date? = nil,
        resetCredits: [ResetCreditSnapshot] = [],
        secondaryWindow: QuotaWindowSnapshot? = nil,
        sessionStatus: CodexSessionStatus? = nil,
        toolSymbolName: String? = nil
    ) {
        self.id = id
        self.limitID = limitID
        self.toolID = toolID
        self.toolName = toolName
        self.displayName = displayName
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetAt = resetAt
        self.updatedAt = updatedAt
        self.planType = planType
        self.windowDurationMinutes = windowDurationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.availableResetCount = availableResetCount.map { max(0, $0) }
        self.resetCreditExpiresAt = resetCreditExpiresAt
        self.resetCredits = resetCredits
        self.secondaryWindow = secondaryWindow
        self.sessionStatus = sessionStatus
        self.toolSymbolName = toolSymbolName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        limitID = try container.decode(String.self, forKey: .limitID)
        toolID = try container.decode(UUID.self, forKey: .toolID)
        toolName = try container.decode(String.self, forKey: .toolName)
        displayName = try container.decode(String.self, forKey: .displayName)
        remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        windowDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .windowDurationMinutes)
        availableResetCount = try container.decodeIfPresent(Int.self, forKey: .availableResetCount)
        resetCreditExpiresAt = try container.decodeIfPresent(Date.self, forKey: .resetCreditExpiresAt)
        resetCredits = try container.decodeIfPresent([ResetCreditSnapshot].self, forKey: .resetCredits) ?? []
        secondaryWindow = try container.decodeIfPresent(QuotaWindowSnapshot.self, forKey: .secondaryWindow)
        sessionStatus = try container.decodeIfPresent(CodexSessionStatus.self, forKey: .sessionStatus)
        toolSymbolName = try container.decodeIfPresent(String.self, forKey: .toolSymbolName)
    }

    public var usedPercent: Double {
        100 - remainingPercent
    }

    public var primaryWindow: QuotaWindowSnapshot {
        QuotaWindowSnapshot(
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes
        )
    }

    public var typeTag: String {
        primaryWindow.typeTag
    }

    public var combinedTypeTag: String {
        guard let secondaryWindow else { return typeTag }
        return "\(typeTag) + \(secondaryWindow.typeTag)"
    }

    /// The caller owns the freshness policy; no refresh interval is hidden here.
    public func isStale(at date: Date = Date(), maximumAge: TimeInterval) -> Bool {
        guard maximumAge > 0 else { return true }
        return date.timeIntervalSince(updatedAt) > maximumAge
    }

    public static func stableID(toolID: UUID, limitID: String) -> String {
        "\(toolID.uuidString.lowercased()):\(limitID)"
    }
}
