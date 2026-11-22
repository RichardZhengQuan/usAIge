import Foundation

/// What a tool's own command-line app printed, and how it exited.
struct LocalCommandOutput: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data

    var text: String { String(decoding: standardOutput, as: UTF8.self) }
}

/// Runs the command-line apps that report their own usage (`amp usage`,
/// `muse usage --json`, `omp usage --json`, …) or print their own sign-in
/// (`gh auth token`). Providers take this protocol so tests can script output
/// without running anything.
protocol LocalCommandRunning: Sendable {
    /// Nil when no executable with that name is installed. Throws
    /// `LocalToolUsageError.timedOut` when the command runs past `timeout`,
    /// and `.invalidResponse` when it prints more than a usage report could be.
    func run(
        _ name: String,
        arguments: [String],
        timeout: TimeInterval,
        environment overrides: [String: String]
    ) async throws -> LocalCommandOutput?
}

extension LocalCommandRunning {
    func run(_ name: String, arguments: [String], timeout: TimeInterval = 20) async throws -> LocalCommandOutput? {
        try await run(name, arguments: arguments, timeout: timeout, environment: [:])
    }
}

enum LocalCommandLocator {
    /// `PATH` first, then the folders installers use. An app opened from the
    /// Finder or at login inherits only the system `PATH`, so a CLI installed
    /// by Homebrew, npm, Bun or a curl script would otherwise not be found.
    static func searchDirectories(environment: [String: String]) -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = environment["HOME"], !home.isEmpty {
            directories += ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func executableURL(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return searchDirectories(environment: environment)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

struct LocalCommandRunner: LocalCommandRunning {
    /// Far more than any usage report; anything larger is not one.
    static let defaultMaximumOutputBytes = 1024 * 1024

    let environment: [String: String]
    let maximumOutputBytes: Int

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumOutputBytes: Int = Self.defaultMaximumOutputBytes
    ) {
        self.environment = environment
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(
        _ name: String,
        arguments: [String],
        timeout: TimeInterval,
        environment overrides: [String: String]
    ) async throws -> LocalCommandOutput? {
        guard let executable = LocalCommandLocator.executableURL(named: name, environment: environment) else {
            return nil
        }
        return try await run(executable: executable, arguments: arguments, timeout: timeout, environment: overrides)
    }

    /// Runs `executable` with no terminal and no standard input. Standard
    /// error is discarded: CLIs print account details there, and usAIge only
    /// needs the report on standard output.
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment overrides: [String: String] = [:]
    ) async throws -> LocalCommandOutput {
        var processEnvironment = environment
        // Scripts like `#!/usr/bin/env node` need the same folders on PATH.
        processEnvironment["PATH"] = LocalCommandLocator.searchDirectories(environment: environment)
            .joined(separator: ":")
        processEnvironment["TERM"] = "dumb"
        processEnvironment["NO_COLOR"] = "1"
        processEnvironment["CI"] = "1"
        for (key, value) in overrides { processEnvironment[key] = value }

        let job = CommandJob(limit: maximumOutputBytes)
        job.process.executableURL = executable
        job.process.arguments = arguments
        job.process.environment = processEnvironment
        job.process.standardInput = FileHandle.nullDevice
        job.process.standardError = FileHandle.nullDevice
        job.process.standardOutput = job.pipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// One running command. Output arrives on the pipe's reading queue and the
/// exit on the process's queue; the lock lets whichever comes last finish.
private final class CommandJob: @unchecked Sendable {
    let process = Process()
    let pipe = Pipe()
    private let limit: Int
    private let lock = NSLock()
    private var output = Data()
    private var overflowed = false
    private var exitCode: Int32?
    private var reachedEnd = false
    private var continuation: CheckedContinuation<LocalCommandOutput, Error>?

    init(limit: Int) {
        self.limit = limit
    }

    func start(continuation: CheckedContinuation<LocalCommandOutput, Error>, timeout: TimeInterval) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.endOfOutput()
            } else if !self.append(chunk) {
                self.terminate()
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.exited(process.terminationStatus)
            // A child the CLI started can keep the pipe open after it exits;
            // don't wait on it past a short grace.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.pipe.fileHandleForReading.readabilityHandler = nil
                self?.endOfOutput()
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            fail(LocalToolUsageError.notInstalled)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.05, timeout)) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.terminate()
            self.fail(LocalToolUsageError.timedOut)
        }
    }

    func cancel() {
        terminate()
        fail(CancellationError())
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return false }
        guard output.count + chunk.count <= limit else {
            overflowed = true
            return false
        }
        output.append(chunk)
        return true
    }

    private func endOfOutput() {
        lock.lock()
        reachedEnd = true
        let finished = finishIfReady()
        lock.unlock()
        finished?()
    }

    private func exited(_ code: Int32) {
        lock.lock()
        exitCode = code
        let finished = finishIfReady()
        lock.unlock()
        finished?()
    }

    private func fail(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }

    /// Called with the lock held; returns the resume to run after unlocking.
    private func finishIfReady() -> (() -> Void)? {
        guard let exitCode, reachedEnd, let pending = continuation else { return nil }
        continuation = nil
        if overflowed {
            return { pending.resume(throwing: LocalToolUsageError.invalidResponse) }
        }
        let result = LocalCommandOutput(exitCode: exitCode, standardOutput: output)
        return { pending.resume(returning: result) }
    }
}
