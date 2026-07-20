import AppKit
import SwiftUI

struct WhatsNewView: View {
    @ObservedObject var updateController: UpdateController
    let close: () -> Void

    private var presentation: WhatsNewPresentation { updateController.whatsNewPresentation }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if presentation.releaseNotes.highlights.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 34))
                                .foregroundColor(.secondary)
                            Text("No additional release notes")
                                .font(.headline)
                            Text("You have the latest installed version.")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(presentation.releaseNotes.highlights) { highlight in
                                highlightRow(highlight)
                            }
                        }
                    }
                }
                .padding(.horizontal, 38)
                .padding(.vertical, 34)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 68, height: 68)
                .accessibilityHidden(true)
            Text("What’s New in usAIge \(presentation.version)")
                .font(.system(size: 30, weight: .bold))
            Text(presentation.releaseNotes.headline)
                .font(.title3.weight(.semibold))
            Text(presentation.releaseNotes.summary)
                .font(.body).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func highlightRow(_ highlight: ReleaseHighlight) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12))
                Image(systemName: highlight.systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title).font(.headline)
                Text(highlight.detail)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(updateController.statusText)
                .font(.caption).foregroundColor(.secondary).lineLimit(2)
            Spacer()
            Button("Close", action: close).keyboardShortcut(.cancelAction)
            if presentation.isAvailableUpdate {
                Button(updateController.primaryButtonTitle) {
                    Task { await updateController.performPrimaryAction() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!updateController.canPerformPrimaryAction)
            }
        }
    }
}

@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    init(updateController: UpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "What’s New in usAIge"
        window.minSize = NSSize(width: 520, height: 520)
        window.setFrameAutosaveName("WhatsNewWindow")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: WhatsNewView(
            updateController: updateController,
            close: { [weak window] in window?.close() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.setFrameUsingName("WhatsNewWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
}
