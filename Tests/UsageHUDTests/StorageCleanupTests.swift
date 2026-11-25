import Foundation
import Testing
@testable import UsageHUD

@Suite(.serialized)
struct StorageCleanupTests {
    @MainActor
    @Test func clearsSelectedDependenciesInMainAndLinkedWorktreesWithoutDeletingGitWork() async throws {
        let fixture = try await Task.detached { try Self.prepareRepository() }.value
        let worktree = fixture.worktreePath("topic")
        try fixture.git(["worktree", "add", "--quiet", "-b", "topic", worktree])
        try installDependency(in: fixture.repository, fixture: fixture)
        try installDependency(in: worktree, fixture: fixture)
        try fixture.write("draft.txt", "Local work stays", in: worktree)

        let store = BranchesStore(scanner: fixture.scanner(), diskURL: URL(fileURLWithPath: fixture.home))
        await store.loadCleanupInventory()?.value
        let inventory = try #require(store.cleanupInventory)
        let items = inventory.rows.compactMap(\.candidate)
        #expect(Set(items.map(\.id)) == Set([fixture.repository, worktree].map { $0 + "/site/node_modules" }))
        #expect(inventory.foldersChecked == 2)
        #expect(store.cleanableSpace.bytes == items.reduce(0) { $0 + $1.bytes })
        #expect(store.loadCleanupInventory() == nil)
        #expect(!store.startStorageCleanup([try #require(items.first), try #require(items.first)]))
        #expect(store.startStorageCleanup(items))
        #expect(store.cleanupProgress?.operation == .clearingFiles)
        store.windowClosed()

        let deadline = ContinuousClock.now + .seconds(10)
        while store.isDeleting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
        #expect(!store.isDeleting)
        #expect(store.resultMessage?.deletedCount == 2)
        #expect(store.resultMessage?.undoable.isEmpty == true)
        #expect(store.resultMessage?.text.contains("Available space was") == true)
        #expect(store.cleanupInventory == nil)
        await store.loadCleanupInventory()?.value
        #expect(store.cleanupInventory?.rows.isEmpty == true)
        #expect(store.cleanableSpace.bytes == 0)
        for item in items { #expect(!FileManager.default.fileExists(atPath: item.id)) }
        #expect(try fixture.git(["worktree", "list"]).contains(worktree))
        #expect(FileManager.default.fileExists(atPath: worktree + "/draft.txt"))
        #expect(FileManager.default.fileExists(atPath: fixture.repository + "/site/package-lock.json"))
    }

    @Test func refusesChangedTrackedOrBusyFilesAtConfirmation() async throws {
        let fixture = try Self.prepareRepository()
        try installDependency(in: fixture.repository, fixture: fixture)
        let scanner = fixture.scanner()
        let firstScan = await scanner.scanStorage(addedFolders: [])
        let reviewed = try #require(firstScan.rows.first?.candidate)
        let source = reviewed.id + "/example/index.js"
        try fixture.write("site/node_modules/example/index.js", "Edited after review", in: fixture.repository)
        let changed = await scanner.removeStorageArtifact(reviewed)
        #expect(changed?.contains("changed") == true)
        #expect(FileManager.default.fileExists(atPath: source))

        let freshScan = await scanner.scanStorage(addedFolders: [])
        let fresh = try #require(freshScan.rows.first?.candidate)
        fixture.setRunningProcesses([fixture.process(named: "node", in: fixture.repository)])
        let busy = await scanner.removeStorageArtifact(fresh)
        #expect(busy?.contains("in use") == true)
        fixture.setRunningProcesses([])
        let blob = try fixture.git(["hash-object", "-w", "--", "site/node_modules/example/index.js"])
        try fixture.git(["update-index", "--add", "--cacheinfo", "100644,\(blob),Site/node_modules/example/index.js"])
        let tracked = await scanner.removeStorageArtifact(fresh)
        #expect(tracked?.contains("Git tracks") == true)
        #expect(FileManager.default.fileExists(atPath: source))
    }

    @Test func nestedConfigurationAndLinkedDependenciesAreNotSelectable() async throws {
        let fixture = try Self.prepareRepository()
        try installDependency(in: fixture.repository, fixture: fixture)
        try fixture.write("site/node_modules/example/.env", "FIXTURE=keep", in: fixture.repository)
        let scanner = fixture.scanner()
        let protected = await scanner.scanStorage(addedFolders: [])
        let row = try #require(protected.rows.first)
        #expect(row.candidate == nil)
        #expect(row.reason?.contains(".env") == true)

        let modules = fixture.repository + "/site/node_modules"
        let outside = fixture.root + "/external-package"
        try fixture.write("index.js", "Outside contents", in: outside)
        try FileManager.default.createDirectory(atPath: modules + "/.bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: modules + "/.bin/external", withDestinationPath: outside)
        let linked = await scanner.scanStorage(addedFolders: [])
        #expect(linked.rows.first?.candidate == nil)
        #expect(linked.rows.first?.reason?.contains("external") == true)
        #expect(FileManager.default.fileExists(atPath: outside + "/index.js"))
    }

    @Test func toolArtifactsAreAvailableWithoutAnyGitWorktree() async throws {
        let fixture = try GitFixture()
        try fixture.write(".npm/_cacache/content-v2/example", "npm cache", in: fixture.home)
        let derived = StorageArtifactKind.derivedDataPath + "/Sample-abc"
        try fixture.write(derived + "/info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WorkspacePath</key><string>/tmp/Sample.xcodeproj</string></dict></plist>
            """, in: fixture.home)
        try fixture.write(derived + "/Build/Intermediates.noindex/build.o", "intermediate", in: fixture.home)
        try fixture.write("Library/Developer/Xcode/Archives/Release.xcarchive/Keep", "archive", in: fixture.home)

        let scanner = StorageArtifactScanner(home: fixture.home, locator: RepositoryLocator(home: fixture.home),
                                             git: nil, processes: { [] }, sessions: [], now: Date())
        let inventory = await scanner.scan(sessionFolders: [fixture.home], addedFolders: [])
        #expect(inventory.foldersChecked == 0)
        let candidates = inventory.rows.compactMap(\.candidate)
        #expect(Set(candidates.map(\.location.kind)) == [.npmCache, .xcodeBuild])
        let npm = try #require(candidates.first { $0.location.kind == .npmCache })
        #expect(await scanner.remove(npm) == nil)
        #expect(!FileManager.default.fileExists(atPath: npm.id))
        #expect(FileManager.default.fileExists(atPath: fixture.home + "/Library/Developer/Xcode/Archives/Release.xcarchive/Keep"))
    }

    @Test func scanningOneDocumentsProjectKeepsItsSiblingOutOfGitAndStorage() async throws {
        let fixture = try Self.prepareRepository()
        let project = fixture.home + "/Documents/project"
        let sibling = project + "-other"
        try FileManager.default.createDirectory(atPath: fixture.home + "/Documents", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: fixture.repository, toPath: project)
        try installDependency(in: project, fixture: fixture)
        try FileManager.default.copyItem(atPath: project, toPath: sibling)

        let access = WorkspaceFolderAccess(home: fixture.home)
        var environment = BranchesScanner.Environment(
            home: URL(fileURLWithPath: fixture.home),
            cacheFile: URL(fileURLWithPath: fixture.root + "/cache/branches.json"),
            deletionLogFile: URL(fileURLWithPath: fixture.root + "/deletions.json"),
            git: GitClient.locate(), cursorDatabase: URL(fileURLWithPath: fixture.root + "/no-cursor.vscdb"),
            addedFolders: { [project, sibling] }, processes: { [] }, now: Date.init,
            selectedFolders: { access.authorizedPaths }
        )
        let scanner = BranchesScanner(environment: environment)
        let lockedSnapshot = await fixture.scan(with: scanner)
        #expect(lockedSnapshot.repositories.isEmpty)
        #expect(lockedSnapshot.notCheckedFolders == [project, sibling])
        let lockedInventory = await scanner.scanStorage(addedFolders: [])
        #expect(lockedInventory.rows.isEmpty)
        #expect(lockedInventory.skippedFolders == [project, sibling])
        #expect(access.authorizedPaths.isEmpty)

        #expect(await access.requestScan(of: project) == .allowed)
        #expect(access.authorizedPaths == [project])
        let afterSelection = await fixture.scan(with: scanner)
        #expect(afterSelection.repositories.map(\.folder) == [project])
        #expect(afterSelection.notCheckedFolders == [sibling])
        let inventory = await scanner.scanStorage(addedFolders: [])
        #expect(inventory.rows.compactMap(\.candidate).map(\.id) == [project + "/site/node_modules"])
        #expect(inventory.skippedFolders == [sibling])

        let nextLaunch = WorkspaceFolderAccess(home: fixture.home)
        environment.selectedFolders = { nextLaunch.authorizedPaths }
        let relaunched = await fixture.scan(with: BranchesScanner(environment: environment))
        #expect(relaunched.repositories.isEmpty)
        #expect(relaunched.notCheckedFolders == [project, sibling])
    }

    @Test func selectedNonGitFolderCanBeScannedInsideDocuments() async throws {
        let fixture = try GitFixture()
        let project = fixture.home + "/Documents/standalone"
        try fixture.write("site/package.json", #"{"name":"sample","dependencies":{"example":"1.0.0"}}"#, in: project)
        try fixture.write("site/package-lock.json", #"{"packages":{"node_modules/example":{"version":"1.0.0"}}}"#, in: project)
        try installDependency(in: project, fixture: fixture)

        let locator = RepositoryLocator(home: fixture.home, allowedFolders: [project])
        let scanner = StorageArtifactScanner(home: fixture.home, locator: locator,
                                             git: nil, processes: { [] }, sessions: [], now: Date())
        let inventory = await scanner.scan(sessionFolders: [], addedFolders: [project])
        #expect(inventory.skippedFolders.isEmpty)
        #expect(inventory.rows.first?.candidate?.id == project + "/site/node_modules")
    }

    @Test func incompleteFolderSizesAreUnknown() async throws {
        let fixture = try GitFixture()
        let locator = RepositoryLocator(home: fixture.home)
        try fixture.write("readable/data", "fixture")
        try fixture.write("unreadable/data", "protected fixture")
        let folder = fixture.repository + "/unreadable"
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        #expect(await FolderSizer.bytes(of: fixture.repository, locator: locator) == nil)
        #expect(CleanupFileInspection.read(fixture.repository, locator: locator) == nil)
    }

    @Test func storageDiscoverySkipsHomeAndPhotoLibraries() async throws {
        let fixture = try Self.prepareRepository()
        let locator = RepositoryLocator(home: fixture.home)
        let library = fixture.repository + "/Library.PhotosLibrary"
        try fixture.write("Library.PhotosLibrary/assets", String(repeating: "x", count: 1_000_000))
        try fixture.write("Pictures/Photos Library.photoslibrary/assets", "private fixture", in: fixture.home)
        try installDependency(in: fixture.repository, fixture: fixture)

        let scanner = StorageArtifactScanner(home: fixture.home, locator: locator, git: GitClient.locate(),
                                             processes: { [] }, sessions: [], now: Date())
        let inventory = await scanner.scan(sessionFolders: [fixture.home, fixture.repository],
                                           addedFolders: [fixture.home, library])
        #expect(inventory.foldersChecked == 1)
        #expect(inventory.skippedFolders.isEmpty)
        #expect(inventory.rows.compactMap(\.candidate).map(\.id) == [fixture.repository + "/site/node_modules"])
        #expect(await FolderSizer.bytes(of: fixture.home, locator: locator) == nil)
        #expect(await FolderSizer.bytes(of: library, locator: locator) == nil)
        let withoutPhotos = try #require(await FolderSizer.bytes(of: fixture.repository, locator: locator))
        #expect(withoutPhotos < 1_000_000)
        #expect(CleanupFileInspection.read(fixture.repository, locator: locator) == nil)
    }

    private static func prepareRepository() throws -> GitFixture {
        let fixture = try GitFixture()
        try fixture.commit(".gitignore", "site/node_modules/\n", message: "Ignore generated npm dependencies")
        try fixture.commit("site/package.json", #"{"name":"sample","dependencies":{"example":"1.0.0"}}"#,
                           message: "Package manifest")
        try fixture.commit("site/package-lock.json", #"{"packages":{"node_modules/example":{"version":"1.0.0"}}}"#,
                           message: "Lock npm dependencies")
        return fixture
    }

    private func installDependency(in folder: String, fixture: GitFixture) throws {
        try fixture.write("site/node_modules/example/index.js", "Generated dependency", in: folder)
        let modules = folder + "/site/node_modules"
        try FileManager.default.createDirectory(atPath: modules + "/.bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: modules + "/.bin/example", withDestinationPath: "../example/index.js")
    }
}
