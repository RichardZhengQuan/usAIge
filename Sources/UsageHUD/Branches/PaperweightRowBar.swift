import SwiftUI

extension StorageCategory {
    var tint: Color {
        let hex: UInt32 = switch self {
        case .worktrees: 0xE2729A
        case .buildCache: 0x3DB58C
        case .toolStorage: 0xF4B14A
        }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

/// List bars carry the selected liquid's colour without any animation clock.
@available(macOS 14.0, *)
struct PaperweightRowBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(color.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.75))
                        .frame(width: geometry.size.width * min(1, max(0, share)))
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
