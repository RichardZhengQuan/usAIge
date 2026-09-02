import AppKit
import Foundation

/// Locates the Claude Code CLI the same way the version resolver does.
enum ClaudeCodeCLI {
    static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.local/bin/claude")
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        for directory in environment["PATH"]?.split(separator: ":") ?? [] {
            candidates.append("\(directory)/claude")
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

/// A running `claude auth login` process: its merged output as it arrives,
/// a way to answer its code prompt, and its exit status.
protocol ClaudeLoginProcess: Sendable {
    func start() async throws -> AsyncStream<String>
    func write(_ text: String) async throws
    func waitForExit() async -> Int32
    func terminate() async
}

actor ClaudeCLILoginProcess: ClaudeLoginProcess {
    private let executableURL: URL
    private var process: Process?
    private var input: Pipe?
    private var readerTask: Task<Void, Never>?
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start() async throws -> AsyncStream<String> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["auth", "login", "--claudeai"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.recordExit(status) }
        }
        try process.run()
        self.process = process
        self.input = input

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let handle = output.fileHandleForReading
        readerTask = Task.detached {
            while !Task.isCancelled {
                let received = autoreleasepool { () -> Bool in
                    let data = handle.availableData
                    guard !data.isEmpty else { return false }
                    if let text = String(data: data, encoding: .utf8) { continuation.yield(text) }
                    return true
                }
                if !received { break }
            }
            continuation.finish()
        }
        return stream
    }

    func write(_ text: String) async throws {
        guard let input else { throw LocalToolUsageError.notInstalled }
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func waitForExit() async -> Int32 {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    func terminate() async {
        readerTask?.cancel()
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
    }

    private func recordExit(_ status: Int32) {
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume(returning: status) }
    }
}

/// Drives Claude Code's own `claude auth login --claudeai` from Settings:
/// starts the CLI, opens the sign-in page it prints, and passes back the
/// code the user pastes. Claude Code stores the resulting plan sign-in in
/// its Keychain item; usAIge never sees or keeps the credential itself.
@MainActor
final class ClaudeSignInSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case waitingForCode(URL)
        case submitting
        case succeeded
        case failed(String)
        case unavailable
    }

    @Published private(set) var state: State = .idle
    @Published var code = ""
    var onSucceeded: (() -> Void)?

    private let makeProcess: @MainActor () -> (any ClaudeLoginProcess)?
    private let openURL: @MainActor (URL) -> Void
    private let timeout: TimeInterval
    private var process: (any ClaudeLoginProcess)?
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var transcript = ""

    init(
        makeProcess: @escaping @MainActor () -> (any ClaudeLoginProcess)? = {
            ClaudeCodeCLI.executableURL().map { ClaudeCLILoginProcess(executableURL: $0) }
        },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        timeout: TimeInterval = 600
    ) {
        self.makeProcess = makeProcess
        self.openURL = openURL
        self.timeout = timeout
    }

    var isActive: Bool {
        switch state {
        case .starting, .waitingForCode, .submitting: true
        default: false
        }
    }

    func start() {
        guard !isActive else { return }
        guard let process = makeProcess() else {
            state = .unavailable
            return
        }
        self.process = process
        transcript = ""
        code = ""
        state = .starting
        task = Task { [weak self] in
            do {
                let output = try await process.start()
                for await chunk in output {
                    guard !Task.isCancelled else { return }
                    self?.consume(chunk)
                }
                let status = await process.waitForExit()
                guard !Task.isCancelled else { return }
                self?.finish(status: status)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, self?.timeout ?? 600) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isActive else { return }
            await self.process?.terminate()
            self.task?.cancel()
            self.state = .failed("Timed out waiting for the sign-in to finish.")
        }
    }

    func submit() {
        guard case .waitingForCode = state else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .submitting
        let process = self.process
        Task {
            do { try await process?.write(trimmed + "\n") }
            catch { self.state = .failed(error.localizedDescription) }
        }
    }

    func openSignInPage() {
        if case let .waitingForCode(url) = state { openURL(url) }
    }

    func cancel() {
        task?.cancel()
        timeoutTask?.cancel()
        let process = self.process
        Task { await process?.terminate() }
        self.process = nil
        state = .idle
    }

    func reset() {
        guard !isActive else { return }
        state = .idle
        code = ""
    }

    /// The sign-in page the CLI prints after "visit:".
    nonisolated static func signInURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard token.hasPrefix("https://"), token.contains("oauth/authorize") else { continue }
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)\"'"))
            if let url = URL(string: cleaned) { return url }
        }
        return nil
    }

    private func consume(_ chunk: String) {
        transcript += chunk
        if case .starting = state, let url = Self.signInURL(in: transcript) {
            state = .waitingForCode(url)
            openURL(url)
        }
    }

    private func finish(status: Int32) {
        timeoutTask?.cancel()
        process = nil
        if status == 0 {
            state = .succeeded
            code = ""
            onSucceeded?()
        } else {
            // The CLI prints its verdict right after the code prompt, on the
            // same line when input comes from a pipe, so strip that prompt
            // before picking the last message.
            let lastLine = transcript
                .split(whereSeparator: \.isNewline)
                .compactMap { raw -> String? in
                    var line = raw.trimmingCharacters(in: .whitespaces)
                    if let range = line.range(of: "Paste code here if prompted >") {
                        line = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    }
                    return line.isEmpty ? nil : line
                }
                .last
            state = .failed(lastLine ?? "Claude Code exited with status \(status).")
        }
    }
}
