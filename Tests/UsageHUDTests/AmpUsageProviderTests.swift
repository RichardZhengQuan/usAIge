import Foundation
import Testing
@testable import UsageHUD

@Test func ampReadsCappedPoolsWithTheExactCommand() async throws {
    let output = """
    Signed in as reader@example.invalid (reader)
    \u{001B}[1mAmp  Free\u{001B}[0m :  $ 17.59 / $20 remaining (replenishes +$0.83/hour)
    Team: Credits:\t$40/$50  REMAINING - https://ampcode.com/settings
    Individual credits: $12.50 remaining
    """
    let command = ScriptedLocalCommandRunner(stdout: ["amp": output])
    let registry = await LocalToolStatusRegistry()
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let provider = AmpUsageProvider(command: command, statusRegistry: registry, now: { now })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["amp", "amp_team_credits"])
    #expect(snapshots.map(\.displayName) == ["Free", "Team: Credits"])
    let free = try #require(snapshots.first)
    let team = try #require(snapshots.last)
    #expect(abs(free.usedPercent - 12.05) < 0.0001)
    #expect(team.usedPercent == 20)
    for snapshot in snapshots {
        #expect(snapshot.toolID == .amp)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.planType == nil)
        #expect(snapshot.resetAt == nil)
        #expect(snapshot.windowDurationMinutes == nil)
        #expect(snapshot.secondaryWindow == nil)
    }
    #expect(await command.calls == [.init(name: "amp", arguments: ["usage", "--no-color"], environment: [:])])
    #expect(await registry.status(for: .amp) == .connected)
}

@Test func ampLeavesOutBalanceOnlyCredit() async throws {
    let command = ScriptedLocalCommandRunner(stdout: ["amp": "Individual credits: $50 remaining"])
    let registry = await LocalToolStatusRegistry()
    let provider = AmpUsageProvider(command: command, statusRegistry: registry)

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .amp) == .connected)
}

@Test func ampClampsPercentagesAndKeepsCollidingIDsUnique() throws {
    let output = """
    Free: $25/$20 remaining
    Team-credits: $-1/$10 remaining
    Team credits: $5/$10 remaining
    Team credits 2: $10/$10 remaining
    """
    let buckets = try #require(AmpUsageParser.buckets(from: output))

    #expect(buckets.map(\.limitID) == ["amp", "amp_team_credits", "amp_team_credits__2", "amp_team_credits_2"])
    #expect(buckets.map(\.usedPercent) == [0, 100, 50, 0])
}

@Test func ampReportsMissingCLIAsNotInstalled() async throws {
    let command = ScriptedLocalCommandRunner(["amp": [.notInstalled]])
    let registry = await LocalToolStatusRegistry()
    let provider = AmpUsageProvider(command: command, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .amp) == .notInstalled)
}

@Test(arguments: ["Run amp login to sign in.", "Free: $1/$0 remaining", "Unexpected usage format"])
func ampFailsWhenTheInstalledCLIProvidesNoValidCreditLine(output: String) async {
    let command = ScriptedLocalCommandRunner(stdout: ["amp": output])
    let registry = await LocalToolStatusRegistry()
    let provider = AmpUsageProvider(command: command, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .amp) == .failed("Couldn't find Amp credit lines. Sign in with `amp login`, or update usAIge."))
}

@Test func ampRejectsANonzeroExitEvenWithCreditLines() async {
    let command = ScriptedLocalCommandRunner(stdout: ["amp": "Free: $17.59/$20 remaining"], exitCode: 1)
    let registry = await LocalToolStatusRegistry()
    let provider = AmpUsageProvider(command: command, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .amp) == .failed("`amp usage` failed. Run it in Terminal to see why."))
}

@Test func ampReportsCommandTimeout() async {
    let command = ScriptedLocalCommandRunner(["amp": [.failure(.timedOut)]])
    let registry = await LocalToolStatusRegistry()
    let provider = AmpUsageProvider(command: command, statusRegistry: registry)

    await #expect(throws: LocalToolUsageError.timedOut) { try await provider.refresh() }
    #expect(await registry.status(for: .amp) == LocalToolStatus(error: LocalToolUsageError.timedOut))
}
