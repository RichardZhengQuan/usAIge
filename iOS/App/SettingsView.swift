import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    var body: some View {
        Form {
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
