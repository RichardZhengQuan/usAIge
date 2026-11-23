import Foundation
import SwiftUI

enum ResetCreditText {
    static func accessibilityLabel(count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        if count == 1 {
            return String(localized: "\(count) full reset available")
        }
        return String(localized: "\(count) full resets available")
    }
}

struct ResetCreditBadge: View {
    let count: Int?

    var body: some View {
        if let count, let label = ResetCreditText.accessibilityLabel(count: count) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Image(systemName: "arrow.counterclockwise")
                Text(count, format: .number)
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.green)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
        }
    }
}
