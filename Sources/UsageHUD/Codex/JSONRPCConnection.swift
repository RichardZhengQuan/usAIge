import Foundation

protocol LineTransport: Sendable {
    func start() async throws
    func write(_ line: String) async throws
    func lines() async -> AsyncStream<String>
    func stop() async
}

struct JSONRPCNotification: Equatable, Sendable {
    let method: String
    let params: JSONValue
}

enum JSONRPCError: Error, Equatable, Sendable {
    case disconnected
    case invalidResponse
    case server(code: Int?, message: String)
}

actor JSONRPCConnection {
    private let transport: any LineTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var notificationContinuations: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]
    private var readTask: Task<Void, Never>?
    private var started = false

    init(transport: any LineTransport) {
        self.transport = transport
    }

    func start() async throws {
        guard !started else { return }
        try await transport.start()
        let stream = await transport.lines()
        started = true
        readTask = Task { [weak self] in
            for await line in stream {
                await self?.receive(line)
            }
            await self?.disconnect()
        }
    }

    func request(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard started else { throw JSONRPCError.disconnected }
        let id = nextID
        nextID += 1
        let frame: JSONValue = .object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let data = try JSONEncoder().encode(frame)
        guard let line = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.invalidResponse
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do {
                        try await transport.write(line)
                    } catch {
                        self.failRequest(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failRequest(id: id, error: CancellationError()) }
        }
    }

    func notify(method: String, params: JSONValue = .object([:])) async throws {
        guard started else { throw JSONRPCError.disconnected }
        let frame: JSONValue = .object([
            "method": .string(method),
            "params": params,
        ])
        let data = try JSONEncoder().encode(frame)
        guard let line = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.invalidResponse
        }
        try await transport.write(line)
    }

    func notifications() -> AsyncStream<JSONRPCNotification> {
        let id = UUID()
        return AsyncStream { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        await transport.stop()
        disconnect()
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = frame.objectValue else { return }

        if let id = object["id"]?.intValue {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"]?.objectValue {
                continuation.resume(throwing: JSONRPCError.server(
                    code: error["code"]?.intValue,
                    message: error["message"]?.stringValue ?? "Unknown server error"
                ))
            } else if let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: JSONRPCError.invalidResponse)
            }
            return
        }

        if let method = object["method"]?.stringValue {
            let notification = JSONRPCNotification(
                method: method,
                params: object["params"] ?? .object([:])
            )
            for continuation in notificationContinuations.values {
                continuation.yield(notification)
            }
        }
    }

    private func failRequest(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func disconnect() {
        guard started else { return }
        started = false
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: JSONRPCError.disconnected) }
        notificationContinuations.values.forEach { $0.finish() }
        notificationContinuations.removeAll()
    }
}

actor ProcessLineTransport: LineTransport {
    private let executableURL: @Sendable () -> URL?
    private let arguments: [String]
    private var process: Process?
    private var input: Pipe?
    private var outputReader: PipeReader?
    private var errorReader: PipeReader?
    private var lineStream: AsyncStream<String>?
    private var lineContinuation: AsyncStream<String>.Continuation?

    init(executableURL: URL, arguments: [String] = ["app-server"]) {
        self.init(executableURL: { executableURL }, arguments: arguments)
    }

    /// `executableURL` is asked again on every start, so a restart picks up
    /// an executable that moved since the last one.
    init(executableURL: @escaping @Sendable () -> URL?, arguments: [String] = ["app-server"]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start() async throws {
        guard process == nil else { return }
        guard let executableURL = executableURL() else { throw JSONRPCError.disconnected }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let streamPair = AsyncStream.makeStream(of: String.self)
        self.process = process
        self.input = input
        lineStream = streamPair.stream
        lineContinuation = streamPair.continuation

        let continuation = streamPair.continuation
        outputReader = PipeReader(
            output.fileHandleForReading,
            label: "com.usaige.app-server.stdout",
            onLine: { continuation.yield($0) },
            onEnd: { continuation.finish() }
        )
        // Nothing reads the app-server's stderr, so drain it as it arrives.
        // A pipe nobody reads fills after about 64 KB and then blocks the
        // app-server on its next log line, which stalls stdout and every
        // request with it.
        errorReader = PipeReader(error.fileHandleForReading, label: "com.usaige.app-server.stderr")
    }

    func write(_ line: String) async throws {
        guard let input else { throw JSONRPCError.disconnected }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func lines() async -> AsyncStream<String> {
        lineStream ?? AsyncStream { $0.finish() }
    }

    func stop() async {
        // The readers close stdout and stderr themselves. Closing either
        // here could land just before a read the reader has already begun.
        outputReader?.cancel()
        errorReader?.cancel()
        outputReader = nil
        errorReader = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        lineContinuation?.finish()
        lineStream = nil
        lineContinuation = nil
    }
}

/// Drains one pipe end on a dispatch read source, framing it into lines when
/// `onLine` is set and discarding it otherwise.
///
/// The cancel handler is the only place the pipe is closed. Dispatch runs it
/// after the last read handler has returned and starts no read after it, so
/// `cancel()` is safe at any moment. Closing the handle from outside is not:
/// a read that starts on the closed descriptor makes FileHandle raise an
/// Objective-C exception that Swift can't catch, and a plain read(2) could
/// land on whatever reused the descriptor number.
private final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let onLine: (@Sendable (String) -> Void)?
    // Only the read handler touches these, and it runs on one serial queue.
    private var chunk = [UInt8](repeating: 0, count: 65_536)
    private var buffer = Data()

    /// `onEnd` runs once, after the pipe is closed, whether it reached end of
    /// file or `cancel()` stopped it.
    init(
        _ handle: FileHandle,
        label: String,
        onLine: (@Sendable (String) -> Void)? = nil,
        onEnd: @escaping @Sendable () -> Void = {}
    ) {
        descriptor = handle.fileDescriptor
        self.onLine = onLine
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: label)
        )
        // The event handler keeps the reader alive until the pipe closes.
        // Dispatch releases it once the source is cancelled.
        source.setEventHandler { [self] in readAvailable() }
        source.setCancelHandler {
            try? handle.close()
            onEnd()
        }
        source.activate()
    }

    func cancel() {
        source.cancel()
    }

    private func readAvailable() {
        // Dispatch threads drain their autorelease pools only now and then,
        // and a busy pipe fires this many times a second, so drain one after
        // every read.
        autoreleasepool {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                // End of file or a broken pipe. A read source keeps firing
                // at end of file, so stop it.
                source.cancel()
                return
            }
            guard let onLine else { return }
            buffer.append(contentsOf: chunk[..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let frame = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let line = String(data: frame, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
            }
        }
    }
}
