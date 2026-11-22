import CryptoKit
import Darwin
import Foundation

struct CleanupFileIdentity: Codable, Equatable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

/// A bounded, metadata-only read. An incomplete read cannot authorize removal.
struct CleanupFileInspection: Equatable, Sendable {
    let identity: CleanupFileIdentity
    let fingerprint: String
    let allocatedBytes: Int64
    let protectedPath: String?

    static func normalized(_ path: String) -> String {
        RepositoryLocator.normalized(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    static func metadata(_ path: String) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info
    }

    static func directory(_ path: String) -> CleanupFileIdentity? {
        guard let info = metadata(path), isDirectory(info), isLocal(path, info: info),
              normalized(path) == normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        else { return nil }
        return CleanupFileIdentity(info)
    }

    static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR
    }

    static func regularFile(_ path: String) -> stat? {
        guard let info = metadata(path), info.st_mode & S_IFMT == S_IFREG,
              isLocal(path, info: info) else { return nil }
        return info
    }

    static func read(_ path: String) -> CleanupFileInspection? {
        guard let info = metadata(path),
              directory((path as NSString).deletingLastPathComponent) != nil else { return nil }
        var scan = Inspection(root: path, device: info.st_dev)
        guard scan.visit(path, info: info, depth: 0) else { return nil }
        return CleanupFileInspection(identity: CleanupFileIdentity(info), fingerprint: Self.finish(scan.digest),
                                     allocatedBytes: scan.bytes, protectedPath: scan.protectedPath)
    }

    static func finish(_ digest: SHA256) -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isLocal(_ path: String, info: stat) -> Bool {
        let lower = path.lowercased()
        return info.st_flags & UInt32(SF_DATALESS) == 0
            && !lower.contains("/library/cloudstorage/")
            && !lower.hasSuffix("/library/cloudstorage")
            && !lower.contains("/library/mobile documents/")
            && !lower.hasSuffix("/library/mobile documents")
            && (!isDirectory(info) || !RepositoryLocator.isManagedByICloud(path))
    }

    private struct Inspection {
        let root: String
        let device: Int32
        var digest = SHA256()
        var bytes: Int64 = 0
        var protectedPath: String?
        var visited = 0
        var hardLinks: Set<CleanupFileIdentity> = []

        mutating func visit(_ path: String, info: stat, depth: Int) -> Bool {
            visited += 1
            guard visited <= 200_000, depth <= 64, !Task.isCancelled,
                  info.st_dev == device, CleanupFileInspection.isLocal(path, info: info) else { return false }
            let relative = String(path.dropFirst(root.count))
            let type = info.st_mode & S_IFMT
            let modified = info.st_mtimespec
            let changed = info.st_ctimespec
            let stamp = "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_flags):"
                + "\(info.st_nlink):\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):"
                + "\(changed.tv_sec):\(changed.tv_nsec)"
            digest.update(data: Data("\(relative.utf8.count):\(relative):\(stamp)\n".utf8))
            if type != S_IFREG || info.st_nlink == 1 || hardLinks.insert(CleanupFileIdentity(info)).inserted {
                bytes += max(0, info.st_blocks) * 512
            }
            if protectedPath == nil, info.st_uid != getuid() || Self.isProtectedName(path) {
                protectedPath = path
            }
            switch type {
            case S_IFREG:
                return true
            case S_IFLNK:
                // Standard npm executable links point inside node_modules.
                // Other links may represent a locally linked package.
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
                let destination = URL(fileURLWithPath: target, relativeTo: URL(
                    fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true
                )).standardizedFileURL
                let resolved = CleanupFileInspection.normalized(destination.resolvingSymlinksInPath().path)
                if path == root || !RepositoryLocator.contains(root, resolved) { protectedPath = protectedPath ?? path }
                digest.update(data: Data("\(target.utf8.count):\(target)\n".utf8))
                return true
            case S_IFDIR:
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
                for name in children.sorted() {
                    let child = path + "/" + name
                    guard let childInfo = CleanupFileInspection.metadata(child),
                          visit(child, info: childInfo, depth: depth + 1) else { return false }
                }
                // A replaced or edited directory invalidates a partially read inventory.
                guard let current = CleanupFileInspection.metadata(path) else { return false }
                return CleanupFileIdentity(info) == CleanupFileIdentity(current)
                    && changed.tv_sec == current.st_ctimespec.tv_sec && changed.tv_nsec == current.st_ctimespec.tv_nsec
            default:
                return false
            }
        }

        private static func isProtectedName(_ path: String) -> Bool {
            let name = (path as NSString).lastPathComponent.lowercased()
            return name == ".env" || name == ".envrc" || name.hasPrefix(".env.")
                || [".git", ".ssh", ".npmrc", ".netrc", ".aws", "id_rsa", "id_ed25519"].contains(name)
                || ["xcarchive", "dmg", "p12", "pfx", "pem", "key", "mobileprovision"]
                    .contains((name as NSString).pathExtension)
        }
    }
}

struct WorktreeIgnoredReview: Codable, Equatable, Sendable {
    let identity: CleanupFileIdentity
    let fingerprint: String
    let unverifiedPaths: [String]

    static func read(worktree: String, ignored: [String]) -> WorktreeIgnoredReview? {
        guard let identity = CleanupFileInspection.directory(worktree) else { return nil }
        var digest = SHA256()
        var unverified: [String] = []
        for relative in ignored.sorted() {
            let path = worktree + "/" + relative
            guard CleanupFileInspection.normalized(path) == path, RepositoryLocator.contains(worktree, path),
                  path != worktree, let scan = CleanupFileInspection.read(path),
                  scan.identity.device == identity.device else { return nil }
            digest.update(data: Data("\(relative.utf8.count):\(relative):\(scan.fingerprint)\n".utf8))
            if let protected = scan.protectedPath {
                unverified.append(String(protected.dropFirst(worktree.count + 1)))
            } else if !StorageArtifactKind.isVerifiedProjectOutput(path, within: worktree) {
                unverified.append(relative)
            }
        }
        return WorktreeIgnoredReview(identity: identity, fingerprint: CleanupFileInspection.finish(digest),
                                     unverifiedPaths: unverified)
    }
}
