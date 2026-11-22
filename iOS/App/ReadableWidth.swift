import SwiftUI

extension View {
    func readableListWidth() -> some View {
        modifier(ReadableListWidth())
    }
}

private struct ReadableListWidth: ViewModifier {
    @State private var horizontalMargin: CGFloat?

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat?.self) { geometry in
                let margin = (geometry.size.width - 700) / 2
                return margin > 0 ? margin : nil
            } action: { margin in
                horizontalMargin = margin
            }
    }
}
