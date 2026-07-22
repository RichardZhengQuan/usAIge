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
    nonisolated static let usageAlertIntervalOptions = [5, 10, 20, 50]
    nonisolated static let defaultUsageAlertIntervalPercent = 10

    private struct LegacyRemoteTool: Codable, Equatable {
        let id: AIToolID
    }

    private struct Payload: Codable, Equatable {
        var version = 8
        var bucketOrder: [String] = []
        var hiddenBucketIDs: Set<String> = []
        var toolOrder: [AIToolID] = AIToolID.builtInIDs
        var hiddenToolIDs: Set<AIToolID> = []
        var scale = 1.0
        var opacity = 0.92
        var showsResetCredits = true
        var usageAlertIntervalPercent = HUDSettings.defaultUsageAlertIntervalPercent
        var didApplyLatestBucketDefault = false
        var didApplyPrimaryBucketDefault = false
        var positions: [String: HUDPosition] = [:]
        var remoteTools: [LegacyRemoteTool] = []

        enum CodingKeys: String, CodingKey {
            case version, bucketOrder, hiddenBucketIDs, toolOrder, hiddenToolIDs
            case scale, opacity, positions
            case showsResetCredits
            case usageAlertIntervalPercent
            case didApplyLatestBucketDefault
            case didApplyPrimaryBucketDefault
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
            didApplyPrimaryBucketDefault = try values.decodeIfPresent(
                Bool.self,
                forKey: .didApplyPrimaryBucketDefault
            ) ?? false
            positions = try values.decodeIfPresent([String: HUDPosition].self, forKey: .positions) ?? [:]
            remoteTools = try values.decodeIfPresent([LegacyRemoteTool].self, forKey: .remoteTools) ?? []
        }
    }

    private static let storageKey = "usageHUD.settings.v1"
    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           (1...8).contains(decoded.version) {
            payload = decoded
            if decoded.version < 5 {
                // Updating users keep their existing bucket visibility exactly as configured.
                payload.didApplyPrimaryBucketDefault = true
            } else if decoded.version < 8 {
                // Migrate the exact versions 5–7 automatic choice without overriding
                // users who subsequently chose Codex or enabled both buckets.
                payload.didApplyPrimaryBucketDefault = !(
                    payload.didApplyLatestBucketDefault
                        && payload.hiddenBucketIDs.contains("codex")
                )
            }
            if decoded.version < 7 {
                let legacyRemoteIDs = Set(payload.remoteTools.map(\.id))
                payload.remoteTools = []
                payload.toolOrder.removeAll { legacyRemoteIDs.contains($0) }
                payload.hiddenToolIDs.subtract(legacyRemoteIDs)
                payload.bucketOrder.removeAll { id in
                    legacyRemoteIDs.contains { id.hasPrefix("\($0.rawValue):") }
                }
                payload.hiddenBucketIDs = payload.hiddenBucketIDs.filter { id in
                    !legacyRemoteIDs.contains { id.hasPrefix("\($0.rawValue):") }
                }
            }
            payload.version = 8
        } else {
            payload = Payload()
        }
        payload.scale = Self.clamp(payload.scale, to: Self.scaleRange)
        payload.opacity = Self.clamp(payload.opacity, to: Self.opacityRange)
        if !Self.usageAlertIntervalOptions.contains(payload.usageAlertIntervalPercent) {
            payload.usageAlertIntervalPercent = Self.defaultUsageAlertIntervalPercent
        }
        payload.remoteTools = []
        payload.toolOrder = Self.stableUnique(payload.toolOrder)
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
        let toolAdditions = Self.stableUnique(snapshots.map(\.toolID))
            .filter { !payload.toolOrder.contains($0) }
        var changed = !additions.isEmpty || !toolAdditions.isEmpty
        if !additions.isEmpty {
            payload.bucketOrder.append(contentsOf: additions)
        }
        if !toolAdditions.isEmpty {
            payload.toolOrder.append(contentsOf: toolAdditions)
        }

        if !payload.didApplyPrimaryBucketDefault {
            let chatGPTBuckets = snapshots.filter { $0.toolID == .chatGPT }
            if chatGPTBuckets.count > 1,
               let preferred = Self.preferredDefaultBucket(in: chatGPTBuckets) {
                payload.hiddenBucketIDs.formUnion(
                    chatGPTBuckets.lazy.map(\.id).filter { $0 != preferred.id }
                )
                payload.hiddenBucketIDs.remove(preferred.id)
                payload.didApplyPrimaryBucketDefault = true
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

    private static func preferredDefaultBucket(in snapshots: [QuotaSnapshot]) -> QuotaSnapshot? {
        if let primary = snapshots.first(where: { $0.id == "codex" }) {
            return primary
        }
        return snapshots.max { lhs, rhs in
            return lhs.displayName.compare(rhs.displayName, options: .numeric) == .orderedAscending
        }
    }

}
