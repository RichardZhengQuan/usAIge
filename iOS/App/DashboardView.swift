import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.canModifyTools, model.systemErrorMessage == nil {
                ProgressView("Loading saved tools…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tools.isEmpty {
                ContentUnavailableView {
                    Label("No AI tools yet", systemImage: "gauge.open.with.lines.needle.33percent")
                } description: {
                    Text(model.systemErrorMessage ?? "Connect a remote usage endpoint to see quota limits and reset times here and in the widget.")
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
            } else if model.enabledTools.isEmpty {
                ContentUnavailableView {
                    Label("All AI tools are off", systemImage: "pause.circle")
                } description: {
                    Text("Open the Tools tab and enable at least one connection to resume quota updates.")
                }
            } else if model.snapshots.isEmpty, model.isRefreshing {
                ProgressView("Getting current limits…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.snapshots.isEmpty, let message = model.primaryErrorMessage {
                ContentUnavailableView {
                    Label("Limits unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button(model.canRetryPersistence ? "Retry Saving" : "Try Again", systemImage: "arrow.clockwise") {
                        Task {
                            if model.systemErrorMessage != nil {
                                await model.recoverFromSystemError()
                            } else {
                                await model.refreshAll()
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                quotaList
            }
        }
        .navigationTitle("AI Usage")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .disabled(model.isRefreshing || model.enabledTools.isEmpty)

                Button("Add Tool", systemImage: "plus") {
                    model.isPresentingAddTool = true
                }
                .disabled(!model.canStartToolMutation)
            }
        }
    }

    private var quotaList: some View {
        List {
            if let systemError = model.systemErrorMessage {
                Section {
                    StatusBanner(
                        title: "Saved changes need attention",
                        detail: systemError,
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    Button(model.canRetryPersistence ? "Retry Saving" : "Try Again", systemImage: "arrow.clockwise") {
                        Task { await model.recoverFromSystemError() }
                    }
                }
            } else if model.isCacheStale || !model.errorsByToolID.isEmpty {
                Section {
                    StatusBanner(
                        title: model.isCacheStale ? "Showing saved limits" : "Some tools did not update",
                        detail: model.statusDetail,
                        systemImage: model.isCacheStale ? "clock.badge.exclamationmark" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                    )
                }
            }

            ForEach(model.enabledTools) { tool in
                Section {
                    let values = model.snapshots(for: tool.id)
                    if values.isEmpty {
                        ToolUnavailableRow(tool: tool, message: model.errorsByToolID[tool.id])
                    } else {
                        ForEach(values) { snapshot in
                            QuotaRow(snapshot: snapshot)
                        }
                    }
                } header: {
                    Label(tool.name, systemImage: tool.symbolName)
                } footer: {
                    if let date = model.lastRefreshByToolID[tool.id] {
                        Text("Updated \(date, style: .relative)")
                    }
                }
            }
        }
        .refreshable {
            await model.refreshAll()
        }
        .overlay {
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .glassEffect(.regular, in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .accessibilityLabel("Refreshing limits")
            }
        }
    }
}

private struct StatusBanner: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ToolUnavailableRow: View {
    let tool: RemoteToolConfiguration
    let message: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No limits available")
                Text(message ?? "Pull to refresh or check this tool's endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
