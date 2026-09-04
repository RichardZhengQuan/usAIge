import CryptoKit
import Foundation
import Testing
@testable import UsageHUD

@Test func updateManifestUsesBuildNumberForAvailability() throws {
    let manifest = UpdateManifest(
        version: "0.2.1",
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
        version: "0.2.1",
        build: 8,
        minimumSystemVersion: "15.0",
        downloadURL: try #require(URL(string: "http://example.com/usAIge.dmg")),
        sha256: "not-a-hash"
    )

    #expect(throws: UpdateError.self) { try insecure.validate() }
}

@Test func updateManifestRejectsVersionsThatAreNotPlainVersionText() throws {
    for version in ["../../injected", "0.2 beta", "", String(repeating: "9", count: 41)] {
        let manifest = UpdateManifest(
            version: version,
            build: 8,
            minimumSystemVersion: "11.0",
            downloadURL: try #require(URL(string: "https://example.com/usAIge.dmg")),
            sha256: String(repeating: "a", count: 64)
        )
        #expect(throws: UpdateError.self) { try manifest.validate() }
    }
    let manifest = UpdateManifest(
        version: "0.2.14-beta_1",
        build: 8,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/usAIge.dmg")),
        sha256: String(repeating: "a", count: 64)
    )
    #expect(throws: Never.self) { try manifest.validate() }
}

@Test func releaseSigningKeyIsPinned() throws {
    // Without a pinned key the whole manifest signature path is skipped.
    #expect(UpdateSigning.pinnedPublicKey != nil)
}

