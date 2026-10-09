import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 14.0, *)
struct HUDSettingsRootView: View {
    @ObservedObject var settings: HUDSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var relaySync: RelaySyncController
    @ObservedObject var localToolStatus: LocalToolStatusRegistry
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        SettingsWindowSizing {
            HUDSettingsView(
                settings: settings,
                snapshots: store.visibleSnapshots,
                launchAtLogin: launchAtLogin,
                updateController: updateController,
                relaySync: relaySync,
                localToolStatus: localToolStatus,
                navigation: navigation,
                refreshUsage: { await store.refresh() }
            )
        }
    }
}

/// Sizing for the Settings window. Each page sizes the window to its own
/// content, the way the rail grows to fit its rows, so nothing scrolls until
/// the display is too short for the page.
enum HUDSettingsMetrics {
    static let width: CGFloat = 520
    static let minimumHeight: CGFloat = 300
    /// Close to the root page's height, so the first open doesn't visibly
    /// grow the window.
    static let initialHeight: CGFloat = 760
    /// Room for the title bar and a margin above and below the window.
    static let screenAllowance: CGFloat = 96

    /// A page shorter than the window by less than this keeps the window.
    /// The scroller appearing and disappearing as the window crosses the
    /// page height rewraps text by a few points, and following those changes
    /// both ways would resize the window back and forth forever.
    static let shrinkThreshold: CGFloat = 16

    static func windowHeight(forPage pageHeight: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let maximum = max(minimumHeight, visibleScreenHeight - screenAllowance)
        return min(maximum, max(minimumHeight, pageHeight.rounded(.up)))
    }

    /// The page height to size the window for after measuring `measured`:
    /// grow at once, shrink only for a real change such as another page.
    static func settledPageHeight(current: CGFloat, measured: CGFloat) -> CGFloat {
        guard measured > 0 else { return current }
        if measured > current || current - measured > shrinkThreshold { return measured }
        return current
    }
}

/// The natural height of the Settings page on screen: its header plus its
/// form content, measured inside the scroll view.
struct SettingsPageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

@available(macOS 14.0, *)
struct SettingsWindowSizing<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var pageHeight = HUDSettingsMetrics.initialHeight
    @State private var visibleScreenHeight = NSScreen.main?.visibleFrame.height ?? 900

    var body: some View {
        content
            .background(WindowScreenHeightReader { height in visibleScreenHeight = height })
            .onPreferenceChange(SettingsPageHeightKey.self) { height in
                // Preferences are delivered on the main thread during layout.
                MainActor.assumeIsolated {
                    pageHeight = HUDSettingsMetrics.settledPageHeight(current: pageHeight, measured: height)
                }
            }
            .frame(
                width: HUDSettingsMetrics.width,
                height: HUDSettingsMetrics.windowHeight(
                    forPage: pageHeight,
                    visibleScreenHeight: visibleScreenHeight
                )
            )
    }
}

/// Reports the visible height of the display the hosting window is on, and
/// again whenever the window moves to another display, so Settings fits the
/// screen it opened on rather than the main one.
private struct WindowScreenHeightReader: NSViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the window (when Settings closes) drops the observer.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let height = window?.screen?.visibleFrame.height else { return }
            // Never change SwiftUI state during the layout pass that moved us.
            DispatchQueue.main.async { [weak self] in
                guard let self, let onChange = self.onChange else { return }
                onChange(height)
            }
        }
    }
}

@available(macOS 14.0, *)
struct HUDSettingsView: View {
    private static let websiteURL = URL(string: "https://pmrichq.com/project/usaige/")!

    @ObservedObject var settings: HUDSettings
    let snapshots: [QuotaSnapshot]
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var updateController: UpdateController
    @ObservedObject var relaySync: RelaySyncController
    @ObservedObject var localToolStatus: LocalToolStatusRegistry
    @ObservedObject var navigation: SettingsNavigation
    let refreshUsage: () async -> Void
    @State private var remoteToolToDelete: RelayRemoteTool?
    @State private var isDetectingLocalTools = false
    @State private var remotePromptCopied = false
    @State private var feedbackDraft = FeedbackDraft()
    @State private var feedbackState: FeedbackSubmissionState = .idle
    @StateObject private var claudeSignIn = ClaudeSignInSession()
    @State private var expandedToolIDs: Set<AIToolID> = []
    @State private var draggedTool: DraggedTool?
    @AccessibilityFocusState private var isPageTitleFocused: Bool

