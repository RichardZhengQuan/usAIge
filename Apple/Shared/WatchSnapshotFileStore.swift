import Foundation

struct WatchSnapshotFileStore: Sendable {
    let fileURL: URL

    func load() throws -> WatchUsageSnapshotEnvelope? {
        do {
            return try WatchUsageSnapshotCodec.decode(Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ envelope: WatchUsageSnapshotEnvelope) throws {
        let data = try WatchUsageSnapshotCodec.encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
