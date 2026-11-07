import Foundation

struct ShellCommand: Sendable {
    var executable: URL
    var arguments: [String]
    var directory: URL? = nil
    var environment: [String: String]? = nil
}

struct CommandOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let truncated: Bool

    var succeeded: Bool { status == 0 && !timedOut && !truncated }
    var text: String { String(decoding: stdout, as: UTF8.self) }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    static let couldNotStart = CommandOutput(status: -1, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
}

/// Runs short helper processes off the main thread at utility priority. Every
/// run has a deadline and an output cap, and stops when its task is cancelled.
enum CommandRunner {
    static let defaultMaximumOutputBytes = 8 * 1024 * 1024

    static func run(
        _ command: ShellCommand,
        timeout: TimeInterval = 20,
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) async -> CommandOutput {
        await execute([command], timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    /// Connects one process's output straight to another's input, so a large
    /// diff streams between them and never enters this app's memory.
    static func run(
        piping source: ShellCommand,
        into sink: ShellCommand,
        timeout: TimeInterval = 60,
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) async -> CommandOutput {
        await execute([source, sink], timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    private static func execute(
        _ stages: [ShellCommand],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async -> CommandOutput {
        let running = RunningCommand(stages: stages, maximumOutputBytes: maximumOutputBytes)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                running.start(timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            running.cancel()
        }
    }
}

private final class RunningCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let processes: [Process]
    private let linkPipes: [Pipe]
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let maximumOutputBytes: Int
    private var output = Data()
    private var errors = Data()
    private var truncated = false
    private var timedOut = false
    private var cancelled = false
    private var started = false
    private var completion: ((CommandOutput) -> Void)?

    init(stages: [ShellCommand], maximumOutputBytes: Int) {
        self.maximumOutputBytes = maximumOutputBytes
        processes = stages.map { stage in
            let process = Process()
            process.executableURL = stage.executable
            process.arguments = stage.arguments
            if let directory = stage.directory { process.currentDirectoryURL = directory }
            if let environment = stage.environment { process.environment = environment }
            process.qualityOfService = .utility
            return process
        }
        linkPipes = stages.dropLast().map { _ in Pipe() }
    }

    func start(timeout: TimeInterval, completion: @escaping (CommandOutput) -> Void) {
        lock.lock()
        self.completion = completion
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled {
            finish(with: .couldNotStart)
            return
        }

        processes[0].standardInput = FileHandle.nullDevice
        for (index, pipe) in linkPipes.enumerated() {
            processes[index].standardOutput = pipe
            processes[index].standardError = FileHandle.nullDevice
            processes[index + 1].standardInput = pipe
        }
        processes[processes.count - 1].standardOutput = outputPipe
        processes[processes.count - 1].standardError = errorPipe

        let group = DispatchGroup()
        var launched: [Process] = []
        for process in processes {
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
                launched.append(process)
            } catch {
                group.leave()
                for running in launched where running.isRunning { running.terminate() }
                closeParentPipeEnds()
                finish(with: .couldNotStart)
                return
            }
        }
        lock.lock()
        started = true
        let cancelledDuringLaunch = cancelled
        lock.unlock()
        // Only the children may hold these ends, or a reader would never see
        // the end of its input.
        closeParentPipeEnds()
        if cancelledDuringLaunch { terminateAll() }

        let queue = DispatchQueue.global(qos: .utility)
        group.enter()
        queue.async { [self] in
            drain(outputPipe.fileHandleForReading) { [self] chunk in appendOutput(chunk) }
            group.leave()
        }
        group.enter()
        queue.async { [self] in
            drain(errorPipe.fileHandleForReading) { [self] chunk in appendError(chunk) }
            group.leave()
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let isFinished = self.completion == nil
            if !isFinished { timedOut = true }
            lock.unlock()
            guard !isFinished else { return }
            terminateAll()
            // A process that ignores termination, or a descendant keeping the
            // pipe open, must not hold the caller forever.
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                for process in processes where process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                finish(with: currentOutput(status: -1))
            }
        }
        group.notify(queue: queue) { [self] in
            // A source that dies midway leaves the last stage with partial
            // input and a clean exit, so every stage has to have succeeded.
            let statuses = processes.map(\.terminationStatus)
            finish(with: currentOutput(status: statuses.first { $0 != 0 } ?? 0))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let hasStarted = started
        lock.unlock()
        if hasStarted { terminateAll() }
    }

    private func terminateAll() {
        for process in processes where process.isRunning { process.terminate() }
    }

    private func closeParentPipeEnds() {
        for pipe in linkPipes {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }

    private func drain(_ handle: FileHandle, into append: (Data) -> Void) {
        while true {
            let chunk = autoreleasepool { handle.availableData }
            if chunk.isEmpty { break }
            append(chunk)
        }
        try? handle.close()
    }

    private func appendOutput(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = maximumOutputBytes - output.count
        if chunk.count > room { truncated = true }
        if room > 0 { output.append(chunk.prefix(room)) }
    }

    private func appendError(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard errors.count < 64 * 1024 else { return }
        errors.append(chunk.prefix(64 * 1024 - errors.count))
    }

    private func currentOutput(status: Int32) -> CommandOutput {
        lock.lock()
        defer { lock.unlock() }
        return CommandOutput(status: status, stdout: output, stderr: errors, timedOut: timedOut, truncated: truncated)
    }

    private func finish(with result: CommandOutput) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(result)
    }
}
