import SwiftUI

@main
struct ArmoniaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerManager.shared
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(downloads)
                .tint(Color(red: 1.0, green: 0.22, blue: 0.37))
                .preferredColorScheme(.dark)
                .onAppear {
                    player.library = library
                    downloads.library = library
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { SearchView() }
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }

            NavigationStack { LibraryView() }
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("Libreria", systemImage: "square.stack.fill") }
        }
        .fullScreenCover(isPresented: $player.showFullPlayer) {
            NowPlayingView()
        }
    }
}
