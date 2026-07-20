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
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var readerTask: Task<Void, Never>?
    private let lineStream: AsyncStream<String>
    private let lineContinuation: AsyncStream<String>.Continuation

    init(executableURL: URL, arguments: [String] = ["app-server"]) {
        self.executableURL = executableURL
        self.arguments = arguments
        (lineStream, lineContinuation) = AsyncStream.makeStream(of: String.self)
    }

    func start() async throws {
        guard process == nil else { return }
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
        self.process = process
        self.input = input
        self.output = output

        let handle = output.fileHandleForReading
        let continuation = lineContinuation
        readerTask = Task.detached {
            var buffer = Data()
            while !Task.isCancelled {
                // FileHandle returns autoreleased NSData. This detached task has no
                // run-loop pool, so drain one explicitly after every pipe read.
                let receivedChunk = autoreleasepool {
                    let data = handle.availableData
                    guard !data.isEmpty else { return false }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let frame = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        if let line = String(data: frame, encoding: .utf8), !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                    return true
                }
                if !receivedChunk { break }
            }
            continuation.finish()
        }
    }

    func write(_ line: String) async throws {
        guard let input else { throw JSONRPCError.disconnected }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func lines() async -> AsyncStream<String> {
        lineStream
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        lineContinuation.finish()
    }
}
