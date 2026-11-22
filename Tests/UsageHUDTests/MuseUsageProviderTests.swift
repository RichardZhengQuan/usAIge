import Foundation
import Testing
@testable import UsageHUD

private let museTestNow = Date(timeIntervalSince1970: 1_794_636_900)

// Schema 1 from Muse Code 1.4.20, as documented by ClaudeBar.
private let museAllowance = """
    {
      "schemaVersion": 1,
      "allowance": {
        "tier": "Muse Code High Usage",
        "window": {"usedPercent": 1, "resetsAtMs": 1794651434000},
        "weekly": {"usedPercent": 7, "resetsAtMs": 1794787200000},
        "asOfMs": 1794636810548,
        "source": "mint"
      },
      "reason": null,
      "hint": null
    }
    """

@Test func museReadsSchemaOneAsOneBucketWithTwoWindows() async throws {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": museAllowance])
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry, now: { museTestNow })

    let snapshots = try await provider.refresh().snapshots

    try #require(snapshots.count == 1)
    let quota = snapshots[0]
    #expect(quota.id == "muse")
    #expect(quota.toolID == .muse)
    #expect(quota.displayName == "Muse Code")
    #expect(quota.planType == "Muse Code High Usage")
    #expect(quota.remainingPercent == 99)
    #expect(quota.windowDurationMinutes == nil)
    #expect(quota.resetAt == Date(timeIntervalSince1970: 1_794_651_434))
    #expect(quota.secondaryWindow?.remainingPercent == 93)
    #expect(quota.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(quota.secondaryWindow?.resetAt == Date(timeIntervalSince1970: 1_794_787_200))
    #expect(quota.updatedAt == museTestNow)
    #expect(await registry.status(for: .muse) == .connected)
    #expect(await runner.calls == [.init(name: "muse", arguments: ["usage", "--json"], environment: [:])])
}

@Test(arguments: [false, true])
func musePromotesTheOnlyWindowAndOmitsMissingMetadata(_ weekly: Bool) async throws {
    let key = weekly ? "weekly" : "window"
    let json = #"{"schemaVersion":1,"allowance":{"tier":"  ","\#(key)":{"usedPercent":17.25,"resetsAtMs":null}}}"#
    let provider = MuseUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["muse": json]))

    let quota = try #require(try await provider.refresh().snapshots.first)

    #expect(quota.usedPercent == 17.25)
    #expect(quota.windowDurationMinutes == (weekly ? 10_080 : nil))
    #expect(quota.resetAt == nil)
    #expect(quota.planType == nil)
    #expect(quota.secondaryWindow == nil)
}

@Test func museClampsBothReportedPercentages() async throws {
    let json = #"{"schemaVersion":1,"allowance":{"window":{"usedPercent":-1},"weekly":{"usedPercent":101}}}"#
    let provider = MuseUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["muse": json]))

    let quota = try #require(try await provider.refresh().snapshots.first)

    #expect(quota.usedPercent == 0)
    #expect(quota.secondaryWindow?.usedPercent == 100)
}

@Test func museKeepsWindowMetadataFromTheCurrentCommandAfterAReportedReset() async throws {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": museAllowance])
    let provider = MuseUsageProvider(runner: runner, now: { time })

    let quota = try #require(try await provider.refresh().snapshots.first)

    #expect(quota.updatedAt == time)
    #expect(quota.resetAt == Date(timeIntervalSince1970: 1_794_651_434))
    #expect(quota.secondaryWindow?.usedPercent == 7)
}

@Test func museDistinguishesAMissingCLIFromASignedOutCLI() async throws {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(["muse": [.notInstalled, .failure(.notSignedIn)]])
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .muse) == .notInstalled)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .muse) == .signedOut)
}

@Test(arguments: [("not_logged_in", Int32(0)), ("Session Expired", Int32(1))])
func museMapsAStructuredSignInFailureToCredentialExpired(_ reason: String, _ exitCode: Int32) async {
    let json = #"{"schemaVersion":1,"allowance":null,"reason":"\#(reason)","hint":"Sign in for private@example.test"}"#
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": json], exitCode: exitCode)
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.credentialExpired) { try await provider.refresh() }
    #expect(await registry.status(for: .muse) == .credentialExpired)
}

@Test func museExplainsAnUnsupportedSchema() async {
    let registry = await LocalToolStatusRegistry()
    let json = #"{"schemaVersion":2,"allowance":{"window":{"usedPercent":1}}}"#
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": json])
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .muse) == .failed("Update Muse Code; usAIge can't read this version's usage."))
}

@Test(arguments: [
    "not JSON",
    #"{"schemaVersion":1,"allowance":{"weekly":{"usedPercent":true}}}"#,
    #"{"schemaVersion":1,"allowance":{"window":{"usedPercent":12,"resetsAtMs":-1}}}"#,
    #"{"schemaVersion":1,"allowance":null,"reason":"private@example.test","hint":"sensitive output"}"#,
])
func museReportsMalformedOrUnavailableUsageWithoutLeakingOutput(_ output: String) async {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": output])
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .muse) == .failed("Run `muse usage` in Terminal to check your allowance."))
}

@Test func museRejectsAnAllowanceFromAFailedCommand() async {
    let runner = ScriptedLocalCommandRunner(stdout: ["muse": museAllowance], exitCode: 1)
    let provider = MuseUsageProvider(runner: runner)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
}

@Test func museReportsACommandTimeout() async {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(["muse": [.failure(.timedOut)]])
    let provider = MuseUsageProvider(runner: runner, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.timedOut) { try await provider.refresh() }
    #expect(await registry.status(for: .muse) == LocalToolStatus(error: LocalToolUsageError.timedOut))
}
