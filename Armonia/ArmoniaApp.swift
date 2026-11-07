import SwiftUI

@main
struct ArmoniaApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerManager.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var podcasts = PodcastStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(podcasts)
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
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { SearchView() }
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }

            NavigationStack { PodcastsView() }
                .tabItem { Label("Podcast", systemImage: "mic.fill") }

            NavigationStack { LibraryView() }
                .tabItem { Label("Libreria", systemImage: "square.stack.fill") }
        }
        .fullScreenCover(isPresented: $player.showFullPlayer) {
            NowPlayingView()
        }
    }
}

extension View {
    /// Mostra il mini player in fondo alla schermata e lascia lo spazio per scorrere fino all'ultimo elemento.
    /// Va applicato a ogni schermata con una lista, non al NavigationStack: così l'ultima riga
    /// resta sempre raggiungibile anche nelle pagine aperte dentro la navigazione.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
    }
}
