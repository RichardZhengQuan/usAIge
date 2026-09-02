import Foundation
import Testing
@testable import UsageHUD

/// Scripted stand-in for `claude auth login`: emits output on demand,
/// records what the session writes back, and exits when told to.
actor FakeClaudeLoginProcess: ClaudeLoginProcess {
    private var continuation: AsyncStream<String>.Continuation?
    private var pending: [String] = []
    private var exit: CheckedContinuation<Int32, Never>?
    private var exitStatus: Int32?
    private(set) var writes: [String] = []
    private(set) var terminated = false
    private(set) var started = false

    func start() async throws -> AsyncStream<String> {
        started = true
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.continuation = continuation
        pending.forEach { continuation.yield($0) }
        pending.removeAll()
        return stream
    }

    func write(_ text: String) async throws { writes.append(text) }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exit = $0 }
    }

    func terminate() async { terminated = true }

    func emit(_ text: String) {
        if let continuation { continuation.yield(text) } else { pending.append(text) }
    }

    func finish(status: Int32) {
        continuation?.finish()
        exitStatus = status
        exit?.resume(returning: status)
        exit = nil
    }
}

private let sampleOutput = """
Opening browser to sign in…
If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=abc&scope=user%3Aprofile
Paste code here if prompted > 
"""

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Test func signInURLIsExtractedFromTheCLIOutput() {
    let url = ClaudeSignInSession.signInURL(in: sampleOutput)
    #expect(url?.host == "claude.com")
    #expect(url?.path == "/cai/oauth/authorize")
    #expect(ClaudeSignInSession.signInURL(in: "Opening browser to sign in…\n") == nil)
    #expect(ClaudeSignInSession.signInURL(in: "see https://example.com/docs first") == nil)
}

@MainActor
@Test func signInFlowOpensThePageSubmitsTheCodeAndReportsSuccess() async throws {
    let process = FakeClaudeLoginProcess()
    let opened = TestClockBox(Date(timeIntervalSince1970: 0))
    let session = ClaudeSignInSession(
        makeProcess: { process },
        openURL: { _ in opened.now = opened.now.addingTimeInterval(1) },
        timeout: 30
    )
    var succeeded = false
    session.onSucceeded = { succeeded = true }

    session.start()
    #expect(session.state == .starting)
    await waitUntil { await process.started }
    await process.emit(sampleOutput)
    await waitUntil { if case .waitingForCode = session.state { return true } else { return false } }
    guard case let .waitingForCode(url) = session.state else { Issue.record("expected waitingForCode"); return }
    #expect(url.host == "claude.com")
    #expect(opened.now == Date(timeIntervalSince1970: 1))

    session.code = "  abc#123  "
    session.submit()
    #expect(session.state == .submitting)
    await waitUntil { false == (await process.writes.isEmpty) }
    #expect(await process.writes == ["abc#123\n"])

    await process.emit("Logged in as someone@example.com\n")
    await process.finish(status: 0)
    await waitUntil { session.state == .succeeded }
    #expect(session.state == .succeeded)
    #expect(succeeded)
    #expect(session.code.isEmpty)
}

@MainActor
@Test func signInFlowReportsTheCLIsFailureLine() async throws {
    let process = FakeClaudeLoginProcess()
    let session = ClaudeSignInSession(makeProcess: { process }, openURL: { _ in }, timeout: 30)

    session.start()
    await waitUntil { await process.started }
    await process.emit(sampleOutput)
    await waitUntil { if case .waitingForCode = session.state { return true } else { return false } }
    await process.emit("Invalid code, please try again\n")
    await process.finish(status: 1)
    await waitUntil { if case .failed = session.state { return true } else { return false } }

    #expect(session.state == .failed("Invalid code, please try again"))
    session.reset()
    #expect(session.state == .idle)
}

@MainActor
@Test func signInFlowIsUnavailableWithoutTheCLIAndCanBeCancelled() async throws {
    let missing = ClaudeSignInSession(makeProcess: { nil }, openURL: { _ in })
    missing.start()
    #expect(missing.state == .unavailable)

    let process = FakeClaudeLoginProcess()
    let session = ClaudeSignInSession(makeProcess: { process }, openURL: { _ in }, timeout: 30)
    session.start()
    await waitUntil { await process.started }
    session.cancel()
    #expect(session.state == .idle)
    await waitUntil { await process.terminated }
    #expect(await process.terminated)
}

@Test func claudeCLIIsFoundInTheStandardInstallLocations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usaige-claude-cli-\(UUID().uuidString)")
    let bin = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let binary = bin.appendingPathComponent("claude")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(ClaudeCodeCLI.executableURL(environment: ["HOME": root.path, "PATH": ""]) == binary)
    #expect(ClaudeCodeCLI.executableURL(environment: ["HOME": "/nonexistent", "PATH": ""]) == nil)
}

@MainActor
@Test func signInButtonIsOfferedOnlyWhenNoPlanSignInIsReadable() {
    #expect(HUDSettingsView.offersClaudeSignIn(status: .signedOut))
    #expect(HUDSettingsView.offersClaudeSignIn(status: .apiKeyOnly))
    #expect(HUDSettingsView.offersClaudeSignIn(status: .credentialExpired))
    #expect(HUDSettingsView.offersClaudeSignIn(status: .disabled))
    #expect(!HUDSettingsView.offersClaudeSignIn(status: .connected))
    #expect(!HUDSettingsView.offersClaudeSignIn(status: .rateLimited))
}
