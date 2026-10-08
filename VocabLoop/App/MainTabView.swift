import SwiftUI

/// The library: everything that is not a card.
///
/// No longer the app's root — ``StudySessionView`` is, and this is presented from its top bar.
/// The rename is only in the documentation because the type is still a `TabView` and still owns
/// the same five destinations; what changed is that it sits one layer *behind* studying rather
/// than in front of it.
///
/// Study is deliberately not among the tabs. A visible tab bar during review is an invitation to
/// abandon the session, which is the same reason the tabs are a layer down.
struct MainTabView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var selection: Tab = .today

    enum Tab: Hashable {
        case today, browse, decks, progress, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("今天", systemImage: "sun.max") }
                .tag(Tab.today)

            BrowseView()
                .tabItem { Label("浏览", systemImage: "magnifyingglass") }
                .tag(Tab.browse)

            DeckListView()
                .tabItem { Label("词库", systemImage: "square.stack.3d.up") }
                .tag(Tab.decks)

            StatsView()
                .tabItem { Label("进度", systemImage: "chart.bar") }
                .tag(Tab.progress)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Palette.brandPrimary)
        // Sync opportunistically when the app comes forward. Never blocks anything, and is
        // a no-op when there is no server or nothing pending.
        .task(id: dependencies.network.isConnected) {
            await dependencies.sync.sync()
        }
    }
}
