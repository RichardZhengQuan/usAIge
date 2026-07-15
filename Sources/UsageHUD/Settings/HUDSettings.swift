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
        var version = 3
        var bucketOrder: [String] = []
        var hiddenBucketIDs: Set<String> = []
        var toolOrder: [AIToolID] = AIToolID.builtInIDs
        var hiddenToolIDs: Set<AIToolID> = []
        var scale = 1.0
        var opacity = 0.92
        var positions: [String: HUDPosition] = [:]
        var remoteTools: [RemoteAITool] = []

        enum CodingKeys: String, CodingKey {
            case version, bucketOrder, hiddenBucketIDs, toolOrder, hiddenToolIDs
            case scale, opacity, positions
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
           (1...3).contains(decoded.version) {
            payload = decoded
            payload.version = 3
        } else {
            payload = Payload()
        }
        payload.scale = Self.clamp(payload.scale, to: 0.75...1.5)
        payload.opacity = Self.clamp(payload.opacity, to: 0.4...1.0)
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
        set { payload.scale = Self.clamp(newValue, to: 0.75...1.5); persist() }
    }

    var opacity: Double {
        get { payload.opacity }
        set { payload.opacity = Self.clamp(newValue, to: 0.4...1.0); persist() }
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

    func registerBuckets(_ ids: [String]) {
        let additions = Self.stableUnique(ids).filter { !bucketOrder.contains($0) }
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

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
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
