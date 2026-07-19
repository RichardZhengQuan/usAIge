import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.connections.isEmpty {
                    Label("Connect a Mac to configure alerts.", systemImage: "laptopcomputer")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.connections, id: \.channelID) { connection in
                        Toggle(isOn: sessionActivityBinding(for: connection.channelID)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.macName)
                                Text("Finished, errors, and permission requests")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = model.errorMessage(for: connection.channelID) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Session Activity")
            } footer: {
                Text("Control alerts separately for each Mac. Alerts also mirror to Apple Watch when notification mirroring is enabled.")
            }

            Section("System") {
                Link(destination: URL(string: UIApplication.openNotificationSettingsURLString)!) {
                    Label("iPhone Notification Settings", systemImage: "app.badge")
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func sessionActivityBinding(for connectionID: UUID) -> Binding<Bool> {
        Binding(
            get: { model.sessionNotificationsEnabled(for: connectionID) },
            set: { enabled in
                Task {
                    await model.setSessionNotificationsEnabled(enabled, for: connectionID)
                }
            }
        )
    }
}
