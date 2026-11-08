import SwiftUI

/// The sidebar opens the Settings page to review an update. Installing remains
/// an explicit action in Settings, using the app's shared update controller.
@available(macOS 14.0, *)
struct SidebarUpdateReminderView: View {
    @ObservedObject var updateController: UpdateController
    var openSettings: () -> Void

    var body: some View {
        Button {
            openSettings()
            if !updateController.canInstallUpdate && !isBusy,
               updateController.status != .unavailableInDevelopment {
                Task { await updateController.checkForUpdates() }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(updateController.canInstallUpdate ? .semibold : .regular))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: updateController.canInstallUpdate
                          ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                }
            }
            .foregroundStyle(updateController.canInstallUpdate ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .help(updateController.canInstallUpdate ? "Review and install this update in Settings" : "Check for updates in Settings")
    }

    private var title: String {
        switch updateController.status {
        case .available: "Update available"
        case .checking: "Checking for updates…"
        case .downloading: "Downloading update…"
        case .preparing: "Preparing update…"
        case .failed: "Retry Update Check"
        default: "Check for Updates"
        }
    }

    private var detail: String {
        if let update = updateController.availableUpdate {
            return "Version \(update.version) is ready"
        }
        if updateController.status == .idle {
            return "Version \(updateController.currentVersionText)"
        }
        return updateController.statusText
    }

    private var isBusy: Bool {
        switch updateController.status {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }
}
