import Foundation
@testable import UsageHUD

/// Scripted command output for provider tests: answers by executable name,
/// records every call, and never starts a process.
actor ScriptedLocalCommandRunner: LocalCommandRunning {
    enum Reply: Sendable {
        case output(LocalCommandOutput)
        case notInstalled
        case failure(LocalToolUsageError)
    }

    struct Call: Equatable, Sendable {
        let name: String
        let arguments: [String]
        let environment: [String: String]
    }

    private var replies: [String: [Reply]]
    private(set) var calls: [Call] = []

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
    }

    init(stdout: [String: String], exitCode: Int32 = 0) {
        replies = stdout.mapValues { [.output(LocalCommandOutput(exitCode: exitCode, standardOutput: Data($0.utf8)))] }
    }

    func run(
        _ name: String,
        arguments: [String],
        timeout: TimeInterval,
        environment overrides: [String: String]
    ) async throws -> LocalCommandOutput? {
        calls.append(Call(name: name, arguments: arguments, environment: overrides))
        guard var queue = replies[name], !queue.isEmpty else { return nil }
        let reply = queue.count == 1 ? queue[0] : queue.removeFirst()
        replies[name] = queue
        switch reply {
        case let .output(output): return output
        case .notInstalled: return nil
        case let .failure(error): throw error
        }
    }
}
