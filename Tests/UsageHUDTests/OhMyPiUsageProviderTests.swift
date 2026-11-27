import Foundation
import Testing
@testable import UsageHUD

private let ohMyPiTestNow = Date(timeIntervalSince1970: 1_800_000_000)

// Modeled on the report shape documented for omp v16.4.6 and v18.14.
private let ohMyPiAccounts = """
    {
      "generatedAt": 1783869272381,
      "reports": [
        {
          "provider": "openai-codex",
          "fetchedAt": 1783869167737,
          "metadata": {"email": "private@example.test", "accountId": "acct-private-1", "planType": "pro"},
          "limits": [
            {
              "scope": {"windowId": "7d"},
              "window": {"durationMs": 604800000, "resetsAt": 1784354613000},
              "amount": {"remainingFraction": 0.375, "unit": "percent"}
            },
            {
              "scope": {"windowId": "5h", "accountId": "acct-private-1"},
              "window": {"durationMs": 18000000, "resetsAt": 1783887168000},
              "amount": {"usedFraction": 0.25, "unit": "percent"}
            }
          ]
        },
        {
          "provider": "openai-codex",
          "metadata": {"email": "other@example.test", "tag": "private-team"},
          "limits": [
            {"scope": {"windowId": "5h"}, "amount": {"usedFraction": 0.5}}
          ]
        }
      ],
      "accountsWithoutUsage": [{"provider": "ollama", "type": "api_key"}],
      "disabledCredentials": [{"provider": "anthropic", "email": "signed-out@example.test"}]
    }
    """

@Test func ohMyPiDoesNotRunTheCommandBeforeOptIn() async throws {
    let runner = ScriptedLocalCommandRunner(stdout: ["omp": ohMyPiAccounts])
    let registry = await LocalToolStatusRegistry()
    let provider = OhMyPiUsageProvider(runner: runner, isOptedIn: { false }, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .ohMyPi) == .optInRequired)
    #expect(await runner.calls.isEmpty)
}

@Test func ohMyPiPairsWindowsByAccountAndKeepsAccountDetailsPrivate() async throws {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(stdout: ["omp": "Synced accounts\n\(ohMyPiAccounts)\nDone."])
    let provider = OhMyPiUsageProvider(runner: runner, isOptedIn: { true }, statusRegistry: registry, now: { ohMyPiTestNow })

    let snapshots = try await provider.refresh().snapshots

    try #require(snapshots.count == 2)
    #expect(snapshots.map(\.id) == ["ohMyPi_openai_codex_1", "ohMyPi_openai_codex_2"])
    #expect(snapshots.map(\.displayName) == ["Codex", "Codex 2"])
    #expect(snapshots.allSatisfy { $0.toolID == .ohMyPi && $0.updatedAt == ohMyPiTestNow })
    let first = snapshots[0]
    #expect(first.planType == "pro")
    #expect(first.usedPercent == 25)
    #expect(first.windowDurationMinutes == 300)
    // The current command returned these resets even though its upstream capture predates this refresh.
    #expect(first.resetAt == Date(timeIntervalSince1970: 1_783_887_168))
    #expect(first.secondaryWindow?.remainingPercent == 37.5)
    #expect(first.secondaryWindow?.windowDurationMinutes == 10_080)
    #expect(first.secondaryWindow?.resetAt == Date(timeIntervalSince1970: 1_784_354_613))
    let second = snapshots[1]
    #expect(second.usedPercent == 50)
    #expect(second.windowDurationMinutes == nil)
    #expect(second.resetAt == nil)
    #expect(second.planType == nil)
    #expect(second.secondaryWindow == nil)
    #expect(await registry.status(for: .ohMyPi) == .connected)
    #expect(await runner.calls == [.init(name: "omp", arguments: ["usage", "--json"], environment: [:])])
}

@Test func ohMyPiKeepsDifferentModelsAndMetersInSeparatePools() async throws {
    let json = """
        {"reports":[
          {"provider":"openai-codex","limits":[
            {"scope":{"windowId":"5h"},"amount":{"usedFraction":0.25}},
            {"scope":{"windowId":"5h","tier":"spark"},"amount":{"usedFraction":0.5}},
            {"scope":{"windowId":"7d"},"amount":{"usedFraction":0.75}}
          ]},
          {"provider":"zai","limits":[
            {"scope":{"windowId":"5h"},"amount":{"usedFraction":0.125,"unit":"tokens"}},
            {"scope":{"windowId":"7d"},"amount":{"usedFraction":0.375,"unit":"requests"}}
          ]}
        ]}
        """
    let provider = OhMyPiUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["omp": json]), isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["ohMyPi_openai_codex_1", "ohMyPi_openai_codex_1_pool_2", "ohMyPi_zai_1", "ohMyPi_zai_1_pool_2"])
    #expect(snapshots.map(\.displayName) == ["Codex", "Codex", "Z.ai", "Z.ai"])
    #expect(snapshots.map(\.usedPercent) == [25, 50, 37.5, 12.5])
    #expect(snapshots.compactMap { $0.secondaryWindow?.usedPercent } == [75])
    #expect(snapshots.allSatisfy { $0.planType == nil })
}

