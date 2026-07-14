import SwiftUI

struct ToolDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false
    @State private var isEditingConnection = false
    let toolID: UUID

    var body: some View {
        @Bindable var model = model

        if let toolIndex = model.tools.firstIndex(where: { $0.id == toolID }) {
            Form {
                if let systemError = model.systemErrorMessage {
                    Section("Saved changes need attention") {
                        Label(systemError, systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Button(model.canRetryPersistence ? "Retry Saving" : "Try Again", systemImage: "arrow.clockwise") {
                            Task { await model.recoverFromSystemError() }
                        }
                    }
                }

                Section("Connection") {
                    LabeledContent("Endpoint") {
                        Text(model.tools[toolIndex].displayEndpoint)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Refresh") {
                        Text("Every \(model.tools[toolIndex].refreshIntervalMinutes) minutes")
                    }
                    Toggle(
                        "Include in refreshes",
                        isOn: Binding(
                            get: { model.displayedEnabledState(for: toolID) },
                            set: { isEnabled in
                                Task {
                                    await model.setToolEnabled(
                                        toolID: toolID,
                                        isEnabled: isEnabled
                                    )
                                }
                            }
                        )
                    )
                    .disabled(!model.canStartToolMutation)

                    if model.isSavingToolChanges {
                        ProgressView("Saving connection…")
                    }

                    Button("Edit Connection", systemImage: "pencil") {
                        isEditingConnection = true
                    }
                    .disabled(!model.canStartToolMutation)
                }

                Section("Status") {
                    let snapshots = model.snapshots(for: toolID)
                    if snapshots.isEmpty {
                        ContentUnavailableView(
                            "No limits cached",
                            systemImage: "gauge.open.with.lines.needle.33percent",
                            description: Text(model.errorsByToolID[toolID] ?? "Refresh this tool to request its current limits.")
                        )
                    } else {
                        ForEach(snapshots) { snapshot in
                            LabeledContent(snapshot.displayName) {
                                Text(snapshot.remainingPercent / 100, format: .percent.precision(.fractionLength(0)))
                            }
                        }
                    }

                    Button("Refresh Now", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(toolID: toolID) }
                    }
                    .disabled(
                        model.isRefreshing
                            || model.isSavingToolChanges
                            || !model.tools[toolIndex].isEnabled
                    )
                }

                Section {
                    Button("Remove Tool", systemImage: "trash", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .disabled(!model.canStartToolMutation)
                }
            }
            .navigationTitle(model.tools[toolIndex].name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isEditingConnection) {
                NavigationStack {
                    EditToolView(tool: model.tools[toolIndex]) { _ in
                        isEditingConnection = false
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Remove this AI tool?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove \(model.tools[toolIndex].name)", role: .destructive) {
                    let tool = model.tools[toolIndex]
                    Task {
                        if await model.deleteTool(tool) {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("Its endpoint, saved token, and cached quota limits will be removed from this device.")
            }
        } else {
            ContentUnavailableView("Tool not found", systemImage: "questionmark.app")
        }
    }
}
