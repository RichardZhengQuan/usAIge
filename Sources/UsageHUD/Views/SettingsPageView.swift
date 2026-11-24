import SwiftUI

/// The sidebar keeps the install action, its progress, and any retry in one place.
@available(macOS 14.0, *)
struct SidebarUpdateReminderView: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        if let update = updateController.status.sidebarManifest {
            VStack(alignment: .leading, spacing: 5) {
                switch updateController.status {
                case .available:
                    installButton("Update to \(update.version)", symbol: "arrow.down.circle.fill")
                case let .installationFailed(_, message):
                    installButton("Retry update", symbol: "arrow.clockwise.circle")
                        .help(message)
                    Text(message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(message)
                case .downloading:
                    Text("Downloading \(update.version)…").font(.callout.weight(.medium))
                    if let progress = updateController.downloadProgress {
                        ProgressView(progress).labelsHidden().progressViewStyle(.linear)
                            .accessibilityLabel("Download progress")
                    } else {
                        ProgressView("Starting download").labelsHidden().progressViewStyle(.linear)
                    }
                case .preparing:
                    Text("Preparing \(update.version)…").font(.callout.weight(.medium))
                    ProgressView("Verifying and preparing update").labelsHidden().progressViewStyle(.linear)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 14)
        }
    }

    private func installButton(_ title: String, symbol: String) -> some View {
        Button {
            Task { await updateController.installAvailableUpdate() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
