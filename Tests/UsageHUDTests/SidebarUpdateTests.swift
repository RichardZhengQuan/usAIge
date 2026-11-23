import CryptoKit
import Foundation
import Testing
@testable import UsageHUD

private final class SidebarUpdateFixture: URLProtocol, @unchecked Sendable {
    static let payload = Data("test disk image".utf8)
    static let image = URL(string: "https://updates.example.invalid/image")!

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == image.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let data: Data
        if url.path == "/image" {
            data = Self.payload
        } else {
            // A verified offer whose image digest fails during installation.
            let manifest = UpdateManifest(version: "1.2", build: 1001, minimumSystemVersion: "11",
                                          downloadURL: Self.image, sha256: String(repeating: "0", count: 64))
            data = try! JSONEncoder().encode(manifest)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }
}

@Test func sidebarIsAbsentUntilANewerUpdateExists() {
    let hidden: [UpdateStatus] = [.idle, .checking, .upToDate, .unavailableInDevelopment, .failed("Offline")]
    #expect(hidden.allSatisfy { $0.sidebarManifest == nil })
}

@MainActor
@Test func installingFromSidebarKeepsSameOfferForProgressAndRetry() async throws {
    let suite = "usai.sidebar-update.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(1001, forKey: "update.lastNotifiedBuild")
    let session = SidebarUpdateFixture.session()
    defer { session.invalidateAndCancel() }
    let controller = UpdateController(session: session, userDefaults: defaults,
                                      manifestURLs: [URL(string: "https://updates.example.invalid/feed")!],
                                      signingKey: nil)
    await controller.checkForUpdates()
    let offer = try #require(controller.availableUpdate)
    var states: [UpdateStatus] = []
    let observer = controller.$status.sink { states.append($0) }
    defer { observer.cancel() }

    await controller.installAvailableUpdate()
    #expect(states.contains(.downloading(offer)))
    #expect(states.allSatisfy { $0.sidebarManifest == offer })
    guard case .installationFailed(let failedOffer, _) = controller.status else {
        Issue.record("Expected a retryable image verification failure")
        return
    }
    #expect(failedOffer == offer)
    #expect(controller.primaryButtonTitle == "Retry update")
    await controller.performPrimaryAction()
    #expect(states.filter { $0 == .downloading(offer) }.count == 2)
    #expect(!controller.isReplacementPrepared)
}

@Test func downloadRetainsVerifiedImageAfterURLSessionCallbackReturns() async throws {
    let session = SidebarUpdateFixture.session()
    defer { session.invalidateAndCancel() }
    let hash = SHA256.hash(data: SidebarUpdateFixture.payload).map { String(format: "%02x", $0) }.joined()
    let offer = UpdateManifest(version: "1.2", build: 1001, minimumSystemVersion: "11",
                               downloadURL: SidebarUpdateFixture.image, sha256: hash)
    let file = try await UpdateInstaller().download(manifest: offer, using: session)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: file) == SidebarUpdateFixture.payload)
}
