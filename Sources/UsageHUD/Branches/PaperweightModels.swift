import Foundation

enum PaperweightID: String, CaseIterable, Sendable {
    case memory, storage
}

/// What the Branches window last measured on the disk. The rail's Storage
/// card shows it without scanning anything itself, since scans only run while
/// that window is open.
struct StorageBreakdown: Codable, Equatable, Sendable {
    static let defaultsKey = "usageHUD.branches.storageBreakdown.v1"

    var worktreeBytes: Int64
    var cacheBytes: Int64
    var toolBytes: Int64
    var freeableBytes: Int64
    var measuredAt: Date

    /// Only a finished measurement is kept; a half-read one would understate.
    init?(storage: PaperweightConfiguration, freeableBytes: Int64, measuredAt: Date) {
        guard storage.freeBytes != nil, !storage.layers.isEmpty, storage.layers.allSatisfy({ !$0.isMeasuring }) else { return nil }
        func bytes(_ id: String) -> Int64 { max(0, storage.layers.first { $0.id == id }?.bytes ?? 0) }
        worktreeBytes = bytes("wt")
        cacheBytes = bytes("cache")
        toolBytes = bytes("tool")
        self.freeableBytes = max(0, freeableBytes)
        self.measuredAt = measuredAt
    }

    /// Two measurements show the same thing when only the time differs.
    func sameAmounts(as other: StorageBreakdown?) -> Bool {
        guard let other else { return false }
        return worktreeBytes == other.worktreeBytes && cacheBytes == other.cacheBytes
            && toolBytes == other.toolBytes && freeableBytes == other.freeableBytes
    }

    static func load(from defaults: UserDefaults) -> StorageBreakdown? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(StorageBreakdown.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

struct PaperweightLayer: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var bytes: Int64
    var colorHex: UInt32
    var inkHex: UInt32
    var isMeasuring = false
    var processIDs: Set<Int32> = []
}

struct PaperweightConfiguration: Equatable, Sendable {
    var id: PaperweightID
    var capacityBytes: Int64
    var layers: [PaperweightLayer]
    var freeBytes: Int64?
    var allocationIsEstimated = false
    /// The original category sum remains available when overlapping estimates
    /// have to be fitted inside the disk's observed used space.
    var measuredBytes: Int64? = nil

    var usedBytes: Int64 { PaperweightData.total(layers.map(\.bytes)) }

    var freeLayer: PaperweightLayer {
        PaperweightLayer(
            id: id == .storage ? "free" : "mfree",
            title: id == .storage ? "Free space" : "Other memory",
            bytes: max(0, freeBytes ?? 0), colorHex: 0xB4B2A9, inkHex: 0x343430,
            isMeasuring: freeBytes == nil
        )
    }
}

enum PaperweightData {
    static func storage(
        disk: DiskSpace?, board: BranchesBoard, toolStorage: [ToolStorageEntry],
        isMeasuring: Bool, freeing: Int64 = 0, freeingCacheBytes: Int64 = 0
    ) -> PaperweightConfiguration {
        let folders = BranchesStorageSummary(board: board, toolStorage: []).folders
        let cache = total(folders.map { min(max(0, $0.size?.cacheBytes ?? 0), max(0, $0.size?.totalBytes ?? 0)) })
        let noncache = total(folders.map { max(0, max(0, $0.size?.totalBytes ?? 0) - max(0, $0.size?.cacheBytes ?? 0)) })
        let tools = total(toolStorage.map(\.bytes))
        let raw = [tools, cache, noncache]
        let measured = total(raw)
        let capacity = max(0, disk?.totalBytes ?? 0)
        let available = disk.map { min(capacity, max(0, $0.availableBytes)) }
        let used = available.map { capacity - $0 }
        let freed = min(max(0, freeing), used ?? 0)
        // The review supplies the cache part of its chosen rows, so a preview
        // leaves tool history and the system's remainder alone.
        let cacheFreed = min(cache, min(freed, max(0, freeingCacheBytes)))
        let previewRaw = [tools, cache - cacheFreed, max(0, noncache - (freed - cacheFreed))]
        let previewUsed = used.map { max(0, $0 - freed) }
        let allocated = previewUsed.map { bounded(previewRaw, to: $0) } ?? previewRaw
        let other = previewUsed.map { max(0, $0 - total(allocated)) } ?? 0
        let overlaps = used.map { Double(tools) + Double(cache) + Double(noncache) > Double($0) } ?? false
        let previewOverlaps = previewUsed.map { previewRaw.reduce(0.0) { $0 + Double($1) } > Double($0) } ?? false
        let foldersUnread = board.stillChecking > 0 || folders.contains { $0.size == nil }
        let layers = [
            PaperweightLayer(id: "other", title: "macOS and apps", bytes: other, colorHex: 0x5E9FE3, inkHex: 0x042C53, isMeasuring: disk == nil),
            PaperweightLayer(id: "tool", title: "Tool storage", bytes: allocated[0], colorHex: 0xF4B14A, inkHex: 0x412402, isMeasuring: isMeasuring),
            PaperweightLayer(id: "cache", title: "Build cache", bytes: allocated[1], colorHex: 0x3DB58C, inkHex: 0x04342C, isMeasuring: foldersUnread),
            PaperweightLayer(id: "wt", title: "Worktrees", bytes: allocated[2], colorHex: 0xE2729A, inkHex: 0x4B1528, isMeasuring: foldersUnread),
        ]
        return PaperweightConfiguration(
            id: .storage, capacityBytes: capacity, layers: layers,
            freeBytes: available.map { min(capacity, $0 + freed) },
            allocationIsEstimated: overlaps || previewOverlaps, measuredBytes: measured
        )
    }

