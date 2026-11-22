import Foundation
import Testing
@testable import UsageHUD

@Test func localCommandsAreFoundInInstallerFoldersMissingFromTheAppPath() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-cmd-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let tool = bin.appendingPathComponent("usaige-fake-cli")
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]

    #expect(LocalCommandLocator.executableURL(named: "usaige-fake-cli", environment: environment)?.path == tool.path)
    #expect(LocalCommandLocator.executableURL(named: "usaige-missing-cli", environment: environment) == nil)
    #expect(LocalCommandLocator.executableURL(named: "../bin/sh", environment: environment) == nil)
    let directories = LocalCommandLocator.searchDirectories(environment: environment)
    #expect(directories.prefix(2) == ["/usr/bin", "/bin"])
    #expect(directories.contains("/opt/homebrew/bin"))
    #expect(directories.contains("\(home.path)/.bun/bin"))
    #expect(Set(directories).count == directories.count)
}

@Test func localCommandsReturnStandardOutputAndExitCode() async throws {
    let runner = LocalCommandRunner(environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()])

    let output = try #require(try await runner.run(
        "sh",
        arguments: ["-c", "printf '{\"ok\":true}'; echo 'account@example.com' >&2; exit 3"],
        timeout: 60,
        environment: ["USAIGE_EXTRA": "1"]
    ))

    #expect(output.exitCode == 3)
    #expect(output.text == #"{"ok":true}"#)
    #expect(try await runner.run("usaige-not-a-real-cli", arguments: []) == nil)
}

@Test func localCommandsSeeTheExtendedPathAndOverrides() async throws {
    let runner = LocalCommandRunner(environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/usaige-home"])

    let output = try #require(try await runner.run(
        "sh", arguments: ["-c", "printf '%s|%s|%s' \"$PATH\" \"$TERM\" \"$USAIGE_EXTRA\""],
        timeout: 60, environment: ["USAIGE_EXTRA": "yes"]
    ))

    let parts = output.text.split(separator: "|").map(String.init)
    #expect(parts.count == 3)
    #expect(parts[0].contains("/opt/homebrew/bin"))
    #expect(parts[0].contains("/tmp/usaige-home/.local/bin"))
    #expect(parts[1] == "dumb")
    #expect(parts[2] == "yes")
}

@Test func localCommandsStopAtTheirTimeout() async throws {
    let runner = LocalCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
    let started = Date()

    await #expect(throws: LocalToolUsageError.timedOut) {
        try await runner.run("sleep", arguments: ["120"], timeout: 0.3)
    }
    // Only that it stopped long before the command would have ended: a busy
    // CI runner can take many seconds just to start a process.
    #expect(Date().timeIntervalSince(started) < 90)
}

@Test func localCommandsRefuseOutputLargerThanAUsageReport() async throws {
    let runner = LocalCommandRunner(environment: ["PATH": "/usr/bin:/bin"], maximumOutputBytes: 4_096)

    await #expect(throws: LocalToolUsageError.invalidResponse) {
        try await runner.run("yes", arguments: [], timeout: 60)
    }
}

@Test func optInToolsReadNothingUntilTurnedOn() throws {
    let defaults = try #require(UserDefaults(suiteName: "usaige.optin.\(UUID().uuidString)"))
    #expect(LocalToolOptIn.optInToolIDs == [.copilot])
    #expect(!LocalToolOptIn.isEnabled(.copilot, defaults: defaults))
    LocalToolOptIn.setEnabled(true, for: .copilot, defaults: defaults)
    #expect(LocalToolOptIn.isEnabled(.copilot, defaults: defaults))
    #expect(LocalToolOptIn.key(for: .copilot) == "usageHUD.optIn.copilot.v1")

    let copilot = try #require(LocalToolGuidance.supported.first { $0.id == .copilot })
    let off = copilot.presentation(for: .optInRequired)
    #expect(off.text.hasPrefix("Off."))
    #expect(off.text.contains("GitHub CLI"))
    #expect(!off.isProblem)
}

@Test func aiToolsListsNewerToolsOnlyOnceTheyAreFoundOnThisMac() {
    let statuses: [AIToolID: LocalToolStatus] = [
        .jetBrainsAI: .connected,
        .windsurf: .notInstalled,
        .kiro: .signedOut,
        .amp: .unknown,
        .grok: .notInstalled,
        .copilot: .optInRequired,
        .openCodeGo: .credentialExpired,
    ]
    let order: [AIToolID] = [.kiro, .claude, .chatGPT]

    let listed = LocalToolGuidance.listed(order: order) { statuses[$0] ?? .notInstalled }.map(\.id)

    // The user's order first, then the rest in catalog order.
    #expect(listed == [.kiro, .claude, .chatGPT, .cursor, .grok, .jetBrainsAI, .copilot, .openCodeGo])
    #expect(LocalToolGuidance.alwaysListed == [.chatGPT, .claude, .cursor, .grok, .copilot])
}
