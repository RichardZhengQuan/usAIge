import CryptoKit
import Foundation
import Testing
@testable import UsageHUD

private let cacheOrganization = "33333333-3333-4333-8333-333333333333"
private let cacheTestNow = Date(timeIntervalSince1970: 1_791_815_400) // 2026-10-12 14:30 UTC
private let cacheFixturePayload = Data(
    #"{"five_hour":{"utilization":27,"resets_at":"2026-10-12T18:30:00Z"},"seven_day":{"utilization":63,"resets_at":"2026-10-16T03:00:00Z"}}"#.utf8
)

private func fixtureKey(query: String = "", organization: String = cacheOrganization) -> String {
    "1/0/https://claude.ai/api/organizations/\(organization)/usage\(query)"
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        append(contentsOf: (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    mutating func putLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var encoded = Data()
        encoded.appendLittleEndian(value)
        replaceSubrange(offset..<offset + encoded.count, with: encoded)
    }
}

private func cacheTime(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
}

/// Disposable Simple v5 files, assembled using the published Chromium layout.
/// No fixture accesses Claude's real cache, account, or configuration.
private struct SimpleUsageFixture {
    let key: String
    let filename: String
    let data: Data
    let bodyStart: Int
    let bodyEnd: Int
    let metadataStart: Int

    init(
        key: String = fixtureKey(),
        body: Data = cacheFixturePayload,
        fetchedAt: Date = cacheTestNow.addingTimeInterval(-10),
        originalAt: Date? = nil,
        status: String = "HTTP/1.1 200 OK",
        fields: [String] = ["Content-Type: application/json; charset=utf-8"],
        truncated: Bool = false
    ) {
        self.key = key
        filename = ClaudeDesktopUsageCache.entryFilename(key: key)
        let keyBytes = Data(key.utf8)
        var metadata = Data()
        metadata.appendLittleEndian(UInt32(0)) // Pickle payload length, filled below.
        var flags: UInt32 = 3
        if originalAt != nil { flags |= 1 << 31 }
        if truncated { flags |= 1 << 12 }
        metadata.appendLittleEndian(flags)
        if originalAt != nil { metadata.appendLittleEndian(UInt32(4)) }
        metadata.appendLittleEndian(cacheTime(fetchedAt.addingTimeInterval(-1)))
        metadata.appendLittleEndian(cacheTime(fetchedAt))
        if let originalAt { metadata.appendLittleEndian(cacheTime(originalAt)) }
        let headers = Data(([status] + fields + [""]).joined(separator: "\0").utf8) + Data([0])
        metadata.appendLittleEndian(UInt32(headers.count))
        metadata.append(headers)
        metadata.putLittleEndian(UInt32(metadata.count - 4), at: 0)

        func footer(_ stream: Data, flags: UInt32, streamSize: UInt32) -> Data {
            var result = Data()
            result.appendLittleEndian(UInt64(0xf4fa6f45970d41d8))
            result.appendLittleEndian(flags)
            result.appendLittleEndian(ClaudeDesktopUsageCache.crc32(stream))
            result.appendLittleEndian(streamSize)
            result.appendLittleEndian(UInt32(0))
            return result
        }

        var entry = Data()
        entry.appendLittleEndian(UInt64(0xfcfb6d1ba7725c30))
        entry.appendLittleEndian(UInt32(5))
        entry.appendLittleEndian(UInt32(keyBytes.count))
        entry.appendLittleEndian(UInt32(0)) // SHA256 below validates the complete key.
        entry.appendLittleEndian(UInt32(0))
        entry.append(keyBytes)
        bodyStart = entry.count
        entry.append(body)
        bodyEnd = entry.count
        entry.append(footer(body, flags: 1, streamSize: 0))
        metadataStart = entry.count
        entry.append(metadata)
        entry.append(contentsOf: SHA256.hash(data: keyBytes))
        entry.append(footer(metadata, flags: 3, streamSize: UInt32(metadata.count)))
        data = entry
    }

    func parse(_ bytes: Data? = nil, filename: String? = nil, now: Date = cacheTestNow) -> ClaudeDesktopCachedUsage? {
        ClaudeDesktopUsageCache.parseEntry(bytes ?? data, filename: filename ?? self.filename,
                                          organizationID: cacheOrganization, now: now)
    }
}

private func simpleIndex(filenames: [String], packedInfo: UInt64 = 256) -> Data {
    var payload = Data()
    payload.appendLittleEndian(UInt64(0x656e74657220796f))
    payload.appendLittleEndian(UInt32(9))
    payload.appendLittleEndian(UInt64(filenames.count))
    payload.appendLittleEndian(UInt64(1_024))
    payload.appendLittleEndian(UInt32(2))
    for filename in filenames {
        payload.appendLittleEndian(UInt64(filename.prefix(16), radix: 16)!)
        payload.appendLittleEndian(cacheTime(cacheTestNow))
        payload.appendLittleEndian(packedInfo)
    }
    payload.appendLittleEndian(cacheTime(cacheTestNow))
    var index = Data()
    index.appendLittleEndian(UInt32(payload.count))
    index.appendLittleEndian(ClaudeDesktopUsageCache.crc32(payload))
    index.append(payload)
    return index
}

@Suite struct ClaudeDesktopUsageCacheTests {
    @Test func freshPlainAndCompressedResponsesCarryExactResets() throws {
        let fixture = SimpleUsageFixture()
        let result = try #require(fixture.parse())
        #expect(result.recordedAt == cacheTestNow.addingTimeInterval(-10))
        #expect(result.payload["five_hour"]?["resets_at"]?.stringValue == "2026-10-12T18:30:00Z")
        #expect(result.payload["seven_day"]?["utilization"]?.numberValue == 63)
        // Official Zstandard v1.5.7 compressed-block fixture, independently
        // generated by the decoder tests. Its decompressed quota equals ours.
        let frame = try #require(Data(base64Encoded:
            "KLUv/SSF3QIAYoUTGYAnbvBx+N9ntgQUJHVgZAhxcWN7XmpD5owJKkKVUDIwwWp77HtJHkBURAo4Ko/BY1JiXt9svd63xQuR+ua42YEL3MYRfWE4wtqDB0cCAwAgK1BjU8zhDDWULSo="
        ))
        #expect(SimpleUsageFixture(body: frame).parse()?.payload == result.payload)
        #expect(SimpleUsageFixture(body: Data(" \n".utf8) + cacheFixturePayload).parse()?.payload == result.payload)
    }

    @Test func responseAgeUsesTheOriginalBodyTimeAndRejectsTheFuture() {
        #expect(SimpleUsageFixture(fetchedAt: cacheTestNow.addingTimeInterval(-1_800)).parse() != nil)
        #expect(SimpleUsageFixture(fetchedAt: cacheTestNow.addingTimeInterval(-1_801)).parse() == nil)
        #expect(SimpleUsageFixture(fetchedAt: cacheTestNow.addingTimeInterval(1)).parse() == nil)
        #expect(SimpleUsageFixture(originalAt: cacheTestNow.addingTimeInterval(-1_801)).parse() == nil)
        #expect(SimpleUsageFixture(originalAt: cacheTestNow.addingTimeInterval(-20)).parse()?.recordedAt
                == cacheTestNow.addingTimeInterval(-20))
        #expect(SimpleUsageFixture(truncated: true).parse() == nil)
    }

    @Test func statusAndMimeAreParsedAsCompleteFields() {
        for status in ["HTTP/1.1 2000", "HTTP/2 200evil", "HTTP/1.1 201 OK", "HTTP/1.1 304 Not Modified", "HTTP/3 200 OK"] {
            #expect(SimpleUsageFixture(status: status).parse() == nil)
        }
        for field in ["content-type:application/jsonp", "Content-Type: text/plain", "X-Content-Type: application/json"] {
            #expect(SimpleUsageFixture(fields: [field]).parse() == nil)
        }
        #expect(SimpleUsageFixture(status: "HTTP/2 200", fields: ["content-type:application/json"]).parse() != nil)
        #expect(SimpleUsageFixture(fields: ["cOnTeNt-TyPe: APPLICATION/JSON ; charset=UTF-8"]).parse() != nil)
        #expect(SimpleUsageFixture(fields: []).parse() == nil)
        #expect(SimpleUsageFixture(fields: ["Content-Type: application/json", "Content-Type: text/html"]).parse() == nil)
    }

    @Test func onlyTheExactCurrentOrganizationEndpointIsRead() {
        for query in ["", "?skip_spend=1", "?cedar_ember=1&skip_spend=1"] {
            #expect(SimpleUsageFixture(key: fixtureKey(query: query)).parse() != nil)
        }
        #expect(SimpleUsageFixture(key: "1/0/_dk_https://claude.ai https://claude.ai " + String(fixtureKey().dropFirst(4))).parse() != nil)
        let invalidKeys = [
            fixtureKey(organization: "44444444-4444-4444-8444-444444444444"),
            fixtureKey(query: "?unknown=1"), fixtureKey(query: "?skip_spend=1&unknown=1"),
            fixtureKey(query: "#fragment"), "1/123/" + String(fixtureKey().dropFirst(4)),
            "1/0/https://attacker.invalid/" + String(fixtureKey().dropFirst(4)),
            fixtureKey().replacingOccurrences(of: "https://claude.ai", with: "https://claude.ai.attacker.invalid"),
            fixtureKey().replacingOccurrences(of: "https://", with: "http://"),
            "_dk_ " + fixtureKey(),
        ]
        for key in invalidKeys { #expect(SimpleUsageFixture(key: key).parse() == nil) }
        let fixture = SimpleUsageFixture()
        #expect(fixture.parse(filename: "0000000000000000_0") == nil)
        #expect(fixture.parse(filename: "doomed_" + fixture.filename) == nil)
        #expect(ClaudeDesktopUsageCache.parseEntry(fixture.data, filename: fixture.filename,
                                                  organizationID: "invalid", now: cacheTestNow) == nil)
    }

    @Test func checksumsAndFooterBoundsRejectCorruption() {
        #expect(ClaudeDesktopUsageCache.crc32(Data("123456789".utf8)) == 0xcbf43926)
        let fixture = SimpleUsageFixture()
        let offsets = [0, 8, 12, 20, fixture.bodyStart, fixture.bodyEnd, fixture.bodyEnd + 8,
                       fixture.metadataStart, fixture.data.count - 25, fixture.data.count - 24,
                       fixture.data.count - 16, fixture.data.count - 12, fixture.data.count - 8,
                       fixture.data.count - 4]
        for offset in offsets {
            var corrupt = fixture.data
            corrupt[offset] ^= 1
            #expect(fixture.parse(corrupt) == nil)
        }
        for count in [0, 23, 24, fixture.bodyStart, fixture.bodyEnd, fixture.metadataStart, fixture.data.count - 1] {
            #expect(fixture.parse(Data(fixture.data.prefix(count))) == nil)
        }
        #expect(fixture.parse(fixture.data + Data([0])) == nil)
        #expect(fixture.parse(Data(repeating: 0, count: ClaudeDesktopUsageCache.maximumEntryBytes + 1)) == nil)
    }

    @Test func expiredInvalidAndMissingResetsCannotReplaceHistory() throws {
        for body in ["{}", "[]", #"{"five_hour":{"utilization":20}}"#,
                     #"{"five_hour":{"utilization":20,"resets_at":null}}"#,
                     #"{"five_hour":{"utilization":20,"resets_at":"invalid"}}"#,
                     #"{"five_hour":{"utilization":20,"resets_at":"2026-10-12T14:30:00Z"}}"#,
                     #"{"five_hour":{"utilization":-1,"resets_at":"2026-10-12T18:30:00Z"}}"#,
                     #"{"five_hour":{"utilization":"20","resets_at":"2026-10-12T18:30:00Z"}}"#] {
            #expect(SimpleUsageFixture(body: Data(body.utf8)).parse() == nil)
        }
        var payload = try #require(JSONValue.parse(cacheFixturePayload)?.objectValue)
        payload["five_hour_bonus"] = .object(["utilization": .number(12), "resets_at": .string("2026-10-12T13:00:00Z")])
        payload["seven_day_opus"] = .object(["utilization": .number(.infinity), "resets_at": .string("2026-10-16T03:00:00Z")])
        let usable = try #require(ClaudeDesktopUsageCache.validatedPayload(.object(payload), now: cacheTestNow))
        #expect(usable["five_hour_bonus"] == nil)
        #expect(usable["seven_day_opus"] == nil)
        #expect(usable["five_hour"] != nil)
        // Percentages above 100 are valid provider observations.
        payload["five_hour"] = .object(["utilization": .number(130), "resets_at": .string("2026-10-12T18:30:00Z")])
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(payload), now: cacheTestNow)?["five_hour"]?["utilization"]?.numberValue == 130)
        #expect(ClaudeDesktopUsageCache.validatedPayload(usable, now: cacheTestNow.addingTimeInterval(7 * 86_400)) == nil)
    }

    @Test func nonemptyModernLimitsRemainAuthoritativeAfterExpiry() throws {
        var object = try #require(JSONValue.parse(cacheFixturePayload)?.objectValue)
        let expired: JSONValue = .object(["kind": .string("session"), "percent": .number(20), "resets_at": .string("2026-10-12T13:00:00Z")])
        object["limits"] = .array([expired])
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow) == nil)
        let current: JSONValue = .object(["kind": .string("weekly_all"), "percent": .number(30), "resets_at": .string("2026-10-16T03:00:00Z")])
        object["limits"] = .array([expired, current])
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow)?["limits"]?.arrayValue == [current])
        object["limits"] = .array([])
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow) != nil)
        object["limits"] = .string("invalid")
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow) == nil)
        object = ["limits": .array([current])]
        #expect(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow) != nil)
    }

    @Test func extraUsageCannotLeakAnElapsedOrUnknownReset() throws {
        let primary = try #require(JSONValue.parse(cacheFixturePayload)?.objectValue)
        for reset in [JSONValue.null, .string("invalid"), .string("2026-10-12T13:00:00Z"), .string("2026-10-16T03:00:00Z")] {
            var object = primary
            object["extra_usage"] = .object([
                "is_enabled": .bool(true), "used_credits": .string("1250"),
                "monthly_limit": .number(5000), "resets_at": reset
            ])
            let payload = try #require(ClaudeDesktopUsageCache.validatedPayload(.object(object), now: cacheTestNow))
            let snapshots = ClaudeUsageProvider.snapshots(from: payload, planType: nil, updatedAt: cacheTestNow)
            let extra = snapshots.first { $0.id == "claude_extra" }
            if reset == .string("2026-10-16T03:00:00Z") {
                #expect(extra?.usedPercent == 25)
                #expect(extra?.resetAt == LocalToolDates.parse("2026-10-16T03:00:00Z"))
            } else {
                #expect(extra == nil)
            }
            #expect(snapshots.contains { $0.id == "claude" })
        }
    }

    @Test func indexMustHaveAValidPayloadAndUniqueReachableHashes() {
        let fixture = SimpleUsageFixture()
        let index = simpleIndex(filenames: [fixture.filename])
        #expect(ClaudeDesktopUsageCache.indexHashes(index) == [UInt64(fixture.filename.prefix(16), radix: 16)!])
        #expect(ClaudeDesktopUsageCache.indexHashes(simpleIndex(filenames: [])) == [])
        #expect(ClaudeDesktopUsageCache.indexHashes(simpleIndex(filenames: [fixture.filename, fixture.filename])) == nil)
        #expect(ClaudeDesktopUsageCache.indexHashes(simpleIndex(filenames: [fixture.filename], packedInfo: 1 << 38)) == nil)
        for offset in [0, 4, 8, 16, 20, 40, index.count - 1] {
            var corrupt = index
            corrupt[offset] ^= 1
            #expect(ClaudeDesktopUsageCache.indexHashes(corrupt) == nil)
        }
        #expect(ClaudeDesktopUsageCache.indexHashes(Data(index.dropLast())) == nil)
        #expect(ClaudeDesktopUsageCache.indexHashes(index + Data([0])) == nil)
    }

    @Test func directoryReaderChoosesOnlyIndexedUsageFilesAndRejectsSymlinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-simple-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("index-dir"), withIntermediateDirectories: true)
        let older = SimpleUsageFixture(fetchedAt: cacheTestNow.addingTimeInterval(-20))
        let newer = SimpleUsageFixture(key: fixtureKey(query: "?skip_spend=1"), fetchedAt: cacheTestNow.addingTimeInterval(-10))
        try older.data.write(to: directory.appendingPathComponent(older.filename))
        try newer.data.write(to: directory.appendingPathComponent(newer.filename))
        let indexURL = directory.appendingPathComponent("index-dir/the-real-index")
        try simpleIndex(filenames: [older.filename, newer.filename]).write(to: indexURL)
        let reader = ClaudeDesktopUsageCache(homeDirectory: home)
        #expect(reader.latestUsage(organizationID: cacheOrganization, now: cacheTestNow)?.recordedAt == cacheTestNow.addingTimeInterval(-10))
        try simpleIndex(filenames: [older.filename]).write(to: indexURL)
        #expect(reader.latestUsage(organizationID: cacheOrganization, now: cacheTestNow)?.recordedAt == cacheTestNow.addingTimeInterval(-20))
        let olderURL = directory.appendingPathComponent(older.filename)
        try FileManager.default.removeItem(at: olderURL)
        let outside = home.appendingPathComponent("outside-cache-fixture")
        try older.data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: olderURL, withDestinationURL: outside)
        #expect(reader.latestUsage(organizationID: cacheOrganization, now: cacheTestNow) == nil)
        try Data("corrupt".utf8).write(to: indexURL)
        #expect(reader.latestUsage(organizationID: cacheOrganization, now: cacheTestNow) == nil)
    }
}
