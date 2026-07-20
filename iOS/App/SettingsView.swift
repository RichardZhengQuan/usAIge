import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Widget Data") {
                    Label(
                        model.isWidgetDataSharingAvailable ? "Ready" : "Unavailable",
                        systemImage: model.isWidgetDataSharingAvailable
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(model.isWidgetDataSharingAvailable ? .green : .orange)
                }
            } header: {
                Text("Home Screen Widget")
            } footer: {
                if model.isWidgetDataSharingAvailable {
                    Text("The app and widget can share the latest saved limits.")
                } else {
                    Text("Reinstall a build signed with the same App Group enabled for both the app and UsageWidget targets.")
                }
            }

            Section {
                Button {
                    Task { await openNotificationSettings() }
                } label: {
                    Label("iPhone Notification Settings", systemImage: "app.badge")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("usAIge session alerts are on by default. Manage permission, sounds, and Apple Watch mirroring in iPhone Settings.")
            }
        }
        .navigationTitle("Settings")
    }

    @MainActor
    private func openNotificationSettings() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            return
        }
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        _ = await UIApplication.shared.open(url)
    }
}
