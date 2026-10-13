import CZstd
import Foundation

/// Decodes the already-cached Claude usage response without external tools.
/// Every allocation has a fixed limit; malformed cache bodies are ignored.
enum ClaudeCacheZstd {
    static let maximumOutputBytes = 1_048_576
    static let maximumInputBytes = 2 * 1_048_576

    static func decode(_ data: Data, maximumOutputBytes: Int = 1_048_576) -> Data? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              maximumOutputBytes > 0, maximumOutputBytes <= Self.maximumOutputBytes else { return nil }
        var output = Data(count: maximumOutputBytes)
        var written = 0
        let success = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                usaige_zstd_decode(
                    source.baseAddress, data.count,
                    destination.baseAddress, maximumOutputBytes, &written
                )
            }
        }
        guard success == 1, written <= maximumOutputBytes else { return nil }
        output.count = written
        return output
    }
}