@Test func ohMyPiKeepsPoolIDsWhenLimitRowsReorder() async throws {
    let limits = [
        #"{"scope":{"windowId":"5h"},"amount":{"usedFraction":0.25}}"#,
        #"{"scope":{"windowId":"7d"},"amount":{"usedFraction":0.75}}"#,
        #"{"scope":{"windowId":"5h","tier":"spark"},"amount":{"usedFraction":0.5}}"#,
    ]
    let replies = [limits, Array(limits.reversed())].map { limits in
        let report = #"{"reports":[{"provider":"openai-codex","limits":[\#(limits.joined(separator: ","))]}]}"#
        return ScriptedLocalCommandRunner.Reply.output(.init(exitCode: 0, standardOutput: Data(report.utf8)))
    }
    let runner = ScriptedLocalCommandRunner(["omp": replies])
    let provider = OhMyPiUsageProvider(runner: runner, isOptedIn: { true }, now: { ohMyPiTestNow })

    let first = try await provider.refresh().snapshots
    #expect(first.map(\.id) == ["ohMyPi_openai_codex_1", "ohMyPi_openai_codex_1_pool_2"])
    #expect(try await provider.refresh().snapshots == first)
}

@Test func ohMyPiShowsASharedPoolOnlyOnceAcrossModels() async throws {
    let json = """
        {"reports":[{"provider":"example-provider","limits":[
          {"label":"Gemini","scope":{"windowId":"5h"},"amount":{"usedFraction":0.125}},
          {"label":"Gemini","scope":{"windowId":"weekly"},"amount":{"usedFraction":0.25}},
          {"label":"Claude","scope":{"windowId":"weekly","sharedGroup":"3p-weekly:weekly"},"amount":{"usedFraction":0.5}},
          {"label":"GPT","scope":{"windowId":"weekly","sharedGroup":"3p-weekly:weekly"},"amount":{"usedFraction":0.5}},
          {"label":"Claude","scope":{"windowId":"5h","sharedGroup":"3p-5h:5h"},"amount":{"usedFraction":0.375}},
          {"label":"GPT","scope":{"windowId":"5h","sharedGroup":"3p-5h:5h"},"amount":{"usedFraction":0.375}}
        ]}]}
        """
    let provider = OhMyPiUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["omp": json]), isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["ohMyPi_other_1", "ohMyPi_other_1_pool_2"])
    #expect(snapshots.map(\.usedPercent) == [12.5, 37.5])
    #expect(snapshots.compactMap { $0.secondaryWindow?.usedPercent } == [25, 50])
    #expect(snapshots.allSatisfy { $0.windowDurationMinutes == nil && $0.secondaryWindow?.windowDurationMinutes == nil })
}

@Test func ohMyPiKeepsKimisWeeklySummaryWithoutRepeatingTheAggregate() async throws {
    let json = """
        {"reports":[{"provider":"kimi-code","limits":[
          {"scope":{"windowId":"7d"},"amount":{"usedFraction":0.125,"unit":"unknown"}},
          {"scope":{"windowId":"5h"},"window":{"durationMs":18000000},"amount":{"usedFraction":0.25,"unit":"unknown"}},
          {"scope":{"windowId":"limit_7d"},"amount":{"usedFraction":0.375,"unit":"percent"}}
        ]}]}
        """
    let provider = OhMyPiUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["omp": json]), isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    try #require(snapshots.count == 1)
    let quota = snapshots[0]
    #expect(quota.id == "ohMyPi_kimi_code_1")
    #expect(quota.displayName == "Kimi")
    #expect(quota.usedPercent == 25)
    #expect(quota.secondaryWindow?.usedPercent == 12.5)
    #expect(quota.secondaryWindow?.windowDurationMinutes == nil)
}

@Test func ohMyPiUsesTheDollarCapAndOmitsUncappedSpendAndBalances() async throws {
    let json = """
        {"reports":[{"provider":"cursor","limits":[
          {"amount":{"unit":"USD","used":125,"limit":500,"usedFraction":0.5}},
          {"amount":{"unit":"usd","remaining":75,"limit":100}},
          {"amount":{"unit":"usd","used":1000,"limit":100}},
          {"amount":{"unit":"usd","used":33,"usedFraction":0.5}},
          {"amount":{"unit":"credits","remaining":94}}
        ]}]}
        """
    let provider = OhMyPiUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["omp": json]), isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.usedPercent) == [25, 25, 100])
    #expect(Set(snapshots.map(\.id)).count == 3)
    #expect(snapshots.allSatisfy { $0.secondaryWindow == nil && $0.windowDurationMinutes == nil })
}

