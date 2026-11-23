import SwiftUI

/// The grid and area shading fade together behind the measured trend line.
struct TrendPlotGrid: View {
    let compact: Bool
    let status: TrendStatus
    var areas: [TrendStatus: Path] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let spacing = Self.cellSide(for: size, compact: compact)
            let tint = status.color
            let opacity = contrast == .increased ? 0.66 : (scheme == .dark ? 0.46 : 0.39)
            ZStack {
                tint.opacity(scheme == .dark ? 0.10 : 0.065)
                grid(size: size, spacing: spacing, major: false)
                    .stroke(tint.opacity(opacity), lineWidth: 0.75)
                grid(size: size, spacing: spacing, major: true)
                    .stroke(tint.opacity(min(1, opacity * 1.25)), lineWidth: 0.9)
                ForEach(TrendStatus.allCases, id: \.self) { status in
                    if let area = areas[status] {
                        area.fill(LinearGradient(gradient: Gradient(colors: [status.color.opacity(0.19), .clear]),
                                                 startPoint: .top, endPoint: .bottom))
                    }
                }
            }
            .mask(centerEmphasis(in: size))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// An inscribed ellipse reaches zero opacity at each side, even on a wide sparkline.
    private func centerEmphasis(in size: CGSize) -> some View {
        let side = max(1, size.width, size.height)
        let gradient = Gradient(stops: [
            .init(color: .white, location: 0.38),
            .init(color: .white.opacity(0.90), location: 0.58),
            .init(color: .white.opacity(0.45), location: 0.76),
            .init(color: .white.opacity(0.08), location: 0.90),
            .init(color: .clear, location: 0.98),
        ])
        return RadialGradient(gradient: gradient, center: .center, startRadius: 0, endRadius: side / 2)
            .frame(width: side, height: side)
            .scaleEffect(x: size.width / side, y: size.height / side)
            .position(x: size.width / 2, y: size.height / 2)
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
            let columns = max(1, Int((size.width / spacing).rounded()))
            let rows = max(1, Int((size.height / spacing).rounded()))
            let xInset = (size.width - CGFloat(columns - 1) * spacing) / 2
            let yInset = (size.height - CGFloat(rows - 1) * spacing) / 2
            for column in 0..<columns where column.isMultiple(of: 4) == major {
                let x = xInset + CGFloat(column) * spacing
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0..<rows where row.isMultiple(of: 4) == major {
                let y = yInset + CGFloat(row) * spacing
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }
}
