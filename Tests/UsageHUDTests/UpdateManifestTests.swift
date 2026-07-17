import Foundation
import Testing
@testable import UsageHUD

@Test func updateManifestUsesBuildNumberForAvailability() throws {
    let manifest = UpdateManifest(
        version: "0.2.0",
        build: 8,
        minimumSystemVersion: "15.0",
        downloadURL: try #require(URL(string: "https://example.com/usAIge.dmg")),
        sha256: String(repeating: "a", count: 64)
    )

    #expect(manifest.isNewer(thanBuild: 7))
    #expect(!manifest.isNewer(thanBuild: 8))
    #expect(throws: Never.self) { try manifest.validate() }
}

@Test func updateManifestRejectsInsecureDownloadsAndInvalidHashes() throws {
    let insecure = UpdateManifest(
        version: "0.2.0",
        build: 8,
        minimumSystemVersion: "15.0",
        downloadURL: try #require(URL(string: "http://example.com/usAIge.dmg")),
        sha256: "not-a-hash"
    )

    #expect(throws: UpdateError.self) { try insecure.validate() }
}

@Test func updateStatusUsesCheckAndUpToDateCopy() throws {
    #expect(UpdateStatus.idle.primaryButtonTitle == "Check for Updates")
    #expect(UpdateStatus.upToDate.primaryButtonTitle == "Check for Updates")
    #expect(UpdateStatus.upToDate.isPrimaryActionEnabled)
    #expect(!UpdateStatus.checking.isPrimaryActionEnabled)

    let manifest = UpdateManifest(
        version: "0.2.0",
        build: 8,
        minimumSystemVersion: "15.0",
        downloadURL: try #require(URL(string: "https://example.com/usAIge.dmg")),
        sha256: String(repeating: "a", count: 64)
    )
    #expect(UpdateStatus.available(manifest).primaryButtonTitle == "Update to 0.2.0")
}

@Test func publishedUpdateManifestMatchesPackagedRelease() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistData = try Data(
        contentsOf: projectRoot.appendingPathComponent("Sources/UsageHUD/Resources/Info.plist")
    )
    let plist = try #require(
        PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    )
    let manifestData = try Data(
        contentsOf: projectRoot.appendingPathComponent("site/public/update.json")
    )
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)

    #expect(manifest.version == plist["CFBundleShortVersionString"] as? String)
    #expect(manifest.build == Int(plist["CFBundleVersion"] as? String ?? ""))
    #expect(manifest.minimumSystemVersion == "11.0")
    #expect(manifest.minimumSystemVersion == plist["LSMinimumSystemVersion"] as? String)
    #expect(
        plist["UpdateManifestURLs"] as? [String]
            == UpdateController.defaultManifestURLs.map(\.absoluteString)
    )
}

@Test func migrationReleaseChecksCurrentAndLegacyUpdateFeeds() {
    #expect(UpdateController.defaultManifestURLs == [
        UpdateController.currentManifestURL,
        UpdateController.legacyManifestURL,
    ])
    #expect(UpdateController.currentManifestURL.host == "usaige-macos.richardqz.chatgpt.site")
    #expect(UpdateController.legacyManifestURL.host == "pmrichq.com")
}

@Test func migrationReleaseChoosesTheNewestValidFeed() throws {
    let current = UpdateManifest(
        version: "0.2.0",
        build: 21,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/current.dmg")),
        sha256: String(repeating: "a", count: 64)
    )
    let legacy = UpdateManifest(
        version: "0.2.0",
        build: 18,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/legacy.dmg")),
        sha256: String(repeating: "b", count: 64)
    )

    #expect(UpdateManifest.newest(in: [legacy, current]) == current)
    #expect(UpdateManifest.newest(in: [current, legacy]) == current)
}
