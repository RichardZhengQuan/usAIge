import SwiftUI

@main
struct usAIgeWatchApp: App {
    @StateObject private var model = WatchUsageModel()

    var body: some Scene {
        WindowGroup {
            WatchUsageView(model: model)
        }
    }
}
