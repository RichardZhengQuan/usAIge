import AppKit
import Darwin

/// Saved paths are discovery hints. Only projects the person chooses during
/// this launch can be visited, even when macOS remembers a wider permission.
final class WorkspaceFolderAccess: NSObject, NSOpenSavePanelDelegate, @unchecked Sendable {
    static let shared = WorkspaceFolderAccess(home: FileManager.default.homeDirectoryForCurrentUser.path)
    private let locator: RepositoryLocator
    private let lock = NSLock()
    private var paths: Set<String> = []

    init(home: String) {
        locator = RepositoryLocator(home: home)
    }

    var authorizedPaths: [String] {
        lock.withLock { Array(paths) }
    }

    enum Result: Equatable, Sendable {
        case allowed, denied, unavailable
    }

    /// This read is initiated by Scan Project. macOS can ask for Files &
    /// Folders permission as part of opening the project directory.
    func requestScan(of folder: String) async -> Result {
        guard let project = locator.protectedProjectPath(folder) else { return .unavailable }
        return await Task.detached(priority: .userInitiated) { [self] in
            let scope = RepositoryLocator(home: locator.home, allowedFolders: [project])
            guard case let .allowed(path) = scope.access(to: project) else { return .denied }
            guard let directory = opendir(path) else {
                return (errno == EPERM || errno == EACCES) ? .denied : .unavailable
            }
            defer { closedir(directory) }
            errno = 0
            if readdir(directory) == nil, errno != 0 {
                return (errno == EPERM || errno == EACCES) ? .denied : .unavailable
            }
            lock.withLock { _ = paths.insert(project) }
            return .allowed
        }.value
    }

    @MainActor
    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.delegate = self
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = AppLanguage.text("Choose a project folder to scan.")
        panel.prompt = AppLanguage.text("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = RepositoryLocator.lexicalPath(url.resolvingSymlinksInPath().path)
        if let project = locator.protectedProjectPath(path) {
            lock.withLock { _ = paths.insert(project) }
        }
        return path
    }

    @MainActor
    func panel(_ sender: Any, validate url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        if locator.isProtected(path), locator.protectedProjectPath(path) == nil {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInvalidFileNameError, userInfo: [
                NSLocalizedDescriptionKey: AppLanguage.text("Choose a project inside this folder.")
            ])
        }
    }
}