@Test func updateManifestAcceptsAndValidatesReleaseNotes() throws {
    let data = Data(#"""
    {
      "version":"0.2.2",
      "build":24,
      "minimumSystemVersion":"11.0",
      "downloadURL":"https://example.com/usAIge.dmg",
      "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "releaseNotes":{
        "headline":"A clearer update",
        "summary":"See what changed before installing.",
        "highlights":[{"title":"What’s New","detail":"Read the release highlights in the app.","systemImage":"sparkles"}]
      }
    }
    """#.utf8)
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

    #expect(manifest.releaseNotes?.highlights.first?.title == "What’s New")
    #expect(throws: Never.self) { try manifest.validate() }
}

@Test func updateStatusUsesCheckAndUpToDateCopy() throws {
    #expect(UpdateStatus.idle.primaryButtonTitle == "Check for Updates")
    #expect(UpdateStatus.upToDate.primaryButtonTitle == "Check for Updates")
    #expect(UpdateStatus.upToDate.isPrimaryActionEnabled)
    #expect(!UpdateStatus.checking.isPrimaryActionEnabled)

    let manifest = UpdateManifest(
        version: "0.2.1",
        build: 8,
        minimumSystemVersion: "15.0",
        downloadURL: try #require(URL(string: "https://example.com/usAIge.dmg")),
        sha256: String(repeating: "a", count: 64)
    )
    #expect(UpdateStatus.available(manifest).primaryButtonTitle == "Update to 0.2.1")
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
    #expect(manifest.releaseNotes?.highlights.isEmpty == false)
    #expect(
        plist["UpdateManifestURLs"] as? [String]
            == UpdateController.defaultManifestURLs.map(\.absoluteString)
    )
}

@Test func bundledReleaseNotesMatchThePackagedVersion() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistData = try Data(contentsOf: projectRoot.appendingPathComponent(
        "Sources/UsageHUD/Resources/Info.plist"
    ))
    let plist = try #require(
        PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    )
    let notesData = try Data(contentsOf: projectRoot.appendingPathComponent(
        "Sources/UsageHUD/Resources/ReleaseNotes.json"
    ))
    let document = try JSONDecoder().decode(ReleaseNotesDocument.self, from: notesData)
    let manifestData = try Data(contentsOf: projectRoot.appendingPathComponent(
        "site/public/update.json"
    ))
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)

    #expect(document.version == plist["CFBundleShortVersionString"] as? String)
    #expect(document.build == Int(plist["CFBundleVersion"] as? String ?? ""))
    #expect(document.releaseNotes == manifest.releaseNotes)
    #expect(throws: Never.self) { try document.releaseNotes.validate() }
}

@Test func migrationReleaseChecksCurrentAndLegacyUpdateFeeds() {
    #expect(UpdateController.defaultManifestURLs == [
        UpdateController.currentManifestURL,
        UpdateController.legacyManifestURL,
    ])
    #expect(UpdateController.currentManifestURL.host == "usaige-macos.richardqz.chatgpt.site")
    #expect(UpdateController.legacyManifestURL.host == "pmrichq.com")
}

@Test func updateManifestRequestsBypassCachedReleaseData() throws {
    let url = try #require(URL(string: "https://example.com/update.json"))
    let request = UpdateController.manifestRequest(for: url)

    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 30)
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
}

@Test func updateChecksRepeatWithinThirtyMinutes() {
    #expect(
        UpdateController.automaticCheckIntervalNanoseconds
            == UInt64(30 * 60 * 1_000_000_000)
    )
}

@Test func migrationReleaseChoosesTheNewestValidFeed() throws {
    let current = UpdateManifest(
        version: "0.2.1",
        build: 23,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/current.dmg")),
        sha256: String(repeating: "a", count: 64)
    )
    let legacy = UpdateManifest(
        version: "0.2.0",
        build: 22,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/legacy.dmg")),
        sha256: String(repeating: "b", count: 64)
    )

    #expect(UpdateManifest.newest(in: [legacy, current]) == current)
    #expect(UpdateManifest.newest(in: [current, legacy]) == current)
}

@Test func updateManifestSignatureIsVerifiedAgainstThePinnedKey() throws {
    let key = Curve25519.Signing.PrivateKey()
    var manifest = UpdateManifest(
        version: "0.2.14",
        build: 36,
        minimumSystemVersion: "11.0",
        downloadURL: try #require(URL(string: "https://example.com/usAIge-0.2.14-alpha.dmg")),
        sha256: String(repeating: "b", count: 64)
    )

    #expect(throws: UpdateError.self) { try manifest.verifySignature(publicKey: key.publicKey) }

    manifest.signature = try key.signature(for: manifest.signedPayload).base64EncodedString()
    #expect(throws: Never.self) { try manifest.verifySignature(publicKey: key.publicKey) }

    // Release notes are outside the signed payload; the build is inside it.
    manifest.releaseNotes = ReleaseNotes(headline: "Edited", summary: "Wording only.", highlights: [])
    #expect(throws: Never.self) { try manifest.verifySignature(publicKey: key.publicKey) }
    // So is the download URL: the legacy site export rewrites it for its host,
    // and the signed SHA-256 already pins the disk image it may point at.
    let rehosted = UpdateManifest(
        version: manifest.version,
        build: manifest.build,
        minimumSystemVersion: manifest.minimumSystemVersion,
        downloadURL: try #require(URL(string: "https://pmrichq.com/project/usaige/usAIge-0.2.14-alpha.dmg")),
        sha256: manifest.sha256,
        signature: manifest.signature
    )
    #expect(throws: Never.self) { try rehosted.verifySignature(publicKey: key.publicKey) }
    let swappedImage = UpdateManifest(
        version: manifest.version,
        build: manifest.build,
        minimumSystemVersion: manifest.minimumSystemVersion,
        downloadURL: manifest.downloadURL,
        sha256: String(repeating: "c", count: 64),
        signature: manifest.signature
    )
    #expect(throws: UpdateError.self) { try swappedImage.verifySignature(publicKey: key.publicKey) }
    let tampered = UpdateManifest(
        version: manifest.version,
        build: 37,
        minimumSystemVersion: manifest.minimumSystemVersion,
        downloadURL: manifest.downloadURL,
        sha256: manifest.sha256,
        signature: manifest.signature
    )
    #expect(throws: UpdateError.self) { try tampered.verifySignature(publicKey: key.publicKey) }
    #expect(throws: UpdateError.self) {
        try manifest.verifySignature(publicKey: Curve25519.Signing.PrivateKey().publicKey)
    }
}

@Test func updateManifestSignatureRoundTripsThroughJSON() throws {
    let data = Data(#"""
    {"version":"0.2.14","build":36,"minimumSystemVersion":"11.0",
     "downloadURL":"https://example.com/usAIge.dmg",
     "sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     "signature":"AAAA"}
    """#.utf8)
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
    #expect(manifest.signature == "AAAA")
    #expect(String(decoding: manifest.signedPayload, as: UTF8.self)
        == "usaige-update-v2\n0.2.14\n36\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n")
}

@Test func teamIdentifierIsNilForAdHocSignedBundles() {
    // The test bundle is ad-hoc signed (or unsigned) on every developer Mac
    // and CI runner, so the check must not misreport a team there.
    #expect(UpdateInstaller.teamIdentifier(ofApplicationAt: Bundle.main.bundleURL) == nil)
}
