import AppKit
import SwiftUI

struct HUDSettingsRootView: View {
    @Bindable var settings: HUDSettings
    @Bindable var store: UsageStore
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController

    var body: some View {
        HUDSettingsView(
            settings: settings,
            snapshots: store.visibleSnapshots,
            launchAtLogin: launchAtLogin,
            updateController: updateController
        )
    }
}

struct HUDSettingsView: View {
    @Bindable var settings: HUDSettings
    let snapshots: [QuotaSnapshot]
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController

    private var activeToolIDs: [AIToolID] {
        settings.toolOrder.filter { id in snapshots.contains(where: { $0.toolID == id }) }
    }

    var body: some View {
        Form {
            Section("Floating panel") {
                LabeledContent("Opacity") {
                    Slider(value: binding(for: \HUDSettings.opacity), in: 0.4...1.0)
                        .frame(width: 180)
                }
                LabeledContent("Scale") {
                    Slider(value: binding(for: \HUDSettings.scale), in: 0.75...1.5)
                        .frame(width: 180)
                }
            }

            Section("Startup") {
                Toggle(
                    "Open usAIge at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                if let message = launchAtLogin.errorMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(launchAtLogin.requiresApproval ? Color.secondary : Color.red)
                        if launchAtLogin.requiresApproval {
                            Spacer()
                            Button("Open Login Items") {
                                launchAtLogin.openSystemSettings()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Section("Software Update") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatic updates")
                        Text(updateController.statusText)
                            .font(.caption)
                            .foregroundStyle(isUpdateError ? Color.red : Color.secondary)
                    }
                    Spacer()
                    if isUpdateBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    ZStack(alignment: .topTrailing) {
                        Button(updateController.primaryButtonTitle) {
                            Task { await updateController.performPrimaryAction() }
                        }
                        .disabled(!updateController.canPerformPrimaryAction)

                        if updateController.canInstallUpdate {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityValue(
                        updateController.canInstallUpdate
                            ? "New version available"
                            : updateController.statusText
                    )
                }
            }

            Section("Active AI tools") {
                if activeToolIDs.isEmpty {
                    Text("Tools appear here after a supported usage source reports data.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeToolIDs, id: \.self) { id in
                        let tool = AIToolDescriptor.descriptor(for: id)
                        HStack(spacing: 10) {
                            AIToolIcon(tool: tool, size: 26)
                            Toggle(
                                tool.name,
                                isOn: Binding(
                                    get: { !settings.hiddenToolIDs.contains(id) },
                                    set: { visible in
                                        if visible { settings.hiddenToolIDs.remove(id) }
                                        else { settings.hiddenToolIDs.insert(id) }
                                    }
                                )
                            )
                            Spacer()
                            Text("\(snapshots.count(where: { $0.toolID == id })) types")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Usage types") {
                if snapshots.isEmpty {
                    Text("Quota controls appear after Codex reports usage data.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.bucketOrder, id: \.self) { id in
                        if let snapshot = snapshots.first(where: { $0.id == id }) {
                            HStack(spacing: 9) {
                                Text(snapshot.combinedTypeTag)
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72)
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
                                orderButtons(
                                    moveUp: { settings.moveBucket(id, by: -1) },
                                    moveDown: { settings.moveBucket(id, by: 1) },
                                    label: snapshot.displayName
                                )
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

    private func orderButtons(
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        label: String
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: moveUp) { Image(systemName: "chevron.up") }
                .help("Move \(label) up")
                .accessibilityLabel("Move \(label) up")
            Button(action: moveDown) { Image(systemName: "chevron.down") }
                .help("Move \(label) down")
                .accessibilityLabel("Move \(label) down")
        }
        .buttonStyle(.borderless)
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

    private var isUpdateBusy: Bool {
        switch updateController.status {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }

    private var isUpdateError: Bool {
        if case .failed = updateController.status { true } else { false }
    }
}
