import SwiftUI

/// Vector renditions of each built-in tool's mark, drawn in the current
/// foreground color so they read like the template icons the installed apps
/// provide. They are the fallback when a vendor template is unavailable and
/// the only source for tools without a macOS app, such as Grok Build.
enum BrandMark {
    /// ChatGPT has no vector mark: its template ships with the ChatGPT app,
    /// and the generic symbol is a better fallback than an approximate knot.
    static func hasMark(for id: AIToolID) -> Bool {
        [.claude, .cursor, .grok, .gemini].contains(id)
    }
}

struct BrandMarkView: View {
    let toolID: AIToolID

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let rect = CGRect(
                x: (proxy.size.width - side) / 2,
                y: (proxy.size.height - side) / 2,
                width: side,
                height: side
            )
            ZStack {
                switch toolID {
                case .claude: ClaudeSparkMark(rect: rect)
                case .cursor: CursorCubeMark(rect: rect)
                case .grok: GrokDiscMark(rect: rect)
                case .gemini: GeminiSparkMark(rect: rect)
                default: EmptyView()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Claude's starburst: spokes of alternating length with rounded ends.
private struct ClaudeSparkMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Claude's spark has uneven rays; keep a fixed, slightly irregular
            // pattern so it reads as the mark rather than a sun symbol.
            let lengths: [Double] = [0.47, 0.30, 0.40, 0.33, 0.46, 0.29, 0.42, 0.35, 0.47, 0.31, 0.39, 0.34]
            let spokes = lengths.count
            for (index, factor) in lengths.enumerated() {
                let angle = Double(index) / Double(spokes) * 2 * .pi - .pi / 2 + (index.isMultiple(of: 3) ? 0.08 : -0.05)
                let length = rect.width * factor
                let inner = rect.width * 0.05
                path.move(to: CGPoint(
                    x: center.x + cos(angle) * inner,
                    y: center.y + sin(angle) * inner
                ))
                path.addLine(to: CGPoint(
                    x: center.x + cos(angle) * length,
                    y: center.y + sin(angle) * length
                ))
            }
        }
        .stroke(style: StrokeStyle(lineWidth: rect.width * 0.11, lineCap: .round))
    }
}

/// Cursor's isometric cube: a hexagon with the three inner edges, the top
/// face filled a little lighter so the cube reads as a solid.
private struct CursorCubeMark: View {
    let rect: CGRect

    private var vertices: [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.46
        return (0..<6).map { index in
            let angle = Double(index) * .pi / 3 - .pi / 2
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    var body: some View {
        let points = vertices
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ZStack {
            Path { path in
                path.move(to: points[0])
                path.addLine(to: points[1])
                path.addLine(to: center)
                path.addLine(to: points[5])
                path.closeSubpath()
            }
            .fill(Color.primary.opacity(0.28))
            Path { path in
                path.move(to: points[5])
                path.addLine(to: center)
                path.addLine(to: points[3])
                path.addLine(to: points[4])
                path.closeSubpath()
            }
            .fill(Color.primary.opacity(0.62))
            Path { path in
                path.addLines(points)
                path.closeSubpath()
                for index in [0, 2, 4] {
                    path.move(to: center)
                    path.addLine(to: points[index])
                }
            }
            .stroke(style: StrokeStyle(lineWidth: rect.width * 0.07, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Grok's mark: a disc drawn as a ring open on the right, with its lower end
/// sweeping into the middle like a "G".
private struct GrokDiscMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width * 0.36
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(14),
                endAngle: .degrees(318),
                clockwise: false
            )
            let tailY = center.y + sin(14 * Double.pi / 180) * radius
            path.move(to: CGPoint(x: center.x + cos(14 * Double.pi / 180) * radius, y: tailY))
            path.addLine(to: CGPoint(x: center.x - radius * 0.05, y: tailY))
        }
        .stroke(style: StrokeStyle(lineWidth: rect.width * 0.17, lineCap: .round, lineJoin: .round))
    }
}

/// Gemini's four-point spark with concave sides.
private struct GeminiSparkMark: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = rect.width * 0.5
            let pinch = rect.width * 0.11
            let top = CGPoint(x: center.x, y: center.y - outer)
            let right = CGPoint(x: center.x + outer, y: center.y)
            let bottom = CGPoint(x: center.x, y: center.y + outer)
            let left = CGPoint(x: center.x - outer, y: center.y)
            path.move(to: top)
            path.addQuadCurve(to: right, control: CGPoint(x: center.x + pinch, y: center.y - pinch))
            path.addQuadCurve(to: bottom, control: CGPoint(x: center.x + pinch, y: center.y + pinch))
            path.addQuadCurve(to: left, control: CGPoint(x: center.x - pinch, y: center.y + pinch))
            path.addQuadCurve(to: top, control: CGPoint(x: center.x - pinch, y: center.y - pinch))
            path.closeSubpath()
        }
        .fill()
    }
}