@Test func ohMyPiSkipsGoogleReportsAndKeepsOtherAccountOrdinals() async throws {
    let json = """
        {"reports":[
          {"provider":"anthropic","limits":[]},
          {"provider":"google-antigravity","limits":[{"amount":{"usedFraction":0.75}}]},
          {"provider":"anthropic","limits":[{"amount":{"usedFraction":0.5}}]},
          {"provider":"private-account-tag","limits":[{"label":"private@example.test","amount":{"usedFraction":0.25}}]},
          {"provider":"google-gemini-cli","limits":[{"amount":{"usedFraction":0.125}}]},
          {"provider":"another-private-tag","limits":[{"amount":{"usedFraction":0.375}}]}
        ]}
        """
    let provider = OhMyPiUsageProvider(runner: ScriptedLocalCommandRunner(stdout: ["omp": json]), isOptedIn: { true })

    let snapshots = try await provider.refresh().snapshots

    #expect(snapshots.map(\.id) == ["ohMyPi_anthropic_2", "ohMyPi_other_1", "ohMyPi_other_2"])
    #expect(snapshots.map(\.displayName) == ["Claude 2", "Other provider", "Other provider 2"])
}

@Test func ohMyPiDistinguishesAMissingCLIFromAnEmptyAccountList() async throws {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(["omp": [
        .notInstalled,
        .output(.init(exitCode: 0, standardOutput: Data(#"{"reports":[]}"#.utf8))),
    ]])
    let provider = OhMyPiUsageProvider(runner: runner, isOptedIn: { true }, statusRegistry: registry)

    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .ohMyPi) == .notInstalled)
    #expect(try await provider.refresh() == .signedOut)
    #expect(await registry.status(for: .ohMyPi) == .signedOut)
}

@Test func ohMyPiAsksForSignInWhenUpstreamCredentialsAreDisabled() async throws {
    let json = #"{"reports":[],"disabledCredentials":[{"provider":"anthropic","email":"private@example.test","cause":"Private account error"}]}"#
    let registry = await LocalToolStatusRegistry()
    let provider = OhMyPiUsageProvider(
        runner: ScriptedLocalCommandRunner(stdout: ["omp": json]),
        isOptedIn: { true },
        statusRegistry: registry
    )

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .ohMyPi) == .failed("Sign in again in Oh My Pi (`omp`)."))
}

@Test(arguments: [
    #"{"reports":[],"accountsWithoutUsage":[{"provider":"kimi-code"}]}"#,
    #"{"reports":[{"provider":"google-antigravity","limits":[{"amount":{"usedFraction":0.5}}]},{"provider":"google-gemini-cli","limits":[{"amount":{"usedFraction":0.25}}]}]}"#,
    #"{"reports":[],"disabledCredentials":[{"provider":"google-gemini-cli"}]}"#,
    #"{"reports":[{"provider":"openai-codex","limits":[],"resetCredits":{"availableCount":2},"notes":["private warning"]}],"dailyUsage":{"usedFraction":0.9}}"#,
])
func ohMyPiReportsConnectedAccountsWithoutQuota(_ json: String) async throws {
    let registry = await LocalToolStatusRegistry()
    let provider = OhMyPiUsageProvider(
        runner: ScriptedLocalCommandRunner(stdout: ["omp": json]),
        isOptedIn: { true },
        statusRegistry: registry
    )

    #expect(try await provider.refresh() == .authenticated([]))
    #expect(await registry.status(for: .ohMyPi) == .connected)
}

@Test(arguments: ["{broken", #"[{"reports":[]}]"#, #"{"reports":[{"limits":[]}]}"#])
func ohMyPiRejectsMalformedReportsWithoutLeakingOutput(_ output: String) async {
    let registry = await LocalToolStatusRegistry()
    let provider = OhMyPiUsageProvider(
        runner: ScriptedLocalCommandRunner(stdout: ["omp": output]),
        isOptedIn: { true },
        statusRegistry: registry
    )

    await #expect(throws: LocalToolUsageError.invalidResponse) { try await provider.refresh() }
    #expect(await registry.status(for: .ohMyPi) == .failed("Run `omp usage` in Terminal to check the usage report."))
}

@Test func ohMyPiKeepsTheLastReadingAfterMalformedOutputOrCommandFailure() async throws {
    let registry = await LocalToolStatusRegistry()
    let runner = ScriptedLocalCommandRunner(["omp": [
        .output(.init(exitCode: 0, standardOutput: Data(ohMyPiAccounts.utf8))),
        .output(.init(exitCode: 0, standardOutput: Data("{broken".utf8))),
        .output(.init(exitCode: 1, standardOutput: Data("private@example.test".utf8))),
    ]])
    let provider = CompositeUsageProvider(
        local: ScriptedUsageProvider(result: .signedOut),
        throttled: [OhMyPiUsageProvider(runner: runner, isOptedIn: { true }, statusRegistry: registry, now: { ohMyPiTestNow })],
        remote: ScriptedUsageProvider(result: .signedOut)
    )

    let lastGood = try await provider.refresh().snapshots
    #expect(lastGood.count == 2)
    #expect(try await provider.refresh().snapshots == lastGood)
    #expect(try await provider.refresh().snapshots == lastGood)
    #expect(await registry.status(for: .ohMyPi) == .failed("Run `omp usage` in Terminal to check the usage report."))
}