    /// The supported local tools in the user's rail order.
    private var localGuidances: [LocalToolGuidance] {
        let ordered = settings.toolOrder.compactMap { id in LocalToolGuidance.supported.first { $0.id == id } }
        return ordered + LocalToolGuidance.supported.filter { guidance in !ordered.contains { $0.id == guidance.id } }
    }

    private var orderedRemoteTools: [RelayRemoteTool] {
        let rank = Dictionary(uniqueKeysWithValues: settings.toolOrder.enumerated().map { ($1, $0) })
        return relaySync.remoteTools.sorted { (rank[$0.toolID] ?? Int.max, $0.name) < (rank[$1.toolID] ?? Int.max, $1.name) }
    }

    private var activeToolIDs: [AIToolID] {
        settings.toolOrder.filter { id in snapshots.contains(where: { $0.toolID == id }) }
    }

    private var activeRemoteToolIDs: [AIToolID] {
        activeToolIDs.filter { !AIToolID.builtInIDs.contains($0) }
    }

    var body: some View {
        Group {
            if let destination = navigation.route.last {
                destinationPage(destination)
            } else {
                settingsPage
            }
        }
        .confirmationDialog(
            "Remove remote tool?",
            isPresented: Binding(
                get: { remoteToolToDelete != nil },
                set: { if !$0 { remoteToolToDelete = nil } }
            ),
            presenting: remoteToolToDelete
        ) { tool in
            Button("Remove \(tool.name)", role: .destructive) {
                removeRemoteTool(tool)
            }
        } message: { tool in
            Text("This revokes \(tool.name)'s relay credential and removes its synced limits.")
        }
    }

