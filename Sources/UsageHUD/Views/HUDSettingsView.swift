import AppKit
import SwiftUI

struct HUDSettingsView: View {
    @Bindable var settings: HUDSettings
    let snapshots: [QuotaSnapshot]

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Opacity") {
                    Slider(value: binding(for: \HUDSettings.opacity), in: 0.4...1.0)
                        .frame(width: 180)
                }
                LabeledContent("Scale") {
                    Slider(value: binding(for: \HUDSettings.scale), in: 0.75...1.5)
                        .frame(width: 180)
                }
            }

            Section("Visible quotas") {
                if snapshots.isEmpty {
                    Text("Quota controls appear after Codex reports usage data.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.bucketOrder, id: \.self) { id in
                        if let snapshot = snapshots.first(where: { $0.id == id }) {
                            HStack {
                                Toggle(
                                    snapshot.displayName,
                                    isOn: Binding(
                                        get: { !settings.hiddenBucketIDs.contains(id) },
                                        set: { visible in
                                            if visible { settings.hiddenBucketIDs.remove(id) }
                                            else { settings.hiddenBucketIDs.insert(id) }
                                        }
                                    )
                                )
                                Spacer()
                                Button { settings.moveBucket(id, by: -1) } label: {
                                    Image(systemName: "chevron.up")
                                }
                                Button { settings.moveBucket(id, by: 1) } label: {
                                    Image(systemName: "chevron.down")
                                }
                            }
                        }
                    }
                }
            }

            Section("Automatically hide during") {
                Toggle("Full-screen apps", isOn: triggerBinding(\HideTriggers.fullScreenApps))
                Toggle("Full-screen video", isOn: triggerBinding(\HideTriggers.fullScreenVideo))
                Toggle("Games", isOn: triggerBinding(\HideTriggers.games))
                Toggle("Presentations", isOn: triggerBinding(\HideTriggers.presentations))
                Toggle("Screen sharing", isOn: triggerBinding(\HideTriggers.screenSharing))
            }

            Section {
                Button("Quit usAIge") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func binding(for keyPath: ReferenceWritableKeyPath<HUDSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func triggerBinding(_ keyPath: WritableKeyPath<HideTriggers, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.hideTriggers[keyPath: keyPath] },
            set: { value in
                var triggers = settings.hideTriggers
                triggers[keyPath: keyPath] = value
                settings.hideTriggers = triggers
            }
        )
    }
}
