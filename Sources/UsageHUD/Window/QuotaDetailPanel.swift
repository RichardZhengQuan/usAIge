import AppKit
import SwiftUI

/// Where the hovered row's detail card sits: beside the rail on the right
/// when it fits and on the left otherwise, centred on the row and on screen,
/// with its arrow pointing back at the row.
@available(macOS 14.0, *)
struct QuotaDetailPlacement: Equatable {
    /// Leaves room for the arrow, whose tip stops just short of the rail.
    static let gap = QuotaDetailCardShape.arrowLength + 1

    let cardFrame: CGRect
    let arrowEdge: HorizontalEdge
    let arrowOffset: CGFloat

    init(cardSize size: CGSize, rail: CGRect, rowMidY: CGFloat, visibleFrame: CGRect) {
        let rightX = rail.maxX + Self.gap
        let fitsOnRight = rightX + size.width <= visibleFrame.maxX
        let x = fitsOnRight ? rightX : rail.minX - Self.gap - size.width
        let y = rowMidY - size.height / 2
        cardFrame = CGRect(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
        arrowEdge = fitsOnRight ? .leading : .trailing
        // Screen coordinates grow upward; the card's view coordinates grow downward.
        arrowOffset = cardFrame.midY - rowMidY
    }
}

/// Shows the hovered row's details in one panel kept for the life of the app.
///
/// SwiftUI's `.popover` can't be used here: on macOS 26 each new `NSPopover`
/// leaves its glass view and GPU surface behind when it closes, which adds up
/// to hundreds of megabytes on a rail that opens one for every hover.
@available(macOS 14.0, *)
@MainActor
final class QuotaDetailPanelController {
    private let railWindow: () -> NSWindow?
    private var hostingView: NSHostingView<QuotaDetailCard>?
    private var rowFrame = CGRect.zero
    private(set) var panel: NSPanel?
    private(set) var shownSnapshotID: String?

    init(rail: @escaping () -> NSWindow?) {
        railWindow = rail
    }

    /// Shows `snapshot` beside its row. `rowFrame` is in the rail's coordinates.
    func show(_ snapshot: QuotaSnapshot, rowFrame: CGRect) {
        shownSnapshotID = snapshot.id
        self.rowFrame = rowFrame
        present(snapshot)
    }

    /// Keeps the open card current as new usage arrives.
    func update(_ snapshots: [QuotaSnapshot]) {
        guard let shownSnapshotID else { return }
        if let snapshot = snapshots.first(where: { $0.id == shownSnapshotID }) {
            present(snapshot)
        } else {
            hide(snapshotID: shownSnapshotID)
        }
    }

    /// Hides the card if it still belongs to this row. When the pointer moves
    /// between rows, the new row's hover can arrive before the old row's exit.
    func hide(snapshotID: String) {
        guard shownSnapshotID == snapshotID else { return }
        shownSnapshotID = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ snapshot: QuotaSnapshot) {
        guard let rail = railWindow(), let railView = rail.contentView else { return }
        let cardView = cardView(showing: snapshot)
        let panel = self.panel ?? makePanel(contentView: cardView)
        self.panel = panel

        let inset = QuotaDetailCard.windowInset
        let fittingSize = cardView.fittingSize
        let rowOnScreen = rail.convertToScreen(railView.convert(rowFrame, to: nil))
        let screen = rail.screen ?? NSScreen.main
        let placement = QuotaDetailPlacement(
            cardSize: CGSize(width: fittingSize.width - inset * 2, height: fittingSize.height - inset * 2),
            rail: rail.frame,
            rowMidY: rowOnScreen.midY,
            visibleFrame: screen?.visibleFrame ?? rail.frame
        )
        cardView.rootView = QuotaDetailCard(
            snapshot: snapshot,
            arrowEdge: placement.arrowEdge,
            arrowOffset: placement.arrowOffset
        )
        panel.setFrame(placement.cardFrame.insetBy(dx: -inset, dy: -inset), display: true)
        panel.level = rail.level
        // As a child window the card follows the rail when it is dragged.
        if panel.parent == nil { rail.addChildWindow(panel, ordered: .above) }
    }

    private func cardView(showing snapshot: QuotaSnapshot) -> NSHostingView<QuotaDetailCard> {
        let card = QuotaDetailCard(snapshot: snapshot)
        if let hostingView {
            hostingView.rootView = card
            return hostingView
        }
        let view = NSHostingView(rootView: card)
        hostingView = view
        return view
    }

    private func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 316, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = contentView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The card shows information only, and must not take hover from the rail.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}
