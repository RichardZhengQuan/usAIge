import AppKit
import SwiftUI

/// A SwiftUI implementation restricted to APIs present on the first M1 Macs.
struct LegacyHUDView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: HUDSettings
    @ObservedObject var updateController: UpdateController
    let openTool: (AIToolDescriptor) -> Void
    let openSettings: () -> Void
    let resizePanel: (CGSize) -> Void

    private var availableSnapshots: [QuotaSnapshot] { store.visibleSnapshots }
    private var snapshots: [QuotaSnapshot] { settings.ordered(availableSnapshots) }
    private var desiredSize: CGSize {
        snapshots.isEmpty
            ? HUDMetrics.messageSize
            : CGSize(width: HUDMetrics.railWidth, height: HUDMetrics.railHeight(rowCount: snapshots.count))
    }

    var body: some View {
        VStack(spacing: 8) {
            if snapshots.isEmpty {
                legacyStatus
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snapshots) { snapshot in
                            LegacyQuotaRow(snapshot: snapshot, openTool: openTool)
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Refresh") { Task { await store.refresh() } }
                    Spacer()
                    Button("Settings") { openSettings() }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(10)
        .frame(width: desiredSize.width, height: desiredSize.height)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.94))
        .cornerRadius(18)
        .opacity(settings.opacity)
        .scaleEffect(settings.scale)
        .onAppear {
            settings.registerBuckets(availableSnapshots)
            resizePanel(HUDMetrics.scaledSize(desiredSize, scale: settings.scale))
        }
    }

    @ViewBuilder
    private var legacyStatus: some View {
        switch store.state {
        case .connecting:
            ProgressView("Connecting…")
        case .signedOut:
            Button("Open ChatGPT to sign in") { openTool(.descriptor(for: .chatGPT)) }
        case let .unavailable(message):
            VStack { Text(message); Button("Open ChatGPT") { openTool(.descriptor(for: .chatGPT)) } }
        case .empty:
            VStack { Text("No usage limits"); Button("Retry") { Task { await store.refresh() } } }
        default:
            EmptyView()
        }
    }
}

private struct LegacyQuotaRow: View {
    let snapshot: QuotaSnapshot
    let openTool: (AIToolDescriptor) -> Void

    private var remaining: Double { min(100, max(0, snapshot.remainingPercent)) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { openTool(.descriptor(for: snapshot.toolID)) }) {
                AIToolIcon(tool: .descriptor(for: snapshot.toolID), size: 24)
            }
            .buttonStyle(PlainButtonStyle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(snapshot.displayName).lineLimit(1)
                    Spacer()
                    Text("\(Int(remaining.rounded()))%")
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.gray.opacity(0.25))
                        Rectangle()
                            .fill(remaining <= 10 ? Color.red : Color.accentColor)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct LegacyHUDSettingsRootView: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var relaySync: RelaySyncController
    @State private var feedbackDraft = FeedbackDraft()
    @State private var isSendingFeedback = false
    @State private var feedbackStatusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Floating panel").font(.headline)
                HStack { Text("Opacity"); Slider(value: opacityBinding, in: HUDSettings.opacityRange) }
                HStack { Text("Scale"); Slider(value: scaleBinding, in: 0.75...1.5) }

                Divider()
                Text("Usage display").font(.headline)
                Toggle("Show reset credits", isOn: resetCreditsVisibilityBinding)

                Divider()
                Text("Startup").font(.headline)
                Toggle("Open usAIge at login", isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.isSupported)
                if !launchAtLogin.isSupported {
                    Text("Open at login is available on macOS 13 or later.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
                Text("iPhone & Apple Watch Sync").font(.headline)
                if relaySync.isLinked {
                    Text("Connected as \(relaySync.macName)")
                    if let code = relaySync.pairingCode, let expiry = relaySync.pairingExpiresAt, expiry > Date() {
                        Text(code).font(.system(.title2, design: .monospaced).weight(.semibold))
                        Text("Code expires \(expiry, style: .time).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("Add iPhone") { Task { await relaySync.createPairingCode() } }
                    ForEach(relaySync.devices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button("Revoke") { Task { await relaySync.revoke(device) } }
                        }
                    }
                    Button("Disconnect All") { Task { await relaySync.disconnectAll() } }
                } else {
                    Text("Create a one-time code, then enter it in usAIge on iPhone.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Create Connection") { Task { await relaySync.createChannel() } }
                }

                Divider()
                Text("Software Update").font(.headline)
                Text("Current version \(updateController.currentVersionText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(updateController.statusText).font(.caption)
                Button(updateController.primaryButtonTitle) {
                    Task { await updateController.performPrimaryAction() }
                }
                .disabled(!updateController.canPerformPrimaryAction)

                Divider()
                Text("Send Feedback").font(.headline)
                TextEditor(text: $feedbackDraft.content)
                    .frame(height: 80)
                Text("Your message is sent with basic system and app details. No account is required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let feedbackStatusMessage {
                    Text(feedbackStatusMessage)
                        .font(.caption)
                        .foregroundColor(feedbackStatusMessage == "Feedback sent. Thank you!" ? .green : .red)
                }
                Button(isSendingFeedback ? "Sending…" : "Send Feedback") {
                    submitFeedback()
                }
                .disabled(!feedbackDraft.canSubmit || isSendingFeedback)

                Divider()
                Text("Visible limits").font(.headline)
                if store.visibleSnapshots.isEmpty {
                    Text("No usage limits available.").foregroundColor(.secondary)
                } else {
                    ForEach(store.visibleSnapshots) { snapshot in
                        Toggle(snapshot.displayName, isOn: visibilityBinding(for: snapshot.id))
                    }
                }
                Button("Refresh usage") { Task { await store.refresh() } }
                Spacer()
                Button("Quit usAIge") { NSApplication.shared.terminate(nil) }
            }
            .padding(24)
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { settings.opacity }, set: { settings.opacity = $0 })
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { settings.scale }, set: { settings.scale = $0 })
    }

    private var resetCreditsVisibilityBinding: Binding<Bool> {
        Binding(
            get: { settings.showsResetCredits },
            set: { settings.showsResetCredits = $0 }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }

    private func submitFeedback() {
        let submission = FeedbackSubmission(content: feedbackDraft.trimmedContent)
        isSendingFeedback = true
        feedbackStatusMessage = nil
        Task {
            do {
                _ = try await FeedbackClient().submit(submission)
                feedbackDraft.content = ""
                feedbackStatusMessage = "Feedback sent. Thank you!"
            } catch {
                feedbackStatusMessage = error.localizedDescription
            }
            isSendingFeedback = false
        }
    }

    private func visibilityBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenBucketIDs.contains(id) },
            set: { visible in
                if visible { settings.hiddenBucketIDs.remove(id) }
                else { settings.hiddenBucketIDs.insert(id) }
            }
        )
    }
}
