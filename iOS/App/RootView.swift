import SwiftUI

enum AppSection: Hashable {
    case usage
    case tools
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppSection = .usage

    var body: some View {
        @Bindable var model = model

        TabView(selection: $selection) {
            Tab("Usage", systemImage: "gauge.with.dots.needle.67percent", value: .usage) {
                NavigationStack {
                    DashboardView()
                }
            }

            Tab("Tools", systemImage: "shippingbox.and.arrow.backward", value: .tools) {
                NavigationStack {
                    ToolsView()
                }
            }
        }
        .sheet(isPresented: $model.isPresentingAddTool) {
            NavigationStack {
                AddToolView()
            }
        }
    }
}
