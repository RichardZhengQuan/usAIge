import AppKit
import SwiftUI

/// Modern's iPhone & Apple Watch page: whether this Mac sends its limits to
/// iPhone, the code that pairs one, and the iPhones that are paired. Apple
/// Watch shows what its iPhone receives.
@available(macOS 14.0, *)
struct ModernDevicesPage: View {
    @ObservedObject var relaySync: RelaySyncController
    @State private var copied = false
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statusCard
                if let code = relaySync.pairingCode, let expiry = relaySync.pairingExpiresAt, expiry > Date() {
                    pairingCode(code, expiry: expiry)
                } else if !relaySync.isLinked {
                    steps
                }
                if relaySync.isLinked {
                    pairedPhones
                    disconnect
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ModernPalette.page)
        .environment(\.interfaceStyle, .modern)
        .confirmationDialog("Disconnect every iPhone?", isPresented: $confirmsDisconnect) {
            Button("Disconnect All", role: .destructive) { Task { await relaySync.disconnectAll() } }
        } message: {
            Text("This deletes the connection and revokes every paired iPhone and AI tool. You can connect again with a new code.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("iPhone & Apple Watch")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if relaySync.isLinked {
                Button("Add iPhone…") { Task { await relaySync.createPairingCode() } }
                    .controlSize(.large)
                    .disabled(isBusy)
            } else {
                Button("Connect iPhone…") { Task { await relaySync.createChannel() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Status

    private var statusCard: some View {
        ModernCard(padding: 18) {
            HStack(spacing: 18) {
                HStack(alignment: .bottom, spacing: 2) {
                    Image(systemName: "iphone").font(.system(size: 34, weight: .regular))
                    Image(systemName: "applewatch").font(.system(size: 22, weight: .regular))
                }
                .foregroundStyle(Color(nsColor: .systemIndigo))
                .frame(width: 72, height: 72)
                .background(Color(nsColor: .systemIndigo).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 9, height: 9)
                        Text(statusTitle).font(.title2.weight(.semibold))
                    }
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case let .failed(message) = relaySync.status {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch relaySync.status {
        case .connecting: "Connecting…"
        case .uploading: "Sending…"
        case .failed: relaySync.isLinked ? "Connected" : "Not connected"
        case .connected: "Connected"
        case .disconnected: relaySync.isLinked ? "Connected" : "Not connected"
        }
    }

    private var statusColor: Color {
        switch relaySync.status {
        case .failed: Color(nsColor: .systemOrange)
        case .connecting, .uploading: Color(nsColor: .systemBlue)
        default: relaySync.isLinked ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.5)
        }
    }

    private var statusDetail: String {
        guard relaySync.isLinked else {
            return "See your AI tools' limits on iPhone and Apple Watch. Pair an iPhone with a one-time code."
        }
        let phones = relaySync.devices.count == 1 ? "1 iPhone" : "\(relaySync.devices.count) iPhones"
        let sent = relaySync.lastUploadAt.map { "Last sent \($0.formatted(date: .omitted, time: .shortened))" }
        return ["\(relaySync.macName) sends to \(phones)", sent].compactMap { $0 }.joined(separator: " · ")
    }

    private var isBusy: Bool {
        if case .connecting = relaySync.status { true } else { false }
    }

    // MARK: Pairing

    private func pairingCode(_ code: String, expiry: Date) -> some View {
        ModernSection(title: "Pairing code",
                      footer: "Enter it in usAIge on your iPhone. It works once and expires at \(expiry.formatted(date: .omitted, time: .shortened)).") {
            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .kerning(4)
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                Spacer(minLength: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .padding(.horizontal, ModernMetrics.rowPadding)
            .padding(.vertical, 14)
        }
        .onChange(of: code) { _, _ in copied = false }
    }

    private var steps: some View {
        ModernSection(title: "How it works",
                      footer: "Only remaining percentages and reset times are sent. Sign-ins and usage details stay on this Mac.") {
            stepRow(1, "Choose Connect iPhone to make a one-time code.")
            stepRow(2, "Open usAIge on your iPhone and enter the code.")
            stepRow(3, "Your limits appear on iPhone, and on the Apple Watch paired with it.")
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .systemIndigo))
                .frame(width: ModernMetrics.iconSize, height: ModernMetrics.iconSize)
                .background(Color(nsColor: .systemIndigo).opacity(0.12), in: Circle())
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ModernMetrics.rowPadding)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if number > 1 {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                    .padding(.leading, ModernMetrics.separatorInset)
            }
        }
    }

    // MARK: Paired iPhones

    private var pairedPhones: some View {
        ModernSection(title: "Paired iPhones",
                      footer: "Each iPhone passes your limits to the Apple Watch paired with it.") {
            if relaySync.devices.isEmpty {
                ModernNoteRow(text: "No iPhones yet. Choose Add iPhone to pair one.")
            }
            ForEach(Array(relaySync.devices.enumerated()), id: \.element.id) { index, device in
                HStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemIndigo))
                        .frame(width: ModernMetrics.iconSize, height: ModernMetrics.iconSize)
                        .background(Color(nsColor: .systemIndigo).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("Seen \(device.lastSeenAt.formatted(.relative(presentation: .named))) · Paired \(device.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Revoke", role: .destructive) { Task { await relaySync.revoke(device) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, ModernMetrics.rowPadding)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                            .padding(.leading, ModernMetrics.separatorInset)
                    }
                }
            }
        }
    }

    private var disconnect: some View {
        HStack {
            Button("Disconnect All…", role: .destructive) { confirmsDisconnect = true }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
