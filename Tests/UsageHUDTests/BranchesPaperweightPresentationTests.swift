import Combine
import Foundation
import Testing
@testable import UsageHUD

@Suite
@MainActor
struct BranchesPaperweightPresentationTests {
    @Test func aRailClickBringsStorageForwardWithWorktreesSelected() {
        guard #available(macOS 14.0, *) else { return }
        let request = BranchesPaperweightPresentation.Request(front: .storage)
        let selection = request.selectedLayer(in: configuration(.storage, layers: ["other", "tool", "cache", "wt"]),
                                              currentFront: .memory, currentLayer: "tool-claude")
        #expect(selection == "wt")
    }

    @Test func aRailClickBringsMemoryForwardWithItsFirstToolSelected() {
        guard #available(macOS 14.0, *) else { return }
        let request = BranchesPaperweightPresentation.Request(front: .memory)
        let selection = request.selectedLayer(in: configuration(.memory, layers: ["tool-claude", "tool-chatGPT"]),
                                              currentFront: .storage, currentLayer: "cache")
        #expect(selection == "tool-claude")
    }

    @Test func clickingTheFrontPaperweightKeepsItsSelectedLayer() {
        guard #available(macOS 14.0, *) else { return }
        let request = BranchesPaperweightPresentation.Request(front: .storage)
        let selection = request.selectedLayer(in: configuration(.storage, layers: ["other", "tool", "cache", "wt"]),
                                              currentFront: .storage, currentLayer: "cache")
        #expect(selection == "cache")
    }

    @Test func emptyMemoryStillHasASelectableRemainder() {
        guard #available(macOS 14.0, *) else { return }
        let request = BranchesPaperweightPresentation.Request(front: .memory)
        #expect(request.selectedLayer(in: configuration(.memory, layers: []),
                                      currentFront: .storage, currentLayer: "wt") == "mfree")
    }

    @Test func repeatedRailClicksAreDistinctPresentationRequests() {
        guard #available(macOS 14.0, *) else { return }
        let presentation = BranchesPaperweightPresentation()
        var received: [BranchesPaperweightPresentation.Request] = []
        let subscription = presentation.$request.compactMap { $0 }.sink { received.append($0) }
        presentation.show(.memory)
        presentation.show(.storage)
        presentation.show(.storage)
        #expect(received.map(\.front) == [.memory, .storage, .storage])
        #expect(Set(received.map(\.id)).count == 3)
        withExtendedLifetime(subscription) {}
    }

    private func configuration(_ id: PaperweightID, layers: [String]) -> PaperweightConfiguration {
        PaperweightConfiguration(id: id, capacityBytes: 1_000, layers: layers.map {
            PaperweightLayer(id: $0, title: $0, bytes: 100, colorHex: 0, inkHex: 0)
        }, freeBytes: 500)
    }
}
