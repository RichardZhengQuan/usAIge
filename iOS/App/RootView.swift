import SwiftUI

enum AppSection: Hashable {
    case usage
    case notifications
    case connection
    case settings
}

struct RootView: View {
    @Environment(RelayAppModel.self) private var model
    @State private var selection: AppSection = .usage

    var body: some View {
        @Bindable var model = model

        TabView(selection: $selection) {
            Tab("Usage", systemImage: "gauge.with.dots.needle.67percent", value: .usage) {
                NavigationStack {
                    DashboardView()
                }
            }

            Tab("Activities", systemImage: "bell", value: .notifications) {
                NavigationStack {
                    SessionNotificationListView()
                }
            }

            Tab("Connection", systemImage: "macbook.and.iphone", value: .connection) {
                NavigationStack {
                    ToolsView()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .task {
            if model.sessionNotificationNavigationRequest != nil {
                selection = .notifications
            }
        }
        .onChange(of: model.sessionNotificationNavigationRequest) { _, request in
            if request != nil {
                selection = .notifications
            }
        }
    }
}

private struct SessionNotificationListView: View {
    @Environment(RelayAppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Text("Activities")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshSessionEvents() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isRefreshing)
                    .accessibilityLabel("Refresh Activities")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Group {
                    if model.sessionEvents.isEmpty, model.sessionEventErrorMessage == nil {
                        ContentUnavailableView(
                            "No Activities",
                            systemImage: "bell.slash",
                            description: Text(
                                "Finished sessions, errors, and permission requests will appear here."
                            )
                        )
                    } else {
                        List {
                            if let error = model.sessionEventErrorMessage {
                                Section {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }

                            ForEach(model.sessionEvents) { event in
                                NavigationLink {
                                    SessionNotificationDetailView(event: event)
                                } label: {
                                    SessionNotificationRow(event: event)
                                }
                                .id(event.id)
                                .listRowBackground(
                                    focusedEventID == event.id
                                        ? Color.accentColor.opacity(0.14)
                                        : nil
                                )
                            }
                        }
                        .listStyle(.insetGrouped)
                        .contentMargins(.top, 8, for: .scrollContent)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .task {
                await model.refreshSessionEvents()
                scrollToFocusedEvent(using: proxy)
            }
            .onChange(of: model.sessionNotificationNavigationRequest) { _, _ in
                scrollToFocusedEvent(using: proxy)
            }
            .onChange(of: model.sessionEvents) { _, _ in
                scrollToFocusedEvent(using: proxy)
            }
        }
    }

    private var focusedEventID: String? {
        guard let request = model.sessionNotificationNavigationRequest,
              let eventID = request.eventID else { return nil }
        if let channelID = request.channelID {
            return "\(channelID.uuidString.lowercased()):\(eventID)"
        }
        return model.sessionEvents.first { $0.eventID == eventID }?.id
    }

    private func scrollToFocusedEvent(using proxy: ScrollViewProxy) {
        guard let focusedEventID else { return }
        withAnimation {
            proxy.scrollTo(focusedEventID, anchor: .center)
        }
    }
}

private struct SessionNotificationRow: View {
    let event: SessionEventRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.title)
                    .font(.headline)
                Text(event.sessionTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(event.workspaceName) · \(event.macName) · \(event.occurredAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: event.kind.systemImage)
                .foregroundStyle(event.kind.tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionNotificationDetailView: View {
    let event: SessionEventRecord

    var body: some View {
        Form {
            Section("Event") {
                LabeledContent("Status", value: event.kind.title)
                LabeledContent("Session", value: event.sessionTitle)
                LabeledContent("Workspace", value: event.workspaceName)
                LabeledContent("Mac", value: event.macName)
                LabeledContent("Time") {
                    Text(event.occurredAt, format: .dateTime)
                }
            }
        }
        .navigationTitle(event.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension SessionEventKind {
    var title: String {
        switch self {
        case .finished: "Session Finished"
        case .error: "Session Error"
        case .permissionNeeded: "Permission Needed"
        }
    }

    var systemImage: String {
        switch self {
        case .finished: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .permissionNeeded: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .finished: .green
        case .error: .red
        case .permissionNeeded: .orange
        }
    }
}
