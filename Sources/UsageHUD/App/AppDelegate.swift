import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings: HUDSettings
    let store: UsageStore
    private var panel: HUDPanel?

    override init() {
        settings = HUDSettings()
        if let executable = CodexExecutableResolver.resolve() {
            let transport = ProcessLineTransport(executableURL: executable)
            let connection = JSONRPCConnection(transport: transport)
            store = UsageStore(provider: CodexUsageProvider(rpc: connection))
        } else {
            store = UsageStore(provider: MissingCodexProvider())
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let content = HUDView(
            store: store,
            settings: settings,
            openCodex: Self.openCodex,
            resizePanel: { [weak self] height in self?.resizePanel(to: height) }
        )
        let panel = HUDPanel(contentView: NSHostingView(rootView: content))
        panel.delegate = self
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, let screen = panel.screen else { return }
        settings.setPosition(panel.frame.origin, for: Self.displayKey(for: screen))
    }

    func resetPanelPosition() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let key = Self.displayKey(for: screen)
        settings.resetPosition(for: key)
        positionPanel(panel, on: screen)
    }

    private func positionPanel(_ panel: NSPanel, on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        let key = Self.displayKey(for: screen)
        let frame = PanelPositioner.frame(
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            savedOrigin: settings.position(for: key)
        )
        panel.setFrame(frame, display: true)
    }

    private func resizePanel(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        panel.setFrame(
            CGRect(x: panel.frame.minX, y: panel.frame.minY, width: 292, height: height),
            display: true,
            animate: false
        )
    }

    static func displayKey(for screen: NSScreen) -> String {
        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[numberKey] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    private static func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

private enum CodexExecutableResolver {
    static func resolve() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for directory in pathEntries {
            let path = String(directory) + "/codex"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

private actor MissingCodexProvider: CodexUsageProviding {
    func refresh() async throws -> AccountUsageResult {
        throw MissingCodexError.notInstalled
    }

    func updates() async -> AsyncStream<[QuotaSnapshot]> {
        AsyncStream { $0.finish() }
    }
}

private enum MissingCodexError: Error {
    case notInstalled
}
