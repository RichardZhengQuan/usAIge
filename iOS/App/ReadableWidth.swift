import SwiftUI

extension View {
    func readableListWidth() -> some View {
        modifier(ReadableListWidth())
    }
}

private struct ReadableListWidth: ViewModifier {
    /// About the width of an iPhone Pro Max: wide enough for a tool's bars,
    /// narrow enough that they stay easy to read across.
    static let maximumWidth: CGFloat = 640

    @State private var horizontalMargin: CGFloat?

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat?.self) { geometry in
                let margin = (geometry.size.width - Self.maximumWidth) / 2
                return margin > 0 ? margin : nil
            } action: { margin in
                horizontalMargin = margin
            }
    }
}
