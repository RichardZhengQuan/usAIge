import Foundation
import Testing
@testable import UsageHUD

private let testNow = Date(timeIntervalSince1970: 1_789_300_000) // 2026-09-13

/// A throwaway home folder holding JetBrains IDE options folders.
private struct JetBrainsFixture {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("usaige-jetbrains-\(UUID().uuidString)", isDirectory: true)

    var directory: JetBrainsAIQuotaDirectory { JetBrainsAIQuotaDirectory(homeDirectory: home) }

    /// Writes `options/AIAssistantQuotaManager2.xml` for one IDE folder, such
    /// as `JetBrains/IntelliJIdea2026.2`, last changed `age` seconds ago.
    func saveQuota(_ xml: String, ide: String, age: TimeInterval = 0) throws {
        let file = try makeIDE(ide).appendingPathComponent("options/AIAssistantQuotaManager2.xml")
        try Data(xml.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
    }

    @discardableResult
    func makeIDE(_ ide: String) throws -> URL {
        let folder = home.appendingPathComponent("Library/Application Support/\(ide)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("options"),
            withIntermediateDirectories: true
        )
        return folder
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

/// The quota file as a JetBrains IDE writes it: each option's value is JSON
/// stored as XML-escaped attribute text, with numbers as strings.
private func quotaXML(
    type: String = "Available",
    current: String = "3000",
    maximum: String = "12000",
    refill: String? = "2026-10-01T08:30:00.250Z",
    duration: String = "PT720H"
) -> String {
    func escaped(_ json: String) -> String {
        json.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }
    let info = """
    {
      "type": "\(type)",
      "current": "\(current)",
      "maximum": "\(maximum)",
      "until": "2026-12-31T23:59:59Z",
      "tariffQuota": { "current": "\(current)", "maximum": "\(maximum)", "available": "0" }
    }
    """
    let nextRefill = refill.map { """
    {
      "type": "Known",
      "next": "\($0)",
      "tariff": { "amount": "\(maximum)", "duration": "\(duration)" }
    }
    """ } ?? """
    {
      "type": "Error",
      "exception": "",
      "previous": null
    }
    """
    return """
    <application>
      <component name="SomethingElse">
        <option name="quotaInfo" value="not the quota" />
      </component>
      <component name="AIAssistantQuotaManager2">
        <option name="nextRefill" value="\(escaped(nextRefill))" />
        <option name="quotaInfo" value="\(escaped(info))" />
      </component>
    </application>
    """
}

@Test func jetBrainsAIReadsCreditsLeftFromTheIDEQuotaFile() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(current: "3000", maximum: "12000"), ide: "JetBrains/IntelliJIdea2026.2")
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    let snapshots = try await provider.refresh().snapshots

    let credits = try #require(snapshots.first)
    #expect(snapshots.count == 1)
    #expect(credits.id == "jetbrains_ai")
    #expect(credits.toolID == .jetBrainsAI)
    #expect(credits.displayName == "AI credits")
    #expect(credits.remainingPercent == 75)
    #expect(credits.windowDurationMinutes == 43_200)
    #expect(credits.typeTag == "30D")
    let refill = try #require(LocalToolDates.parse("2026-10-01T08:30:00.250Z"))
    #expect(credits.resetAt == refill)
    #expect(credits.planType == nil)
    #expect(await registry.status(for: .jetBrainsAI) == .connected)
}

@Test func jetBrainsAIReadsTheIDEThatSavedItsQuotaLastIncludingAndroidStudio() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(current: "1000"), ide: "JetBrains/PyCharm2026.1", age: 86_400)
    try fixture.saveQuota(quotaXML(current: "6000"), ide: "Google/AndroidStudio2026.1", age: 60)
    try fixture.saveQuota(quotaXML(current: "9000"), ide: "JetBrains/GoLand2026.2", age: 3_600)
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, now: { testNow })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.remainingPercent) == [50])
}

@Test func jetBrainsAIShowsCreditsWithoutAResetWhenTheIDESavedNoRefill() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(current: "0", refill: nil), ide: "JetBrains/WebStorm2026.2")
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, now: { testNow })

    let credits = try #require(try await provider.refresh().snapshots.first)

    #expect(credits.remainingPercent == 100)
    #expect(credits.resetAt == nil)
    #expect(credits.windowDurationMinutes == nil)
}

@Test func jetBrainsAIClampsCreditsSpentPastTheAllowance() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(current: "13500.5", maximum: "12000"), ide: "JetBrains/Rider2026.2")
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, now: { testNow })

    let credits = try #require(try await provider.refresh().snapshots.first)

    #expect(credits.usedPercent == 100)
    #expect(credits.remainingPercent == 0)
}

@Test func jetBrainsAILeavesOutCreditsThatHaveRefilledSinceTheIDESavedThem() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(refill: "2026-09-01T00:00:00Z"), ide: "JetBrains/IntelliJIdea2026.2")
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    let result = try await provider.refresh()

    #expect(result == .authenticated([]))
    guard case let .failed(message) = await registry.status(for: .jetBrainsAI) else {
        Issue.record("Expected a failed status")
        return
    }
    #expect(message.contains("refilled"))
}

@Test func jetBrainsAIExplainsAnIDEWithoutAnAIQuota() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(type: "Unknown"), ide: "JetBrains/IntelliJIdea2026.2")
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .jetBrainsAI) == .signedOut)
}

@Test func jetBrainsAIReportsAnIDEThatFailedToGetTheQuota() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(quotaXML(type: "Error"), ide: "JetBrains/IntelliJIdea2026.2")
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    #expect(try await provider.refresh() == .authenticated([]))
    guard case let .failed(message) = await registry.status(for: .jetBrainsAI) else {
        Issue.record("Expected a failed status")
        return
    }
    #expect(message.contains("AI Assistant"))
}

@Test func jetBrainsAITellsNotInstalledFromNotSignedIn() async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .jetBrainsAI) == .notInstalled)

    try fixture.makeIDE("JetBrains/CLion2026.2")
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .jetBrainsAI) == .signedOut)
}

@Test(arguments: [
    "not xml at all",
    "<application/>",
    #"<application><component name="AIAssistantQuotaManager2"><option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;5&quot;,&quot;maximum&quot;:&quot;0&quot;}"/></component></application>"#,
])
func jetBrainsAIKeepsTheLastReadingWhenTheFileCannotBeRead(_ xml: String) async throws {
    let fixture = JetBrainsFixture()
    defer { fixture.remove() }
    try fixture.saveQuota(xml, ide: "JetBrains/IntelliJIdea2026.2")
    let registry = await LocalToolStatusRegistry()
    let provider = JetBrainsAIUsageProvider(source: fixture.directory, statusRegistry: registry, now: { testNow })

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await provider.refreshLocalUsage() == nil)
    guard case .failed = await registry.status(for: .jetBrainsAI) else {
        Issue.record("Expected a failed status")
        return
    }
}

@Test func jetBrainsAIReadsISODurationsWithoutGuessingCalendarUnits() {
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("PT720H") == 43_200)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("P30D") == 43_200)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("P1DT12H") == 2_160)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("PT90M") == 90)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("P1M") == nil)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("P1Y") == nil)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("PT30S") == nil)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("720 hours") == nil)
    #expect(JetBrainsAIQuotaParser.isoDurationMinutes("P") == nil)
}
