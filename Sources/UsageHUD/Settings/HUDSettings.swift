import CoreGraphics
import Foundation
import Observation

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
@Observable
final class HUDSettings {
    private struct Payload: Codable, Equatable {
        var version = 2
        var bucketOrder: [String] = []
        var hiddenBucketIDs: Set<String> = []
        var toolOrder: [AIToolID] = AIToolID.allCases
        var hiddenToolIDs: Set<AIToolID> = []
        var scale = 1.0
        var opacity = 0.92
        var positions: [String: HUDPosition] = [:]

        enum CodingKeys: String, CodingKey {
            case version, bucketOrder, hiddenBucketIDs, toolOrder, hiddenToolIDs
            case scale, opacity, positions
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            bucketOrder = try values.decodeIfPresent([String].self, forKey: .bucketOrder) ?? []
            hiddenBucketIDs = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenBucketIDs) ?? []
            toolOrder = try values.decodeIfPresent([AIToolID].self, forKey: .toolOrder) ?? AIToolID.allCases
            hiddenToolIDs = try values.decodeIfPresent(Set<AIToolID>.self, forKey: .hiddenToolIDs) ?? []
            scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
            opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.92
            positions = try values.decodeIfPresent([String: HUDPosition].self, forKey: .positions) ?? [:]
        }
    }

    private static let storageKey = "usageHUD.settings.v1"
    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           (1...2).contains(decoded.version) {
            payload = decoded
            payload.version = 2
        } else {
            payload = Payload()
        }
        payload.scale = Self.clamp(payload.scale, to: 0.75...1.5)
        payload.opacity = Self.clamp(payload.opacity, to: 0.4...1.0)
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
        set { payload.scale = Self.clamp(newValue, to: 0.75...1.5); persist() }
    }

    var opacity: Double {
        get { payload.opacity }
        set { payload.opacity = Self.clamp(newValue, to: 0.4...1.0); persist() }
    }

    func ordered(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let order = Dictionary(uniqueKeysWithValues: bucketOrder.enumerated().map { ($1, $0) })
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

    func registerBuckets(_ ids: [String]) {
        let additions = ids.filter { !bucketOrder.contains($0) }
        guard !additions.isEmpty else { return }
        bucketOrder.append(contentsOf: additions)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
