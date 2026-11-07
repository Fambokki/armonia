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
            TabStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }

            TabStack { SearchView() }
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }

            TabStack { PodcastsView() }
                .tabItem { Label("Podcast", systemImage: "mic.fill") }

            TabStack { LibraryView() }
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

/// Navigazione di una scheda. Le pagine si aprono con `nav.open(...)`: così più riquadri nella
/// stessa riga (griglie, caroselli) aprono solo quello toccato, e non tutti insieme.
@MainActor
final class Navigator: ObservableObject {
    @Published var path = NavigationPath()

    func open<V: Hashable>(_ value: V) {
        path.append(value)
    }
}

struct TabStack<Content: View>: View {
    @StateObject private var nav = Navigator()
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $nav.path) {
            content().appDestinations()
        }
        .environmentObject(nav)
    }
}

extension View {
    /// Tutte le pagine che si possono aprire da qualsiasi scheda.
    func appDestinations() -> some View {
        self
            .navigationDestination(for: BrowseTarget.self) { BrowsePageView(target: $0) }
            .navigationDestination(for: TrackSource.self) { TrackListScreen(source: $0) }
            .navigationDestination(for: PodcastShow.self) { PodcastDetailView(show: $0) }
    }
}
