import SwiftUI

enum AppSection: Hashable {
    case usage
    case connection
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

            Tab("Connection", systemImage: "macbook.and.iphone", value: .connection) {
                NavigationStack {
                    ToolsView()
                }
            }
        }
    }
}