    /// The running rows a Memory layer lists. `measured` rows own processes
    /// counted in that layer. A worktree that counts as running only because
    /// its session wrote lately has no process to measure; it is listed under
    /// its tool's layer, or under other memory when that tool has no layer,
    /// so it never drops out of the window.
    static func memoryRows(for layer: PaperweightLayer, in configuration: PaperweightConfiguration,
                           running: [WorkItem]) -> (measured: [WorkItem], sessionOnly: [WorkItem]) {
        var seen: Set<Int32> = []
        let measured = running.compactMap { item -> WorkItem? in
            let own = item.processes.filter { layer.processIDs.contains($0.id) && seen.insert($0.id).inserted }
            guard !own.isEmpty else { return nil }
            var row = item
            row.processes = own
            return row
        }
        let counted = Set(configuration.layers.flatMap(\.processIDs))
        let layerIDs = Set(configuration.layers.map(\.id))
        let sessionOnly = running.filter { item in
            guard !item.processes.contains(where: { counted.contains($0.id) }) else { return false }
            let home = item.sessions.tools.compactMap(toolLayerID).first(where: layerIDs.contains)
            return (home ?? configuration.freeLayer.id) == layer.id
        }
        return (measured, sessionOnly)
    }

    /// Session logs name their tool; this finds that tool's Memory layer.
    static func toolLayerID(_ sessionTool: String) -> String? {
        switch sessionTool {
        case "Claude Code": "tool-" + AIToolID.claude.rawValue
        case "Codex": "tool-" + AIToolID.chatGPT.rawValue
        case "Cursor": "tool-" + AIToolID.cursor.rawValue
        case "Grok Build": "tool-" + AIToolID.grok.rawValue
        default: nil
        }
    }

    static func memory(
        summary: LiveWorkSummary, running: [WorkItem], physicalMemory: UInt64
    ) -> PaperweightConfiguration {
        let toolIDs = Set(summary.sessions.map(\.toolID) + Array(summary.appProcesses.keys)).sorted {
            let left = AIToolID.builtInIDs.firstIndex(of: $0) ?? Int.max
            let right = AIToolID.builtInIDs.firstIndex(of: $1) ?? Int.max
            return left == right ? $0.rawValue < $1.rawValue : left < right
        }
        var seen: Set<Int32> = []
        var tools: [PaperweightLayer] = []
        for tool in toolIDs {
            let processes = summary.sessions(for: tool).flatMap(\.processes) + (summary.appProcesses[tool] ?? [])
            let own = processes.filter { seen.insert($0.id).inserted }
            let bytes = total(own.map { Int64(clamping: $0.memoryBytes) })
            guard bytes > 0 else { continue }
            let colors = colors(for: tool)
            tools.append(PaperweightLayer(
                id: "tool-" + tool.rawValue, title: tool == .chatGPT ? "Codex" : AIToolDescriptor.descriptor(for: tool).name,
                bytes: bytes, colorHex: colors.color, inkHex: colors.ink, processIDs: Set(own.map(\.id))
            ))
        }
        let dev = running.flatMap(\.processes).filter { seen.insert($0.id).inserted }
        let devBytes = total(dev.map { Int64(clamping: $0.memoryBytes) })
        var layers: [PaperweightLayer] = []
        if devBytes > 0 {
            layers.append(PaperweightLayer(id: "dev", title: "Dev servers", bytes: devBytes, colorHex: 0x7DB343, inkHex: 0x173404, processIDs: Set(dev.map(\.id))))
        }
        layers += tools.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes < $1.bytes }
        let capacity = Int64(clamping: physicalMemory)
        let used = total(layers.map(\.bytes))
        return PaperweightConfiguration(
            id: .memory, capacityBytes: capacity, layers: layers, freeBytes: max(0, capacity - used),
            allocationIsEstimated: used > capacity, measuredBytes: used
        )
    }

    static func total(_ values: [Int64]) -> Int64 {
        values.reduce(0) { sum, value in
            let (result, overflow) = sum.addingReportingOverflow(max(0, value))
            return overflow ? Int64.max : result
        }
    }

    /// Rounding stays inside the observed budget, with the last category
    /// taking the remainder so no bytes are manufactured or counted twice.
    private static func bounded(_ values: [Int64], to budget: Int64) -> [Int64] {
        let budget = max(0, budget)
        let sum = values.reduce(0.0) { $0 + Double(max(0, $1)) }
        guard sum > Double(budget), sum > 0 else { return values.map { max(0, $0) } }
        var remaining = budget
        let lastPositive = values.lastIndex { $0 > 0 }
        return values.enumerated().map { index, value in
            guard value > 0 else { return 0 }
            if index == lastPositive { return remaining }
            let share = Double(max(0, value)) / sum * Double(budget)
            let amount = min(remaining, share >= Double(Int64.max) ? Int64.max : Int64(share))
            remaining -= amount
            return amount
        }
    }

    private static func colors(for tool: AIToolID) -> (color: UInt32, ink: UInt32) {
        switch tool {
        case .claude: (0xE8794F, 0x4A1B0C)
        case .chatGPT: (0x9690E3, 0x26215C)
        case .gemini: (0x73B9CF, 0x12343F)
        case .cursor: (0xC5A56B, 0x3D2A10)
        case .grok: (0xA4A8AC, 0x262B2F)
        default: (0xA3B4BF, 0x24333D)
        }
    }
}