    private var settingsPage: some View {
        settingsForm(topPadding: 16) {
            Section("General") {
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

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Usage alerts")

                        Text("Alerts are sent when usage crosses each selected interval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Usage alerts",
                        selection: Binding(
                            get: { settings.usageAlertIntervalPercent },
                            set: { settings.usageAlertIntervalPercent = $0 }
                        )
                    ) {
                        ForEach(HUDSettings.usageAlertIntervalOptions, id: \.self) { interval in
                            Text("\(interval)%").tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Usage alerts")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pageLink("AI Tools", destination: .aiTools)
                pageLink("iPhone & Apple Watch Sync", destination: .iphoneSync)
            }

            Section("Display") {
                LabeledContent("Opacity") {
                    HStack(spacing: 8) {
                        Slider(value: binding(for: \HUDSettings.opacity), in: HUDSettings.opacityRange)
                            .frame(width: 180)
                            .accessibilityValue(Self.opacityText(settings.opacity))
                        Text(Self.opacityText(settings.opacity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                LabeledContent("Scale") {
                    HStack(spacing: 8) {
                        Slider(value: binding(for: \HUDSettings.scale), in: HUDSettings.scaleRange)
                            .frame(width: 180)
                            .accessibilityValue(Self.scaleText(settings.scale))
                        Text(Self.scaleText(settings.scale))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show reset credits")

                        Text("Shows available Codex resets beside the live reset countdown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "Show reset credits",
                        isOn: Binding(
                            get: { settings.showsResetCredits },
                            set: { settings.showsResetCredits = $0 }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Show reset credits")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Magnet")

                        Text("Drop the rail near the left or right edge of a display to dock it there. A docked rail slides off screen while you work and returns when your pointer touches that edge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "Magnet",
                        isOn: Binding(
                            get: { settings.magnetEnabled },
                            set: { settings.magnetEnabled = $0 }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Magnet")
                    .help("Dock the rail to a screen edge and hide it until the pointer returns")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("More") {
                pageLink("Send Feedback", destination: .feedback)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Software updates")
                        Text("Current version \(updateController.currentVersionText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            if isUpdateBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(updateController.statusText)
                                .font(.caption)
                                .foregroundStyle(isUpdateError ? Color.red : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        updateButton
                    }
                }

                HStack(spacing: 10) {
                    Link("About usAIge", destination: Self.websiteURL)
                    Button("What’s New") {
                        NSApp.sendAction(
                            #selector(AppDelegate.showWhatsNewWindow(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Quit usAIge") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .task {
            await updateController.checkForUpdates()
        }
    }

    static func opacityText(_ opacity: Double) -> String {
        "\(Int((opacity * 100).rounded()))%"
    }

    static func scaleText(_ scale: Double) -> String {
        String(format: "%.1f\u{00D7}", scale)
    }

    private var updateButton: some View {
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
        .fixedSize()
        .layoutPriority(2)
        .accessibilityValue(
            updateController.canInstallUpdate
                ? "New version available"
                : updateController.statusText
        )
    }

    /// One compact list: every supported local tool on its own row with its
    /// state and controls, limits behind a disclosure, so the page fits
    /// without scrolling. Remote tools follow with their limits in place.
    private var aiToolsPage: some View {
        pageContainer(title: "AI Tools") {
            settingsForm {
                Section {
                    ForEach(localGuidances) { guidance in
                        localToolStatusRow(guidance)
                            .reorderable(
                                guidance.id,
                                in: .local,
                                among: localGuidances.map(\.id),
                                dragged: $draggedTool
                            ) { moved, target in
                                settings.moveTool(moved, to: target)
                            }
                    }
                    HStack {
                        Text("Drag or Control-click a tool to reorder. Sign-ins stay on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task {
                                isDetectingLocalTools = true
                                await refreshUsage()
                                isDetectingLocalTools = false
                            }
                        } label: {
                            if isDetectingLocalTools {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Detecting…")
                                }
                            } else {
                                Label("Detect", systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(isDetectingLocalTools)
                        .accessibilityHint("Scans again for supported local AI tools")
                    }
                } header: {
                    Text("Local AI Tools")
                }

                Section("Remote AI Tools") {
                    if relaySync.remoteTools.isEmpty && activeRemoteToolIDs.isEmpty {
                        Text("No remote tools connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(orderedRemoteTools) { tool in
                        remoteToolRow(tool)
                            .reorderable(
                                tool.toolID,
                                in: .remote,
                                among: orderedRemoteTools.map(\.toolID),
                                dragged: $draggedTool
                            ) { moved, target in
                                settings.moveTool(moved, to: target)
                            }
                        if expandedToolIDs.contains(tool.toolID) {
                            ForEach(orderedSnapshots(for: tool.toolID)) { snapshot in
                                usageTypeRow(snapshot)
                            }
                        }
                    }
                    ForEach(activeRemoteToolIDs.filter { id in !relaySync.remoteTools.contains { $0.toolID == id } }, id: \.self) { id in
                        toolRow(for: id)
                    }
                    if let relayErrorMessage {
                        Text(relayErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button {
                            navigation.route.append(.remoteToolPairing)
                        } label: {
                            Label("Connect AI Tool", systemImage: "plus")
                        }
                        .accessibilityHint("Creates a one-time code for pairing a remote AI tool")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destinationPage(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .aiTools:
            aiToolsPage
        case .remoteToolPairing:
            remoteToolPairingPage
        case .iphoneSync:
            iPhoneSyncPage
        case .feedback:
            feedbackPage
        }
    }

    private var feedbackPage: some View {
        pageContainer(title: "Send Feedback") {
            settingsForm {
                Section("Your Feedback") {
                    TextEditor(text: $feedbackDraft.content)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if feedbackDraft.content.isEmpty {
                                Text("What happened, or what would you like us to improve?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: feedbackDraft.content) { _, value in
                            feedbackDraft.content = String(value.prefix(FeedbackDraft.contentLimit))
                            if !value.isEmpty, feedbackState != .submitting {
                                feedbackState = .idle
                            }
                        }
                    Text("Write one sentence or several. Please don’t include passwords, API keys, or other secrets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        feedbackStatus
                        Spacer()
                        Button {
                            submitFeedback()
                        } label: {
                            if feedbackState == .submitting {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Sending…")
                                }
                            } else {
                                Label("Send Feedback", systemImage: "paperplane")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!feedbackDraft.canSubmit || feedbackState == .submitting)
                    }
                } footer: {
                    Text("usAIge sends this message with the platform, system version, architecture, locale, app version/build, and submission time. No account is required.")
                }
            }
        }
    }

    @ViewBuilder
    private var feedbackStatus: some View {
        switch feedbackState {
        case .idle, .submitting:
            EmptyView()
        case .sent:
            Label("Feedback sent. Thank you!", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func submitFeedback() {
        let submission = FeedbackSubmission(content: feedbackDraft.trimmedContent)
        feedbackState = .submitting
        Task {
            do {
                _ = try await FeedbackClient().submit(submission)
                feedbackDraft.content = ""
                feedbackState = .sent
            } catch {
                feedbackState = .failed(error.localizedDescription)
            }
        }
    }

    private var iPhoneSyncPage: some View {
        pageContainer(title: "iPhone & Apple Watch Sync") {
            settingsForm {
                Section("Connection") {
                    if relaySync.isLinked {
                        LabeledContent("Mac", value: relaySync.macName)
                        LabeledContent("Status", value: relayStatusText)
                        if let date = relaySync.lastUploadAt {
                            LabeledContent("Last upload", value: date.formatted(date: .omitted, time: .shortened))
                        }
                    } else {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "iphone.and.arrow.forward",
                            description: Text("Create a code, then enter it in usAIge on iPhone.")
                        )
                    }
                    if let code = relaySync.pairingCode, let expiry = relaySync.pairingExpiresAt, expiry > Date() {
                        LabeledContent("Pairing code") {
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        Text("Expires \(expiry.formatted(date: .omitted, time: .shortened)). Each code connects one iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(relaySync.isLinked ? "Add iPhone" : "Create Connection") {
                            Task {
                                if relaySync.isLinked { await relaySync.createPairingCode() }
                                else { await relaySync.createChannel() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if relaySync.isLinked {
                    Section("Paired iPhones") {
                        if relaySync.devices.isEmpty {
                            Text("No iPhones paired yet.").foregroundStyle(.secondary)
                        }
                        ForEach(relaySync.devices) { device in
                            HStack {
                                Label(device.name, systemImage: "iphone")
                                Spacer()
                                Text(device.lastSeenAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                Button("Revoke", role: .destructive) { Task { await relaySync.revoke(device) } }
                            }
                        }
                    }
                    Section {
                        Button("Disconnect All", role: .destructive) { Task { await relaySync.disconnectAll() } }
                    } footer: {
                        Text("Only normalized limit percentages and reset times are relayed. A paired iPhone forwards them to Apple Watch. Disconnecting deletes the shared server channel and revokes every iPhone and paired AI tool.")
                    }
                }
            }
        }
    }

    private var remoteToolPairingPage: some View {
        pageContainer(title: "Connect AI Tool") {
            settingsForm {
                Section {
                    if relaySync.remoteTools.isEmpty {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "link.badge.plus",
                            description: Text("Create a code, then give it to Codex, Claude Code, or another compatible AI tool.")
                        )
                    } else {
                        LabeledContent("Mac", value: relaySync.macName)
                        LabeledContent("Status", value: relayStatusText)
                    }

                    if let code = relaySync.remotePairingCode,
                       let expiry = relaySync.remotePairingExpiresAt,
                       expiry > Date() {
                        LabeledContent("Pairing code") {
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        Text("Expires \(expiry.formatted(date: .omitted, time: .shortened)). Each code connects one AI tool.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                remotePromptCopied = RemoteToolSetupPrompt.copy(pairingCode: code)
                            } label: {
                                Label(
                                    remotePromptCopied ? "Instructions Copied" : "Copy Connection Instructions",
                                    systemImage: remotePromptCopied ? "checkmark.circle.fill" : "doc.on.doc"
                                )
                            }
                            Spacer()
                            Button("Create New Code") {
                                Task { await relaySync.createRemoteToolPairingCode() }
                            }
                            .disabled(isRelayConnecting)
                        }
                    } else {
                        HStack {
                            Spacer()
                            Button {
                                remotePromptCopied = false
                                Task { await relaySync.createRemoteToolPairingCode() }
                            } label: {
                                if isRelayConnecting {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Creating…")
                                    }
                                } else {
                                    Text(relaySync.remoteTools.isEmpty ? "Create Connection" : "Connect Another Tool")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRelayConnecting)
                        }
                    }
                    if let relayErrorMessage {
                        Text(relayErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Label(
                        "Only normalized remaining percentages and reset times are accepted. Provider credentials stay with the paired tool.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !relaySync.remoteTools.isEmpty {
                    Section("Paired AI Tools") {
                        ForEach(relaySync.remoteTools) { tool in
                            HStack {
                                Label(tool.name, systemImage: tool.symbolName)
                                Spacer()
                                if let lastUploadAt = tool.lastUploadAt {
                                    Text(lastUploadAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Waiting for limits")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Revoke", role: .destructive) {
                                    Task {
                                        await relaySync.revoke(tool)
                                        await refreshUsage()
                                    }
                                }
                            }
                        }
                    }
                }

            }
            .task { _ = try? await relaySync.refreshRemoteTools() }
        }
    }

    private func settingsForm<Content: View>(
        topPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // The window sizes itself to this content; the scroll view only
        // matters when the display is too short for the whole page.
        ScrollView {
            Form {
                content()
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, topPadding)
            .padding(.bottom, 28)
            .background(measuredHeight)
        }
    }

    private var relayStatusText: String {
        switch relaySync.status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .uploading: "Uploading…"
        case let .failed(message): message
        }
    }

    private var isRelayConnecting: Bool {
        if case .connecting = relaySync.status { true } else { false }
    }

    private var relayErrorMessage: String? {
        if case let .failed(message) = relaySync.status { message } else { nil }
    }

    private func pageContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Back")
                .accessibilityLabel("Back")
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isPageTitleFocused)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .background(measuredHeight)
            .task(id: title) { isPageTitleFocused = true }

            content()
        }
    }

    /// Reports the height of the view it backs toward the window's size.
    private var measuredHeight: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SettingsPageHeightKey.self, value: proxy.size.height)
        }
    }

    private func pageLink(
        _ title: String,
        destination: SettingsDestination
    ) -> some View {
        Button {
            navigation.route.append(destination)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }

    private func goBack() {
        guard !navigation.route.isEmpty else { return }
        navigation.route.removeLast()
    }

    private func orderedSnapshots(for toolID: AIToolID) -> [QuotaSnapshot] {
        settings.bucketOrder.compactMap { id in
            snapshots.first(where: { $0.id == id && $0.toolID == toolID })
        }
    }

    private func toolRow(for id: AIToolID) -> some View {
        let tool = snapshots.first(where: { $0.toolID == id })
            .map(AIToolDescriptor.descriptor(for:)) ?? AIToolDescriptor.descriptor(for: id)
        return HStack(spacing: 10) {
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
            Text("\(orderedSnapshots(for: id).count) types")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func localToolStatusRow(_ guidance: LocalToolGuidance) -> some View {
        let tool = AIToolDescriptor.descriptor(for: guidance.id)
        let status = localToolStatus(for: guidance.id)
        let presentation = guidance.presentation(for: status)
        let buckets = orderedSnapshots(for: guidance.id)
        let isExpanded = expandedToolIDs.contains(guidance.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AIToolIcon(tool: tool, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name)
                    Text(presentation.text)
                        .font(.caption)
                        .foregroundStyle(presentation.isProblem ? Color.orange : Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if guidance.id == .claude, Self.offersClaudeSignIn(status: status), !claudeSignIn.isActive {
                    Button("Sign In…") { claudeSignIn.start() }
                        .controlSize(.small)
                        .accessibilityHint("Runs Claude Code's own sign-in and opens the Claude sign-in page")
                }
                if !buckets.isEmpty {
                    Toggle(
                        "Show \(tool.name)",
                        isOn: Binding(
                            get: { !settings.hiddenToolIDs.contains(guidance.id) },
                            set: { visible in
                                if visible { settings.hiddenToolIDs.remove(guidance.id) }
                                else { settings.hiddenToolIDs.insert(guidance.id) }
                            }
                        )
                    )
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Show \(tool.name) in the rail")
                    .help("Show \(tool.name) in the rail")
                    Button {
                        if isExpanded { expandedToolIDs.remove(guidance.id) } else { expandedToolIDs.insert(guidance.id) }
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(buckets.count) \(buckets.count == 1 ? "limit" : "limits")")
                                .font(.caption2)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Hide \(tool.name) limits" : "Show \(tool.name) limits")
                }
            }
            .accessibilityElement(children: .contain)

            if isExpanded {
                ForEach(buckets) { snapshot in
                    usageTypeRow(snapshot)
                }
                .padding(.leading, 34)
            }

            if guidance.id == .claude {
                claudeSignInPanel
            }
        }
        .onAppear {
            claudeSignIn.onSucceeded = {
                Task { await refreshUsage() }
            }
        }
    }

    /// usAIge reads an existing Claude Code sign-in, or the running Claude
    /// app's own readings, on its own, so the button only appears when
    /// neither gives limits; a connected or rate-limited tool, or one still
    /// being checked, doesn't need it.
    static func offersClaudeSignIn(status: LocalToolStatus) -> Bool {
        switch status {
        case .connected, .connectedThroughClaudeApp, .rateLimited, .unknown: false
        default: true
        }
    }

    @ViewBuilder
    private var claudeSignInPanel: some View {
        switch claudeSignIn.state {
        case .idle:
            EmptyView()
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Claude Code's sign-in…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { claudeSignIn.cancel() }.controlSize(.small)
            }
        case .waitingForCode:
            VStack(alignment: .leading, spacing: 6) {
                Text("Approve the sign-in in your browser, then paste the code it shows here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Paste the code", text: $claudeSignIn.code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { claudeSignIn.submit() }
                    Button("Continue") { claudeSignIn.submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(claudeSignIn.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 12) {
                    Button("Open sign-in page again") { claudeSignIn.openSignInPage() }.buttonStyle(.link)
                    Button("Cancel") { claudeSignIn.cancel() }.buttonStyle(.link)
                }
                .font(.caption)
            }
        case .submitting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing the sign-in…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded:
            HStack(spacing: 8) {
                Label("Signed in.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { claudeSignIn.reset() }.controlSize(.small)
            }
        case let .failed(message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer()
                Button("Try Again") { claudeSignIn.reset(); claudeSignIn.start() }.controlSize(.small)
            }
        case .unavailable:
            HStack(spacing: 8) {
                Text("Claude Code isn’t installed. Install it, run `claude` once, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Dismiss") { claudeSignIn.reset() }.controlSize(.small)
            }
        }
    }

    private func localToolStatus(for id: AIToolID) -> LocalToolStatus {
        if id == .chatGPT {
            return snapshots.contains(where: { $0.toolID == .chatGPT }) ? .connected : .signedOut
        }
        return localToolStatus.status(for: id)
    }

    private func remoteToolRow(_ tool: RelayRemoteTool) -> some View {
        let buckets = orderedSnapshots(for: tool.toolID)
        let isExpanded = expandedToolIDs.contains(tool.toolID)
        return HStack(spacing: 10) {
            Image(systemName: tool.symbolName)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                Text(tool.lastUploadAt == nil ? "Waiting for limits" : "Connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !buckets.isEmpty {
                Toggle(
                    "Show \(tool.name)",
                    isOn: Binding(
                        get: { !settings.hiddenToolIDs.contains(tool.toolID) },
                        set: { visible in
                            if visible { settings.hiddenToolIDs.remove(tool.toolID) }
                            else { settings.hiddenToolIDs.insert(tool.toolID) }
                        }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Show \(tool.name) in the rail")
                Button {
                    if isExpanded { expandedToolIDs.remove(tool.toolID) } else { expandedToolIDs.insert(tool.toolID) }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(buckets.count) \(buckets.count == 1 ? "limit" : "limits")").font(.caption2)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Hide \(tool.name) limits" : "Show \(tool.name) limits")
            }
            Button(role: .destructive) {
                remoteToolToDelete = tool
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(tool.name)")
            .accessibilityLabel("Remove \(tool.name)")
        }
    }

    private func removeRemoteTool(_ tool: RelayRemoteTool) {
        remoteToolToDelete = nil
        Task {
            await relaySync.revoke(tool)
            await refreshUsage()
        }
    }

    private func usageTypeRow(_ snapshot: QuotaSnapshot) -> some View {
        HStack(spacing: 9) {
            Text(snapshot.combinedTypeTag)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 72)
            Toggle(
                snapshot.displayName,
                isOn: Binding(
                    get: { !settings.hiddenBucketIDs.contains(snapshot.id) },
                    set: { visible in
                        if visible { settings.hiddenBucketIDs.remove(snapshot.id) }
                        else { settings.hiddenBucketIDs.insert(snapshot.id) }
                    }
                )
            )
            Spacer()
            orderButtons(
                moveUp: {
                    settings.moveBucket(snapshot.id, by: -1, among: orderedSnapshots(for: snapshot.toolID).map(\.id))
                },
                moveDown: {
                    settings.moveBucket(snapshot.id, by: 1, among: orderedSnapshots(for: snapshot.toolID).map(\.id))
                },
                label: snapshot.displayName
            )
        }
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

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var route: [SettingsDestination] = []

    func showMainPage() {
        route.removeAll()
    }
}

enum SettingsDestination: Hashable {
    case aiTools
    case remoteToolPairing
    case iphoneSync
    case feedback
}

private enum FeedbackSubmissionState: Equatable {
    case idle
    case submitting
    case sent
    case failed(String)
}

/// Drag-and-drop reordering for tool rows: the row being dragged carries its
/// tool id, and each row moves the dragged tool into its own slot as the
/// pointer passes over it, so the order updates live and persists on drop.
private struct ToolReorderDropDelegate: DropDelegate {
    let target: AIToolID
    let section: ToolReorderSection
    @Binding var dragged: DraggedTool?
    let move: (AIToolID, AIToolID) -> Void

    func dropEntered(info: DropInfo) {
        // Local and remote tools are separate lists; a row carried over the
        // other list must not reorder anything.
        guard let dragged, dragged.section == section, dragged.id != target else { return }
        move(dragged.id, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragged?.section == section ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragged?.section == section else { return false }
        dragged = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

/// Which list a dragged tool row came from.
enum ToolReorderSection: Equatable {
    case local
    case remote
}

struct DraggedTool: Equatable {
    let id: AIToolID
    let section: ToolReorderSection
    /// Distinguishes two drags of the same row, so the mouse-up watcher of a
    /// finished drag can never clear a new one.
    let token = UUID()
}

@available(macOS 14.0, *)
extension View {
    /// Makes a tool row draggable and a drop target for other tool rows in
    /// the same section. The same moves are offered as Move Up and Move Down
    /// in the row's context menu and as VoiceOver actions, since dragging
    /// needs a pointer.
    func reorderable(
        _ id: AIToolID,
        in section: ToolReorderSection,
        among siblings: [AIToolID],
        dragged: Binding<DraggedTool?>,
        move: @escaping (AIToolID, AIToolID) -> Void
    ) -> some View {
        let index = siblings.firstIndex(of: id)
        let previous = index.flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        let next = index.flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil }
        return self
            .contentShape(Rectangle())
            .contextMenu {
                Button("Move Up") { if let previous { move(id, previous) } }
                    .disabled(previous == nil)
                Button("Move Down") { if let next { move(id, next) } }
                    .disabled(next == nil)
            }
            .accessibilityAction(named: "Move Up") { if let previous { move(id, previous) } }
            .accessibilityAction(named: "Move Down") { if let next { move(id, next) } }
            .onDrag {
                dragged.wrappedValue = DraggedTool(id: id, section: section)
                return NSItemProvider(object: id.rawValue as NSString)
            }
            .onDrop(
                of: [UTType.plainText],
                delegate: ToolReorderDropDelegate(target: id, section: section, dragged: dragged, move: move)
            )
            .opacity(dragged.wrappedValue?.id == id ? 0.55 : 1)
            .task(id: dragged.wrappedValue.flatMap { $0.id == id ? $0.token : nil }) {
                // SwiftUI only reports a drop that lands on a row. A drag
                // cancelled with Escape or released elsewhere would leave
                // this row dimmed, so watch for the button coming up.
                guard let token = dragged.wrappedValue?.token, dragged.wrappedValue?.id == id else { return }
                while !Task.isCancelled, dragged.wrappedValue?.token == token {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if NSEvent.pressedMouseButtons == 0 {
                        // Give a successful drop its own chance to clear the state
                        // first, then clear it ourselves.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        if dragged.wrappedValue?.token == token { dragged.wrappedValue = nil }
                    }
                }
            }
    }
}
