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
        tabs
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                NowPlayingView()
            }
    }

    @ViewBuilder
    private var tabs: some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassTabs
        } else {
            classicTabs
        }
        #else
        classicTabs
        #endif
    }

    /// iOS 17–25: barra dei tab classica, mini player sopra le liste.
    private var classicTabs: some View {
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
    }

    #if compiler(>=6.2)
    /// iOS 26+: Liquid Glass. Barra dei tab in vetro che si riduce scorrendo, Cerca come tab separato
    /// e mini player agganciato sopra la barra, come in Musica di Apple.
    @available(iOS 26, *)
    private var glassTabs: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") { TabStack { HomeView() } }
            Tab("Podcast", systemImage: "mic.fill") { TabStack { PodcastsView() } }
            Tab("Libreria", systemImage: "square.stack.fill") { TabStack { LibraryView() } }
            Tab("Cerca", systemImage: "magnifyingglass", role: .search) { TabStack { SearchView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .playerAccessory(visible: player.current != nil)
    }
    #endif
}

#if compiler(>=6.2)
@available(iOS 26, *)
private extension View {
    /// Mini player sopra la barra dei tab, solo quando c'è qualcosa in riproduzione (iOS 26.1+).
    @ViewBuilder
    func playerAccessory(visible: Bool) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: visible) { MiniPlayerAccessory() }
        } else {
            tabViewBottomAccessory { MiniPlayerAccessory() }
        }
    }
}

/// Mini player dentro la barra dei tab (iOS 26). Si compatta quando la barra si riduce.
@available(iOS 26, *)
struct MiniPlayerAccessory: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let compact = placement == .inline
        HStack(spacing: 10) {
            if let t = player.current {
                ArtworkView(url: t.artworkURL, corner: 6)
                    .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !compact {
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if player.isLoading {
                    ProgressView().frame(width: 30)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 30, height: 30)
                    }
                }
                if !compact {
                    Button {
                        if t.isPodcast { player.skip(by: 30) } else { player.next() }
                    } label: {
                        Image(systemName: t.isPodcast ? "goforward.30" : "forward.fill")
                            .font(.title3)
                            .frame(width: 30, height: 30)
                    }
                }
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                Text("Non in riproduzione").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { player.showFullPlayer = true } }
    }
}
#endif

extension View {
    /// Mostra il mini player in fondo alla schermata e lascia lo spazio per scorrere fino all'ultimo elemento.
    /// Va applicato a ogni schermata con una lista, non al NavigationStack: così l'ultima riga
    /// resta sempre raggiungibile anche nelle pagine aperte dentro la navigazione.
    @ViewBuilder
    func withMiniPlayer() -> some View {
        if usesTabAccessory {
            self      // iOS 26: il mini player sta nella barra dei tab, che gestisce da sola gli spazi
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
        }
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
