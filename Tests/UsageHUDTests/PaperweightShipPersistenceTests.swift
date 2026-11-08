import Foundation
import SceneKit
import Testing
@testable import UsageHUD

@Suite("Paperweight ship persistence")
@MainActor
struct PaperweightShipPersistenceTests {
    @Test func newStoresUseThePrototypeShips() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BranchesStore(defaults: defaults)

        #expect(store.memoryShip == .sailboat)
        #expect(store.storageShip == .galleon)
        #expect(store.ship(for: .memory) == .sailboat)
        #expect(store.ship(for: .storage) == .galleon)
    }

    @Test(arguments: PaperweightShipKind.allCases)
    func eachShipChoiceSurvivesReopeningWithoutChangingTheOtherPaperweight(_ ship: PaperweightShipKind) {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BranchesStore(defaults: defaults)

        store.chooseShip(ship, for: .memory)
        let afterMemoryChoice = BranchesStore(defaults: defaults)
        #expect(afterMemoryChoice.ship(for: .memory) == ship)
        #expect(afterMemoryChoice.ship(for: .storage) == .galleon)

        afterMemoryChoice.chooseShip(ship, for: .storage)
        let afterStorageChoice = BranchesStore(defaults: defaults)
        #expect(afterStorageChoice.ship(for: .memory) == ship)
        #expect(afterStorageChoice.ship(for: .storage) == ship)

        let otherShip: PaperweightShipKind = ship == .tug ? .viking : .tug
        afterStorageChoice.chooseShip(otherShip, for: .memory)
        let reopened = BranchesStore(defaults: defaults)
        #expect(reopened.ship(for: .memory) == otherShip)
        #expect(reopened.ship(for: .storage) == ship)
    }

    @Test func removedOrInvalidShipNamesFallBackToEachPaperweightsDefault() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-ship", forKey: "usageHUD.branches.memoryShip.v1")
        defaults.set("not-a-ship", forKey: "usageHUD.branches.storageShip.v1")

        let store = BranchesStore(defaults: defaults)

        #expect(store.ship(for: .memory) == .sailboat)
        #expect(store.ship(for: .storage) == .galleon)
    }

    @Test func everyShipStaysInsideTheGlassAtTheMaximumRoll() {
        guard #available(macOS 14.0, *) else { return }
        let unit = PaperweightConstants.unitsPerPixel
        for kind in PaperweightShipKind.allCases {
            let ship = PaperweightShipFactory.make(kind)
            var leaves: [SCNNode] = []
            ship.enumerateChildNodes { node, _ in if node.geometry != nil { leaves.append(node) } }
            var side = 0.0, top = 0.0, bottom = 0.0, depth = 0.0
            for leaf in leaves {
                let bounds = leaf.geometry!.boundingBox
                for x in [bounds.min.x, bounds.max.x] {
                    for y in [bounds.min.y, bounds.max.y] {
                        for z in [bounds.min.z, bounds.max.z] {
                            let point = leaf.convertPosition(SCNVector3(x, y, z), to: nil)
                            let px = Double(point.x), py = Double(point.y)
                            depth = max(depth, abs(Double(point.z)))
                            // Each primitive keeps its own bounds, so the bow's
                            // furthest point is not combined with another mast's top.
                            var angles = [-PaperweightConstants.maximumRoll, 0, PaperweightConstants.maximumRoll]
                            for base in [atan2(-py, px), atan2(px, py)] {
                                for turn in -2...2 {
                                    let angle = base + Double(turn) * .pi
                                    if abs(angle) <= PaperweightConstants.maximumRoll { angles.append(angle) }
                                }
                            }
                            for angle in angles {
                                let projectedX = px * cos(angle) - py * sin(angle)
                                let projectedY = px * sin(angle) + py * cos(angle)
                                side = max(side, abs(projectedX))
                                top = max(top, projectedY)
                                bottom = min(bottom, projectedY)
                            }
                        }
                    }
                }
            }
            print(String(format: "[ship-bounds] %@ side %.3f px, top %.3f px, bottom %.3f px, depth %.3f",
                         kind.rawValue, side / unit, top / unit, bottom / unit, depth))
            #expect(side <= PaperweightConstants.boatMargin * unit + 0.000_001,
                    "\(kind.title) needs more room beside the water's boat stop")
            #expect(top <= PaperweightConstants.boatHeight * unit + 0.000_001,
                    "\(kind.title)'s mast must stay beneath the lid")
            #expect(bottom >= -PaperweightConstants.boatDraft * unit - 0.000_001,
                    "\(kind.title)'s keel must stay above the glass floor")
            #expect(depth <= PaperweightConstants.ZF,
                    "\(kind.title) must fit between the front and back glass")
        }
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "PaperweightShipPersistenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
