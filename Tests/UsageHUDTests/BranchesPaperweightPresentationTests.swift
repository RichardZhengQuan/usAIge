import Combine
import Foundation
import Testing
@testable import UsageHUD

@Suite
@MainActor
struct BranchesPaperweightPresentationTests {
    @Test func numberedPagesFollowTheSidebarAndFocusTheirClassicSections() {
        guard #available(macOS 14.0, *) else { return }
        let destinations: [(page: ModernPage, section: OverviewSection, front: PaperweightID?)] = [
            (.overview, .overview, nil),
            (.usage, .overview, nil),
            (.thisMac, .thisMac, nil),
            (.memory, .resources, .memory),
            (.storage, .resources, .storage),
            (.clean, .clean, nil),
            (.branches, .branches, nil),
            (.worktrees, .branches, nil),
            (.devices, .devices, nil),
        ]
        #expect(MainRootView.modernGroups.flatMap(\.pages) == destinations.map(\.page))

        for (page, section, front) in destinations {
            let presentation = BranchesPaperweightPresentation()
            presentation.navigate(to: .settings)
            presentation.navigate(to: .page(page))
            #expect(presentation.modernPage == page)
            #expect(presentation.selectedSection == section)
            #expect(presentation.focusRequest?.section == section)
            #expect(presentation.request?.front == front)
        }
    }

    @Test func thisMacIsASeparateDestinationInBothNavigationStyles() {
        guard #available(macOS 14.0, *) else { return }
        let presentation = BranchesPaperweightPresentation()
        #expect(ModernPage.thisMac.title == "CPU")
        #expect(MainPageDestination.thisMac.title == "CPU")
        #expect(MainRootView.modernGroups.first(where: { $0.pages.contains(.thisMac) })?.title == "Running")
        presentation.navigate(to: .thisMac)
        #expect(presentation.modernPage == .thisMac)
        #expect(presentation.selectedSection == .thisMac)
        presentation.open(.memory)
        #expect(presentation.selectedSection == .resources)
        presentation.open(.thisMac)
        #expect(presentation.selectedSection == .thisMac)
        presentation.focus(.devices)
        #expect(presentation.modernPage == .devices)
        presentation.open(.devices)
        #expect(presentation.selectedSection == .devices)
    }

    @Test func cleanFollowsStorageAndOpensTheSamePageFromEveryEntryPoint() throws {
        guard #available(macOS 14.0, *) else { return }
        let pages = try #require(MainRootView.modernGroups.first { $0.pages.contains(.storage) }?.pages)
        let storage = try #require(pages.firstIndex(of: .storage))
        #expect(pages.dropFirst(storage + 1).first == .clean)
        let presentation = BranchesPaperweightPresentation()
        presentation.open(.storage)
        presentation.open(.clean)
        #expect(presentation.selectedSection == .clean)
        presentation.show(.memory)
        presentation.navigate(to: .cleanup)
        #expect(presentation.modernPage == .clean)
        #expect(presentation.focusRequest?.section == .clean)
        presentation.show(.storage)
        #expect(presentation.modernPage == .storage)
    }

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
