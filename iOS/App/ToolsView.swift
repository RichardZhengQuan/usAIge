import SwiftUI

struct ToolsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Group {
            if !model.canModifyTools, model.systemErrorMessage == nil {
                ProgressView("Loading saved tools…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tools.isEmpty {
                ContentUnavailableView {
                    Label("No remote tools", systemImage: "shippingbox")
                } description: {
                    Text(model.systemErrorMessage ?? "Add an HTTPS endpoint that returns the usAIge limits JSON format.")
                } actions: {
                    VStack {
                        if model.systemErrorMessage != nil {
                            Button(model.canRetryPersistence ? "Retry Saving" : "Try Again", systemImage: "arrow.clockwise") {
                                Task { await model.recoverFromSystemError() }
                            }
                        }
                        Button("Add AI Tool", systemImage: "plus") {
                            model.isPresentingAddTool = true
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.canStartToolMutation)
                    }
                }
            } else {
                List {
                    if let systemError = model.systemErrorMessage {
                        Section("Saved changes need attention") {
                            Label(systemError, systemImage: "externaldrive.badge.exclamationmark")
                                .foregroundStyle(.orange)
                            Button(model.canRetryPersistence ? "Retry Saving" : "Try Again", systemImage: "arrow.clockwise") {
                                Task { await model.recoverFromSystemError() }
                            }
                        }
                    }

                    Section("Remote AI Tools") {
                        ForEach($model.tools) { $tool in
                            NavigationLink {
                                ToolDetailView(toolID: tool.id)
                            } label: {
                                ToolConfigurationRow(tool: tool)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    model.toolPendingDeletion = tool
                                }
                                .disabled(!model.canStartToolMutation)
                            }
                        }
                    }

                    Section {
                        LabeledContent("Widget cache", value: "Quota snapshots; no tokens")
                        LabeledContent("Background refresh", value: "Scheduled by iOS")
                    } footer: {
                        Text("iOS decides the exact background refresh time. Opening the app or pulling to refresh always requests current values immediately.")
                    }
                }
            }
        }
        .navigationTitle("Tools")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.isSavingToolChanges {
                    ProgressView()
                        .accessibilityLabel("Saving tool changes")
                }
                Button("Add Tool", systemImage: "plus") {
                    model.isPresentingAddTool = true
                }
                .disabled(!model.canStartToolMutation)
            }
        }
        .confirmationDialog(
            "Remove this AI tool?",
            isPresented: $model.isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: model.toolPendingDeletion
        ) { tool in
            Button("Remove \(tool.name)", role: .destructive) {
                Task { await model.deleteTool(tool) }
            }
        } message: { tool in
            Text("Its endpoint, saved token, and cached quota limits will be removed from this device.")
        }
    }
}

private struct ToolConfigurationRow: View {
    let tool: RemoteToolConfiguration

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.symbolName)
                .frame(width: 28)
                .foregroundStyle(tool.isEnabled ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                Text(tool.endpointURL.host() ?? tool.endpointURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !tool.isEnabled {
                Text("Off")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
