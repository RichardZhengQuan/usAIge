import CryptoKit
import Darwin
import Foundation

struct ClaudeDesktopCachedUsage: Equatable, Sendable {
    let payload: JSONValue
    let recordedAt: Date
}

/// Reads only Claude's locally cached usage responses. The supported layout is
/// Chromium Simple cache v5 / index v9, independently implemented from its BSD
/// format definitions. No cookies, credentials, or network requests are used.
struct ClaudeDesktopUsageCache: Sendable {
    static let maximumEntryBytes = 2 * 1_024 * 1_024
    static let maximumAge: TimeInterval = 30 * 60
    private let directory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
    }

    func latestUsage(organizationID: String, now: Date) -> ClaudeDesktopCachedUsage? {
        let indexURL = directory.appendingPathComponent("index-dir/the-real-index")
        guard let index = Self.readBounded(indexURL, limit: 4 * 1_024 * 1_024),
              let hashes = Self.indexHashes(index),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        var newest: ClaudeDesktopCachedUsage?
        for file in files {
            let name = file.lastPathComponent
            guard name.count == 18, name.hasSuffix("_0"),
                  let hash = UInt64(name.prefix(16), radix: 16), hashes.contains(hash),
                  let key = Self.readKey(file), Self.isUsageKey(key, organizationID: organizationID),
                  let data = Self.readBounded(file, limit: Self.maximumEntryBytes),
                  let usage = Self.parseEntry(data, filename: name, organizationID: organizationID, now: now),
                  // Reject partial/in-flight replacement rather than locking or
                  // copying any of Claude's cache files.
                  Self.readBounded(file, limit: Self.maximumEntryBytes) == data,
                  let currentIndex = Self.readBounded(indexURL, limit: 4 * 1_024 * 1_024),
                  Self.indexHashes(currentIndex)?.contains(hash) == true
            else { continue }
            if newest.map({ usage.recordedAt > $0.recordedAt }) ?? true { newest = usage }
        }
        return newest
    }

    static func indexHashes(_ data: Data) -> Set<UInt64>? {
        let bytes = CacheBytes(data)
        guard (48...4 * 1_024 * 1_024).contains(data.count),
              bytes.u32(0) == UInt32(data.count - 8),
              bytes.u32(4) == crc32(Data(data.dropFirst(8))),
              bytes.u64(8) == 0x656e74657220796f,
              bytes.u32(16) == 9,
              let count = bytes.u64(20), count <= 100_000,
              data.count == 48 + Int(count) * 24
        else { return nil }
        var hashes = Set<UInt64>()
        for entry in 0..<Int(count) {
            let offset = 40 + entry * 24
            guard let hash = bytes.u64(offset), hashes.insert(hash).inserted,
                  let packedInfo = bytes.u64(offset + 16), packedInfo >> 38 == 0 else { return nil }
        }
        return hashes
    }

    static func parseEntry(_ data: Data, filename: String, organizationID: String, now: Date) -> ClaudeDesktopCachedUsage? {
        let bytes = CacheBytes(data)
        guard data.count <= maximumEntryBytes, data.count >= 72,
              bytes.u64(0) == 0xfcfb6d1ba7725c30, bytes.u32(8) == 5, bytes.u32(20) == 0,
              let keyLength = bytes.u32(12), keyLength > 0, keyLength <= 4_096,
              24 + Int(keyLength) <= data.count - 48
        else { return nil }
        let keyData = data.subdata(in: 24..<24 + Int(keyLength))
        guard let key = String(data: keyData, encoding: .utf8),
              isUsageKey(key, organizationID: organizationID), filename == entryFilename(key: key)
        else { return nil }
        let footer = data.count - 24
        guard bytes.u64(footer) == 0xf4fa6f45970d41d8,
              let flags = bytes.u32(footer + 8), flags == 3,
              bytes.u32(footer + 20) == 0,
              let metadataSize = bytes.u32(footer + 16), metadataSize > 0,
              Int(metadataSize) <= footer - 32 - 24 - 24 - Int(keyLength)
        else { return nil }
        let metadataStart = footer - 32 - Int(metadataSize)
        let bodyEnd = metadataStart - 24
        guard bytes.u64(bodyEnd) == 0xf4fa6f45970d41d8,
              bytes.u32(bodyEnd + 8) == 1, bytes.u32(bodyEnd + 16) == 0, bytes.u32(bodyEnd + 20) == 0,
              data.subdata(in: footer - 32..<footer) == Data(SHA256.hash(data: keyData))
        else { return nil }
        let body = data.subdata(in: 24 + Int(keyLength)..<bodyEnd)
        let metadata = data.subdata(in: metadataStart..<footer - 32)
        guard bytes.u32(bodyEnd + 12) == crc32(body),
              bytes.u32(footer + 12) == crc32(metadata),
              let recordedAt = responseDate(metadata),
              (0...maximumAge).contains(now.timeIntervalSince(recordedAt))
        else { return nil }
        let decoded: Data
        if body.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            guard let value = ClaudeCacheZstd.decode(body) else { return nil }
            decoded = value
        } else {
            // Unsupported encodings remain unknown. Never substitute a guessed
            // reset or require the user to install a decoding utility.
            guard body.drop(while: { [9, 10, 13, 32].contains($0) }).first == UInt8(ascii: "{") else { return nil }
            decoded = body
        }
        guard let payload = JSONValue.parse(decoded),
              let usable = validatedPayload(payload, now: now) else { return nil }
        return ClaudeDesktopCachedUsage(payload: usable, recordedAt: recordedAt)
    }

    static func entryFilename(key: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(key.utf8)))
        let hash = digest.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        return String(format: "%016llx_0", hash)
    }

    private static func isUsageKey(_ key: String, organizationID: String) -> Bool {
        guard let organization = UUID(uuidString: organizationID) else { return false }
        let parts = key.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, ["0", "1"].contains(String(parts[0])), parts[1] == "0" else { return false }
        var resource = String(parts[2])
        if resource.hasPrefix("_dk_") {
            guard let separator = resource.lastIndex(of: " ") else { return false }
            resource = String(resource[resource.index(after: separator)...])
        }
        let url = "https://claude.ai/api/organizations/\(organization.uuidString.lowercased())/usage"
        return [url, url + "?skip_spend=1", url + "?cedar_ember=1&skip_spend=1"].contains(resource)
    }

    private static func responseDate(_ data: Data) -> Date? {
        let bytes = CacheBytes(data)
        guard data.count >= 28, bytes.u32(0) == UInt32(data.count - 4),
              let flags = bytes.u32(4), flags & 255 == 3, flags & (1 << 12) == 0 else { return nil }
        let hasExtra = flags & (1 << 31) != 0
        let extra = hasExtra ? bytes.u32(8) ?? 0 : 0
        var offset = hasExtra ? 12 : 8
        guard let time = bytes.u64(offset + 8) else { return nil }
        var observed = Int64(bitPattern: time)
        offset += 16
        if extra & 4 != 0 {
            guard let original = bytes.u64(offset) else { return nil }
            observed = min(observed, Int64(bitPattern: original))
            offset += 8
        }
        guard let length = bytes.u32(offset), length <= 64 * 1_024,
              offset + 4 + Int(length) <= data.count else { return nil }
        let headers = data.subdata(in: offset + 4..<offset + 4 + Int(length)).split(separator: 0)
        guard let first = headers.first, let status = String(data: Data(first), encoding: .ascii) else { return nil }
        let statusParts = status.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, ["HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/2.0"].contains(String(statusParts[0])),
              statusParts[1] == "200" else { return nil }
        let contentTypes = headers.dropFirst().compactMap { line -> String? in
            guard let field = String(data: Data(line), encoding: .ascii), let colon = field.firstIndex(of: ":"),
                  field[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-type" else { return nil }
            return field[field.index(after: colon)...].split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard contentTypes == ["application/json"] else { return nil }
        return Date(timeIntervalSince1970: Double(observed) / 1_000_000 - 11_644_473_600)
    }

    /// A cache response must contain a real, current reset. Unknown/expired
    /// values cannot override the desktop's percentage-only history.
    static func validatedPayload(_ payload: JSONValue, now: Date) -> JSONValue? {
        guard var object = payload.objectValue else { return nil }
        var hasWindow = false
        for (key, window) in object where key == "five_hour" || key.hasPrefix("five_hour_")
            || key == "seven_day" || key.hasPrefix("seven_day_") {
            if validWindow(window, percentKey: "utilization", now: now) { hasWindow = true }
            else { object.removeValue(forKey: key) }
        }
        if let limits = object["limits"]?.arrayValue {
            let current = limits.filter {
                guard let kind = $0["kind"]?.stringValue, !kind.isEmpty else { return false }
                return validWindow($0, percentKey: "percent", now: now)
            }
            // A nonempty modern limits list is authoritative. Never revive
            // legacy windows when its last actual limit has expired.
            guard limits.isEmpty || !current.isEmpty else { return nil }
            object["limits"] = .array(current)
            if !current.isEmpty { hasWindow = true }
        } else if let limits = object["limits"], limits != .null {
            return nil
        }
        if let extra = object["extra_usage"], extra["is_enabled"]?.boolValue == true {
            let percent = extra["utilization"]?.lenientNumber ?? {
                guard let used = extra["used_credits"]?.lenientNumber,
                      let limit = extra["monthly_limit"]?.lenientNumber, limit > 0 else { return nil }
                return used / limit * 100
            }()
            if let percent, percent.isFinite, percent >= 0,
               let reset = LocalToolDates.parse(extra["resets_at"]?.stringValue), reset > now {
                hasWindow = true
            } else {
                object.removeValue(forKey: "extra_usage")
            }
        }
        return hasWindow ? .object(object) : nil
    }

    private static func validWindow(_ window: JSONValue, percentKey: String, now: Date) -> Bool {
        guard let percent = window[percentKey]?.numberValue, percent.isFinite, percent >= 0,
              let reset = LocalToolDates.parse(window["resets_at"]?.stringValue), reset > now else { return false }
        return true
    }

    private static func readKey(_ url: URL) -> String? {
        guard let handle = openRegularFile(url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24,
              CacheBytes(header).u64(0) == 0xfcfb6d1ba7725c30,
              let length = CacheBytes(header).u32(12), length > 0, length <= 4_096,
              let key = try? handle.read(upToCount: Int(length)), key.count == Int(length) else { return nil }
        return String(data: key, encoding: .utf8)
    }

    private static func readBounded(_ url: URL, limit: Int) -> Data? {
        guard let handle = openRegularFile(url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private static func openRegularFile(_ url: URL) -> FileHandle? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

private struct CacheBytes {
    let data: Data
    init(_ data: Data) { self.data = data }
    func u32(_ offset: Int) -> UInt32? { value(offset, count: 4).map(UInt32.init) }
    func u64(_ offset: Int) -> UInt64? { value(offset, count: 8) }
    private func value(_ offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - count else { return nil }
        return (0..<count).reduce(0) { $0 | UInt64(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
}
