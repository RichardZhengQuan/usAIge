import Foundation

/// Small file helpers shared by the session-activity providers that watch a
/// tool's own files instead of talking to a server.
enum AgentActivityFiles {
    struct Attributes: Equatable, Sendable {
        let size: UInt64
        let modifiedAt: Date
    }

    static func attributes(of url: URL) -> Attributes? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (values[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = values[.modificationDate] as? Date ?? .distantPast
        return Attributes(size: size, modifiedAt: modifiedAt)
    }

    /// The last `maximumBytes` of a file. `startsMidLine` is true when the
    /// read began inside a line, so the caller drops that partial line.
    static func tail(of url: URL, maximumBytes: UInt64) -> (data: Data, startsMidLine: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > maximumBytes ? end - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        return (handle.readDataToEndOfFile(), offset > 0)
    }

    static func lines(in data: Data, startsMidLine: Bool) -> [Data] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Whether a process with this id still exists. A process we may not
    /// signal still exists.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}
