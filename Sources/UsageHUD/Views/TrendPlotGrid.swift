import SwiftUI

/// A square grid shared by the full-size resource charts and the floating CPU gauge.
struct TrendPlotGrid: View {
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rows = compact ? (size.height < 28 ? 2 : 3) : max(3, Int((size.height / 18).rounded()))
            let spacing = max(4, size.height / CGFloat(rows))
            let tint = Color(NSColor.systemTeal)
            let opacity = contrast == .increased ? 0.48 : (scheme == .dark ? 0.25 : 0.23)
            ZStack {
                tint.opacity(scheme == .dark ? 0.06 : 0.04)
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

    private func grid(size: CGSize, spacing: CGFloat, major: Bool) -> Path {
        Path { path in
            for column in 0...Int(size.width / spacing) where column.isMultiple(of: 4) == major {
                let x = CGFloat(column) * spacing
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...Int(size.height / spacing) where row.isMultiple(of: 4) == major {
                let y = CGFloat(row) * spacing
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }
}
