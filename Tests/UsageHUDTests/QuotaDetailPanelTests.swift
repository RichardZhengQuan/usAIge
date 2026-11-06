import AppKit
import SwiftUI
import Testing
@testable import UsageHUD

@Suite struct QuotaDetailPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    private let size = CGSize(width: 260, height: 120)

    @Test func opensToTheRightOfTheRailWhenItFits() {
        let placement = QuotaDetailPlacement(
            cardSize: size,
            rail: CGRect(x: 20, y: 200, width: 84, height: 400),
            rowMidY: 400,
            visibleFrame: screen
        )
        #expect(placement.cardFrame.minX == 104 + QuotaDetailPlacement.gap)
        #expect(placement.cardFrame.midY == 400)
        #expect(placement.arrowEdge == .leading)
        #expect(placement.arrowOffset == 0)
    }

    @Test func opensToTheLeftWhenTheRailIsAtTheRightEdge() {
        let placement = QuotaDetailPlacement(
            cardSize: size,
            rail: CGRect(x: 916, y: 200, width: 84, height: 400),
            rowMidY: 400,
            visibleFrame: screen
        )
        #expect(placement.cardFrame.maxX == 916 - QuotaDetailPlacement.gap)
        #expect(placement.arrowEdge == .trailing)
    }

    @Test func staysOnScreenAndStillPointsAtRowsNearTheScreenEnds() {
        let rail = CGRect(x: 20, y: 0, width: 84, height: 800)
        let top = QuotaDetailPlacement(cardSize: size, rail: rail, rowMidY: 790, visibleFrame: screen)
        let bottom = QuotaDetailPlacement(cardSize: size, rail: rail, rowMidY: 10, visibleFrame: screen)
        #expect(top.cardFrame.maxY == screen.maxY)
        #expect(bottom.cardFrame.minY == screen.minY)
        // A row above the card's centre points up, which is negative in view coordinates.
        #expect(top.arrowOffset == -50)
        #expect(bottom.arrowOffset == 50)
    }

    @Test func theArrowExtendsOnlyTowardTheRail() {
        let rect = CGRect(x: 0, y: 0, width: 278, height: 120)
        let leading = QuotaDetailCardShape(arrowEdge: .leading, arrowOffset: 0).path(in: rect).boundingRect
        let trailing = QuotaDetailCardShape(arrowEdge: .trailing, arrowOffset: 0).path(in: rect).boundingRect
        #expect(leading.minX < QuotaDetailCardShape.arrowLength)
        #expect(leading.maxX <= rect.maxX - QuotaDetailCardShape.arrowLength + 0.5)
        #expect(trailing.maxX > rect.maxX - QuotaDetailCardShape.arrowLength)
        #expect(trailing.minX >= QuotaDetailCardShape.arrowLength - 0.5)
    }

    @Test func aFarAwayRowCannotPushTheArrowOffTheCard() {
        let rect = CGRect(x: 0, y: 0, width: 278, height: 120)
        let bounds = QuotaDetailCardShape(arrowEdge: .leading, arrowOffset: 1_000).path(in: rect).boundingRect
        #expect(bounds.maxY <= rect.maxY + 0.5)
        #expect(bounds.minY >= rect.minY - 0.5)
    }
}

@Suite struct RailMotionTests {
    @Test func breathingFollowsTheKeyframesAndRepeats() {
        let step = AgentBreathingMotion.keyframeDuration
        #expect(abs(AgentBreathingMotion.thickness(at: 0) - 4) < 0.001)
        #expect(abs(AgentBreathingMotion.thickness(at: step) - 2) < 0.001)
        #expect(abs(AgentBreathingMotion.thickness(at: step * 2) - 4) < 0.001)
        #expect(abs(AgentBreathingMotion.thickness(at: step * 3) - 6) < 0.001)
        #expect(abs(AgentBreathingMotion.thickness(at: step * 4) - 4) < 0.001)
        #expect(abs(AgentBreathingMotion.thickness(at: step * 40 + step) - 2) < 0.001)
    }

    @Test func breathingStaysWithinItsLimits() {
        for tick in 0..<400 {
            let thickness = AgentBreathingMotion.thickness(at: Double(tick) * 0.05)
            #expect(thickness >= AgentBreathingMotion.minimumThickness - 0.001)
            #expect(thickness <= AgentBreathingMotion.maximumThickness + 0.001)
        }
    }

    @Test func criticalPulseEasesBetweenItsLimits() {
        #expect(abs(CriticalPulseMotion.value(at: 0)) < 0.001)
        #expect(abs(CriticalPulseMotion.value(at: CriticalPulseMotion.period / 2) - 1) < 0.001)
        #expect(abs(CriticalPulseMotion.value(at: CriticalPulseMotion.period)) < 0.001)
    }
}

@MainActor
@Suite struct QuotaDetailPanelControllerTests {
    private func makeRail() -> NSPanel {
        NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 84, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    private func snapshot(id: String) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id,
            displayName: Fixtures.codexSnapshot.displayName,
            usedPercent: 25,
            remainingPercent: 75,
            resetAt: Fixtures.codexSnapshot.resetAt,
            windowDurationMinutes: 300,
            planType: nil,
            updatedAt: Fixtures.codexSnapshot.updatedAt
        )
    }

    @Test func reusesOnePanelForEveryHover() {
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })

        controller.show(snapshot(id: "a"), rowFrame: CGRect(x: 4, y: 10, width: 76, height: 80))
        let first = controller.panel
        #expect(first != nil)
        #expect(first?.parent === rail)

        for id in ["b", "c", "a"] {
            controller.hide(snapshotID: controller.shownSnapshotID ?? "")
            #expect(first?.parent == nil)
            controller.show(snapshot(id: id), rowFrame: CGRect(x: 4, y: 10, width: 76, height: 80))
            #expect(controller.panel === first)
        }
    }

    @Test func aLateExitFromThePreviousRowDoesNotHideTheNewOne() {
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })

        controller.show(snapshot(id: "a"), rowFrame: .zero)
        controller.show(snapshot(id: "b"), rowFrame: .zero)
        controller.hide(snapshotID: "a")

        #expect(controller.shownSnapshotID == "b")
        #expect(controller.panel?.parent === rail)
    }

    @Test func hidesWhenTheShownRowLeavesTheRail() {
        let rail = makeRail()
        let controller = QuotaDetailPanelController(rail: { rail })

        controller.show(snapshot(id: "a"), rowFrame: .zero)
        controller.update([snapshot(id: "a"), snapshot(id: "b")])
        #expect(controller.shownSnapshotID == "a")

        controller.update([snapshot(id: "b")])
        #expect(controller.shownSnapshotID == nil)
        #expect(controller.panel?.parent == nil)
    }
}
