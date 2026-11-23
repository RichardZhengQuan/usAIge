import SwiftUI

/// A square grid shared by the full-size resource charts and the floating CPU gauge.
struct TrendPlotGrid: View {
    let compact: Bool
    let status: TrendStatus
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let spacing = Self.cellSide(for: size, compact: compact)
            let tint = status.color
            let opacity = contrast == .increased ? 0.48 : (scheme == .dark ? 0.25 : 0.23)
            ZStack {
                tint.opacity(scheme == .dark ? 0.085 : 0.055)
                grid(size: size, spacing: spacing, major: false)
                    .stroke(tint.opacity(opacity), lineWidth: 0.6)
                grid(size: size, spacing: spacing, major: true)
                    .stroke(tint.opacity(min(1, opacity * 1.35)), lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 2 : 4))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Use two rows on a typical chart and limit columns on a wide Overview card.
    static func cellSide(for size: CGSize, compact: Bool) -> CGFloat {
        let rows: CGFloat = compact && size.height < 28 ? 1.5 : (size.height >= 160 ? 3 : 2)
        let columns: CGFloat = compact ? 5 : 11
        return max(5, size.height / rows, size.width / columns)
    }

    private func grid(size: CGSize, spacing: CGFloat, major: Bool) -> Path {
        Path { path in
            guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
            let columns = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            let xInset = (size.width - CGFloat(columns) * spacing) / 2
            let yInset = (size.height - CGFloat(rows) * spacing) / 2
            for column in 0...columns where column.isMultiple(of: 4) == major {
                let x = xInset + CGFloat(column) * spacing
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...rows where row.isMultiple(of: 4) == major {
                let y = yInset + CGFloat(row) * spacing
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }
}
