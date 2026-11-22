import Foundation
import SwiftUI

@main
struct usAIgeWatchApp: App {
    @StateObject private var model = WatchUsageModel()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "usaigeComplicationGallery") {
                ComplicationGalleryView()
            } else {
                WatchUsageView(model: model)
            }
            #else
            WatchUsageView(model: model)
            #endif
        }
    }
}
