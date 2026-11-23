import SwiftUI
import AppPreferences
import LocalStreamProxy

@main
struct AuraTVApp: App {
    @StateObject private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selection: RootTab = .home

    enum RootTab: Hashable {
        case home, sources, settings
    }

    var body: some View {
        ZStack {
            TVTheme.backdrop.ignoresSafeArea()

            TabView(selection: $selection) {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house.fill") }
                    .tag(RootTab.home)

                SourceListView()
                    .tabItem { Label("网络源", systemImage: "externaldrive.connected.to.line.below") }
                    .tag(RootTab.sources)

                AppSettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(RootTab.settings)
            }
            .tabViewStyle(.automatic)
        }
    }
}
