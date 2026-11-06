import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                ArtworkView(url: t.artworkURL, corner: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.isLoading {
                    ProgressView().frame(width: 36)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 36, height: 36)
                    }
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
            }
            .foregroundStyle(.primary)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullPlayer = true }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var scrub: Double?
    @State private var showQueue = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ArtworkView(url: player.current?.artworkURL, corner: 0)
                .blur(radius: 70)
                .opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                ArtworkView(url: player.current?.artworkURL, corner: 14)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .scaleEffect(player.isPlaying ? 1 : 0.86)
                    .animation(.spring(duration: 0.45), value: player.isPlaying)

                Spacer(minLength: 0)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.current?.title ?? "")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text(player.current?.artist ?? "")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let t = player.current {
                        Button { library.toggleFavorite(t) } label: {
                            Image(systemName: library.isFavorite(t) ? "heart.fill" : "heart")
                                .font(.title2)
                        }
                    }
                }

                progress

                controls

                if let e = player.errorMessage {
                    Text(e)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack {
                    RoutePickerButton().frame(width: 36, height: 36)
                    Spacer()
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet").font(.title3)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var progress: some View {
        let total = max(player.duration, 1)
        let value = min(scrub ?? player.currentTime, total)
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { value }, set: { scrub = $0 }),
                in: 0...total,
                onEditingChanged: { editing in
                    if !editing, let s = scrub {
                        player.seek(to: s)
                        scrub = nil
                    }
                }
            )
            HStack {
                Text(formatTime(value))
                Spacer()
                Text(player.duration > 0 ? "-" + formatTime(player.duration - value) : (player.current?.duration ?? ""))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 46) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Button { player.togglePlay() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                    }
                }
                .frame(width: 64, height: 64)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
        }
        .foregroundStyle(.primary)
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Radio automatica", isOn: $player.autoRadio)
                } footer: {
                    Text("Quando la coda sta per finire aggiunge brani simili, come fa Spotify.")
                }

                Section("Coda") {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: 12) {
                            ArtworkView(url: t.artworkURL).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title)
                                    .fontWeight(i == player.index ? .semibold : .regular)
                                    .lineLimit(1)
                                Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if i == player.index {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                        .opacity(i < player.index ? 0.45 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: i) }
                    }
                    .onDelete { player.removeFromQueue(at: $0) }
                    .onMove { player.moveQueue(from: $0, to: $1) }
                }
            }
            .navigationTitle("In riproduzione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
    }
}
