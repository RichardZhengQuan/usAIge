import AppKit
import SwiftUI

struct IconVisibilityToggle: View {
    enum Location {
        case menuBar
        case dock
    }

    let location: Location
    @Binding var isOn: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(AppLanguage.text(title, locale: locale), isOn: $isOn)
            Group {
                switch location {
                case .menuBar: menuBarPreview
                case .dock: dockPreview
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch location {
        case .menuBar: "Show icon in menu bar"
        case .dock: "Show icon in Dock"
        }
    }

    private var menuBarPreview: some View {
        HStack(spacing: 9) {
            Image(nsImage: MenuBarIconController.gaugeImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 13)
                .foregroundColor(.primary)
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(previewBackground(cornerRadius: 5))
    }

    private var dockPreview: some View {
        HStack(alignment: .top, spacing: 7) {
            dockNeighbor("face.smiling")
            VStack(spacing: 2) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
            }
            dockNeighbor("folder.fill")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(previewBackground(cornerRadius: 11))
    }

    private func dockNeighbor(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }

    private func previewBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
    }
}
