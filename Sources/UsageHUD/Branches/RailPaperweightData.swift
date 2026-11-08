import Foundation

enum RailPaperweightData {
    static func memory(_ summary: LiveWorkSummary, physicalMemory: UInt64) -> PaperweightConfiguration {
        PaperweightData.memory(summary: summary, running: [], physicalMemory: physicalMemory)
    }

    static func storage(_ disk: DiskSpace?) -> PaperweightConfiguration {
        let capacity = max(0, disk?.totalBytes ?? 0)
        let used = min(capacity, max(0, disk?.usedBytes ?? 0))
        return PaperweightConfiguration(
            id: .storage, capacityBytes: capacity,
            layers: [PaperweightLayer(id: "used", title: "Storage", bytes: used,
                                     colorHex: storageColor(disk?.usedShare() ?? 0), inkHex: 0x042C53)],
            freeBytes: disk.map { _ in capacity - used }
        )
    }

    /// The calm disk starts in the system layer's blue, then takes on the
    /// rail's warning colours at the same fullness thresholds as its rings.
    static func storageColor(_ share: Double) -> UInt32 {
        let tint: (hex: UInt32, amount: Double) = switch LiveWorkText.severity(share) {
        case .abundant: (0x5E9FE3, 0)
        case .healthy: (0x34C759, 0.2)
        case .caution: (0xFF9500, 0.72)
        case .low: (0xFF3B30, 0.86)
        case .critical: (0xB8000A, 0.94)
        }
        let base: UInt32 = 0x5E9FE3
        return [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let start = Double((base >> shift) & 255)
            let end = Double((tint.hex >> shift) & 255)
            return result | (UInt32((start + (end - start) * tint.amount).rounded()) << shift)
        }
    }
}
