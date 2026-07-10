import SwiftUI

struct HUDView: View {
    @Bindable var store: UsageStore
    @Bindable var settings: HUDSettings
    let openCodex: () -> Void
    let openSettings: () -> Void
    let resizePanel: (CGFloat) -> Void

    private var snapshots: [QuotaSnapshot] {
        switch store.state {
        case let .current(values), let .stale(values, _): settings.ordered(values)
        default: []
        }
    }

    private var desiredHeight: CGFloat {
        switch store.state {
        case .current:
            HUDMetrics.height(rowCount: snapshots.count, includesStatusBanner: false)
        case .stale:
            HUDMetrics.height(rowCount: snapshots.count, includesStatusBanner: true)
        default:
            HUDMetrics.messageHeight
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            content
        }
        .padding(12)
        .frame(width: 292, height: desiredHeight, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .opacity(settings.opacity)
        .scaleEffect(settings.scale)
        .task(id: snapshots.map(\.id)) {
            settings.registerBuckets(snapshots.map(\.id))
        }
        .onAppear { resizePanel(desiredHeight) }
        .onChange(of: desiredHeight) { _, height in resizePanel(height) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.tint)
            Text("Usage")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("usAIge Settings")
            .accessibilityLabel("Open usAIge Settings")
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                Text("Connecting to Codex…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            messageView(
                symbol: "person.crop.circle.badge.exclamationmark",
                title: "Sign in through Codex",
                detail: "usAIge uses your existing Codex account.",
                actionTitle: "Open Codex",
                action: openCodex
            )
        case let .unavailable(message):
            messageView(
                symbol: "bolt.horizontal.circle",
                title: message,
                detail: "Start Codex, then retry the connection.",
                actionTitle: "Open Codex",
                action: openCodex
            )
        case .empty:
            messageView(
                symbol: "circle.dotted",
                title: "No usage limits available",
                detail: "Codex did not expose any quota buckets for this account.",
                actionTitle: "Retry",
                action: { Task { await store.refresh() } }
            )
        case .current:
            quotaList(isStale: false, staleSince: nil)
        case let .stale(_, since):
            quotaList(isStale: true, staleSince: since)
        }
    }

    private func quotaList(isStale: Bool, staleSince: Date?) -> some View {
        VStack(spacing: 8) {
            if let staleSince {
                Label("Last updated \(staleSince.formatted(.relative(presentation: .named)))", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(snapshots) { snapshot in
                        QuotaRowView(snapshot: snapshot)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
        .opacity(isStale ? 0.6 : 1)
    }

    private func messageView(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

enum HUDMetrics {
    static let messageHeight: CGFloat = 260

    static func height(rowCount: Int, includesStatusBanner: Bool) -> CGFloat {
        let bannerHeight: CGFloat = includesStatusBanner ? 24 : 0
        return min(420, max(154, 82 + CGFloat(rowCount) * 72 + bannerHeight))
    }
}
