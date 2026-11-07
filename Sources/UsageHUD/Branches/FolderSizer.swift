import Foundation

/// Folder sizes from `du`. Sizes are allocated blocks, so files APFS shares
/// between folders count in each and deleting one can free less.
enum FolderSizer {
    static let duExecutable = URL(fileURLWithPath: "/usr/bin/du")

    /// Git-ignored folders that a build or install recreates.
    static let cacheNames: Set<String> = [
        "node_modules", ".build", "dist", "build", ".next", ".nuxt", "target", "Pods", ".venv", "venv",
        "__pycache__", "DerivedData", "coverage", ".turbo", ".cache", ".pytest_cache", ".ruff_cache",
        ".mypy_cache", "out", ".swiftpm", "playwright-report", "test-results", ".vite", ".parcel-cache",
        ".gradle", ".tox", ".wrangler",
    ]

    static func bytes(of path: String, timeout: TimeInterval = 120) async -> Int64? {
        let output = await CommandRunner.run(
            ShellCommand(executable: duExecutable, arguments: ["-sk", path]),
            timeout: timeout,
            maximumOutputBytes: 64 * 1024
        )
        // du also reports files it can't read, on stderr, and exits non-zero.
        guard !output.timedOut, let field = output.text.split(whereSeparator: \.isWhitespace).first,
              let kilobytes = Int64(field) else { return nil }
        return kilobytes * 1024
    }

    /// Sizes of many paths from one `du` per batch, so a folder with hundreds
    /// of ignored entries doesn't start hundreds of processes.
    static func bytes(ofEach paths: [String], batchSize: Int = 100, timeout: TimeInterval = 120) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        var start = 0
        while start < paths.count, !Task.isCancelled {
            let batch = Array(paths[start..<min(start + batchSize, paths.count)])
            start += batch.count
            let output = await CommandRunner.run(
                ShellCommand(executable: duExecutable, arguments: ["-sk"] + batch),
                timeout: timeout
            )
            guard !output.timedOut else { continue }
            for line in output.text.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2, let kilobytes = Int64(fields[0]) else { continue }
                sizes[String(fields[1]), default: 0] = kilobytes * 1024
            }
        }
        return sizes
    }

    /// The first path component that names a known cache, if any.
    static func cacheName(forIgnoredPath path: String) -> String? {
        path.split(separator: "/").map(String.init).first { cacheNames.contains($0) }
    }

    /// Measures a worktree. Worktrees nested inside it are rows of their own,
    /// so their sizes are subtracted from whatever contains them.
    static func measure(
        folder: String,
        ignored: [String],
        nestedSizes: [String: Int64],
        now: Date
    ) async -> FolderSize? {
        guard let measured = await bytes(of: folder) else { return nil }
        let nestedInFolder = nestedSizes.filter { RepositoryLocator.contains(folder, $0.key) && $0.key != folder }
        let total = measured - nestedInFolder.values.reduce(0, +)
        let sizes = await bytes(ofEach: ignored.map { folder + "/" + $0 })
        if Task.isCancelled { return nil }
        var cacheBytes: Int64 = 0
        var byName: [String: Int64] = [:]
        var otherBytes: Int64 = 0
        for path in ignored {
            let full = folder + "/" + path
            guard let raw = sizes[full] else { continue }
            let nested = nestedInFolder.filter { RepositoryLocator.contains(full, $0.key) }.values.reduce(0, +)
            let size = max(0, raw - nested)
            if let name = cacheName(forIgnoredPath: path) {
                cacheBytes += size
                byName[name, default: 0] += size
            } else {
                otherBytes += size
            }
        }
        return FolderSize(
            totalBytes: max(0, total),
            cacheBytes: cacheBytes,
            cacheBytesByName: byName,
            ignored: ignored,
            otherIgnoredBytes: otherBytes,
            measuredAt: now
        )
    }
}
