import CoreGraphics
import Combine
import Foundation

struct HUDPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

@MainActor
final class HUDSettings: ObservableObject {
    static let scaleRange: ClosedRange<Double> = 0.5...2.5
    static let opacityRange: ClosedRange<Double> = 0.1...1.0
    nonisolated static let usageAlertIntervalOptions = Array(stride(from: 5, through: 100, by: 5))
    nonisolated static let defaultUsageAlertIntervalPercent = 10

    private struct Payload: Codable, Equatable {
        var version = 6
        var bucketOrder: [String] = []
        var hiddenBucketIDs: Set<String> = []
        var toolOrder: [AIToolID] = AIToolID.builtInIDs
        var hiddenToolIDs: Set<AIToolID> = []
        var scale = 1.0
        var opacity = 0.92
        var showsResetCredits = true
        var usageAlertIntervalPercent = HUDSettings.defaultUsageAlertIntervalPercent
        var didApplyLatestBucketDefault = false
        var positions: [String: HUDPosition] = [:]
        var remoteTools: [RemoteAITool] = []

        enum CodingKeys: String, CodingKey {
            case version, bucketOrder, hiddenBucketIDs, toolOrder, hiddenToolIDs
            case scale, opacity, positions
            case showsResetCredits
            case usageAlertIntervalPercent
            case didApplyLatestBucketDefault
            case remoteTools
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            bucketOrder = try values.decodeIfPresent([String].self, forKey: .bucketOrder) ?? []
            hiddenBucketIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenBucketIDs) ?? []
            toolOrder = try values.decodeIfPresent([AIToolID].self, forKey: .toolOrder) ?? AIToolID.builtInIDs
            hiddenToolIDs = try values.decodeIfPresent(Set<AIToolID>.self, forKey: .hiddenToolIDs) ?? []
            scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
            opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.92
            showsResetCredits = try values.decodeIfPresent(
                Bool.self,
                forKey: .showsResetCredits
            ) ?? true
            usageAlertIntervalPercent = try values.decodeIfPresent(
                Int.self,
                forKey: .usageAlertIntervalPercent
            ) ?? HUDSettings.defaultUsageAlertIntervalPercent
            didApplyLatestBucketDefault = try values.decodeIfPresent(
                Bool.self,
                forKey: .didApplyLatestBucketDefault
            ) ?? false
            positions = try values.decodeIfPresent([String: HUDPosition].self, forKey: .positions) ?? [:]
            remoteTools = try values.decodeIfPresent([RemoteAITool].self, forKey: .remoteTools) ?? []
        }
    }

    private static let storageKey = "usageHUD.settings.v1"
    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           (1...6).contains(decoded.version) {
            payload = decoded
            if decoded.version < 5 {
                // Updating users keep their existing bucket visibility exactly as configured.
                payload.didApplyLatestBucketDefault = true
            }
            payload.version = 6
        } else {
            payload = Payload()
        }
        payload.scale = Self.clamp(payload.scale, to: Self.scaleRange)
        payload.opacity = Self.clamp(payload.opacity, to: Self.opacityRange)
        if !Self.usageAlertIntervalOptions.contains(payload.usageAlertIntervalPercent) {
            payload.usageAlertIntervalPercent = Self.defaultUsageAlertIntervalPercent
        }
        var seenRemoteIDs: Set<AIToolID> = []
        payload.remoteTools = payload.remoteTools.filter {
            Self.isValidRemoteID($0.id) && seenRemoteIDs.insert($0.id).inserted
        }
        payload.toolOrder = Self.stableUnique(payload.toolOrder + payload.remoteTools.map(\.id))
        payload.bucketOrder = Self.stableUnique(payload.bucketOrder)
    }

    var bucketOrder: [String] {
        get { payload.bucketOrder }
        set { payload.bucketOrder = newValue; persist() }
    }

    var hiddenBucketIDs: Set<String> {
        get { payload.hiddenBucketIDs }
        set { payload.hiddenBucketIDs = newValue; persist() }
    }

    var toolOrder: [AIToolID] {
        get { payload.toolOrder }
        set { payload.toolOrder = newValue; persist() }
    }

    var hiddenToolIDs: Set<AIToolID> {
        get { payload.hiddenToolIDs }
        set { payload.hiddenToolIDs = newValue; persist() }
    }

    var scale: Double {
        get { payload.scale }
        set { payload.scale = Self.clamp(newValue, to: Self.scaleRange); persist() }
    }

    var opacity: Double {
        get { payload.opacity }
        set { payload.opacity = Self.clamp(newValue, to: Self.opacityRange); persist() }
    }

    var showsResetCredits: Bool {
        get { payload.showsResetCredits }
        set { payload.showsResetCredits = newValue; persist() }
    }

    var usageAlertIntervalPercent: Int {
        get { payload.usageAlertIntervalPercent }
        set {
            guard Self.usageAlertIntervalOptions.contains(newValue) else { return }
            payload.usageAlertIntervalPercent = newValue
            persist()
        }
    }

    var remoteTools: [RemoteAITool] {
        payload.remoteTools
    }

    func ordered(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let order = Dictionary(uniqueKeysWithValues: Self.stableUnique(bucketOrder).enumerated().map { ($1, $0) })
        return snapshots
            .filter { !hiddenBucketIDs.contains($0.id) && !hiddenToolIDs.contains($0.toolID) }
            .sorted { lhs, rhs in
                switch (order[lhs.id], order[rhs.id]) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.id < rhs.id
                }
            }
    }

    var visibleTools: [AIToolDescriptor] {
        toolOrder
            .filter { !hiddenToolIDs.contains($0) }
            .map(AIToolDescriptor.descriptor(for:))
    }

    func upsertRemoteTool(_ tool: RemoteAITool) throws {
        guard Self.isValidRemoteID(tool.id) else {
            throw RemoteToolConfigurationError.invalidIdentifier
        }
        if let index = payload.remoteTools.firstIndex(where: { $0.id == tool.id }) {
            payload.remoteTools[index] = tool
        } else {
            payload.remoteTools.append(tool)
        }
        if !payload.toolOrder.contains(tool.id) {
            payload.toolOrder.append(tool.id)
        }
        persist()
    }

    func setRemoteToolEnabled(_ id: AIToolID, enabled: Bool) {
        guard let index = payload.remoteTools.firstIndex(where: { $0.id == id }) else { return }
        payload.remoteTools[index].isEnabled = enabled
        persist()
    }

    func removeRemoteTool(_ id: AIToolID) {
        payload.remoteTools.removeAll { $0.id == id }
        payload.toolOrder.removeAll { $0 == id }
        payload.hiddenToolIDs.remove(id)
        let prefix = "\(id.rawValue):"
        payload.bucketOrder.removeAll { $0.hasPrefix(prefix) }
        payload.hiddenBucketIDs = payload.hiddenBucketIDs.filter { !$0.hasPrefix(prefix) }
        persist()
    }

    func setPosition(_ point: CGPoint, for displayKey: String) {
        payload.positions[displayKey] = HUDPosition(point)
        persist()
    }

    func position(for displayKey: String) -> CGPoint? {
        payload.positions[displayKey]?.point
    }

    func resetPosition(for displayKey: String) {
        payload.positions.removeValue(forKey: displayKey)
        persist()
    }

    func moveBucket(_ id: String, by offset: Int) {
        var order = bucketOrder
        guard let index = order.firstIndex(of: id) else { return }
        let destination = min(max(0, index + offset), order.count - 1)
        guard destination != index else { return }
        order.swapAt(index, destination)
        bucketOrder = order
    }

    func moveTool(_ id: AIToolID, by offset: Int) {
        var order = toolOrder
        guard let index = order.firstIndex(of: id) else { return }
        let destination = min(max(0, index + offset), order.count - 1)
        guard destination != index else { return }
        order.swapAt(index, destination)
        toolOrder = order
    }

    func registerBuckets(_ snapshots: [QuotaSnapshot]) {
        let additions = Self.stableUnique(snapshots.map(\.id)).filter { !payload.bucketOrder.contains($0) }
        var changed = !additions.isEmpty
        if !additions.isEmpty {
            payload.bucketOrder.append(contentsOf: additions)
        }

        if !payload.didApplyLatestBucketDefault {
            let chatGPTBuckets = snapshots.filter { $0.toolID == .chatGPT }
            if chatGPTBuckets.count > 1,
               let newest = Self.newestDefaultBucket(in: chatGPTBuckets) {
                payload.hiddenBucketIDs.formUnion(
                    chatGPTBuckets.lazy.map(\.id).filter { $0 != newest.id }
                )
                payload.hiddenBucketIDs.remove(newest.id)
                payload.didApplyLatestBucketDefault = true
                changed = true
            }
        }

        guard changed else { return }
        persist()
    }

    private func persist() {
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func newestDefaultBucket(in snapshots: [QuotaSnapshot]) -> QuotaSnapshot? {
        snapshots.max { lhs, rhs in
            let lhsIsNamedModel = lhs.id != "codex"
            let rhsIsNamedModel = rhs.id != "codex"
            if lhsIsNamedModel != rhsIsNamedModel {
                return !lhsIsNamedModel && rhsIsNamedModel
            }
            return lhs.displayName.compare(rhs.displayName, options: .numeric) == .orderedAscending
        }
    }

    private static func isValidRemoteID(_ id: AIToolID) -> Bool {
        UUID(uuidString: id.rawValue) != nil && !AIToolID.builtInIDs.contains(id)
    }
}

enum RemoteToolConfigurationError: LocalizedError {
    case invalidIdentifier

    var errorDescription: String? {
        "Remote tool identifiers must be unique UUIDs."
    }
}
