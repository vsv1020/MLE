import SwiftUI

/// The five top-level destinations.
///
/// Study is deliberately **not** among them. A review session is presented as a
/// full-screen cover from Today or from a deck, because a visible tab bar during review is
/// an invitation to abandon the session.
struct MainTabView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var selection: Tab = .today

    enum Tab: Hashable {
        case today, browse, decks, progress, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(Tab.today)

            BrowseView()
                .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                .tag(Tab.browse)

            DeckListView()
                .tabItem { Label("Decks", systemImage: "square.stack.3d.up") }
                .tag(Tab.decks)

            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(Tab.progress)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
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
