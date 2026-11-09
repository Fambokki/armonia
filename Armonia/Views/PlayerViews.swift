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
            .overlay(alignment: .bottom) { MiniProgressLine().padding(.horizontal, 14) }
            .glassRect(14, interactive: true)
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

    @State private var showQueue = false
    /// Spostamento verso il basso mentre si trascina per chiudere.
    @State private var dragOffset: CGFloat = 0

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

                if !player.qualityLabel.isEmpty {
                    Text(player.qualityLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassCapsule()
                        .foregroundStyle(.secondary)
                }

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
                    if isPodcast {
                        speedMenu
                        Spacer()
                    }
                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet").font(.title3)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .offset(y: dragOffset)
        .gesture(dismissDrag)
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var progress: some View {
        PlaybackProgress()
    }

    /// Trascinando verso il basso il player scende con il dito; oltre una certa soglia si chiude.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                let dy = v.translation.height
                guard dy > 0 || dragOffset > 0 else { return }
                // Solo movimenti soprattutto verticali (lo slider del brano resta libero).
                guard dragOffset > 0 || abs(dy) > abs(v.translation.width) * 1.2 else { return }
                dragOffset = max(0, dy)
            }
            .onEnded { v in
                let shouldClose = v.translation.height > 140 || v.predictedEndTranslation.height > 420
                if shouldClose && dragOffset > 0 {
                    let h = UIScreen.main.bounds.height
                    withAnimation(.easeOut(duration: 0.22)) { dragOffset = h }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { player.showFullPlayer = false }
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = 0 }
                }
            }
    }

    private var isPodcast: Bool { player.current?.isPodcast == true }

    private var controls: some View {
        HStack(spacing: 0) {
            if !isPodcast {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(player.shuffleEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .bottom) { if player.shuffleEnabled { activeDot } }
                }
                .accessibilityLabel(player.shuffleEnabled ? "Casuale attiva" : "Casuale")
                Spacer(minLength: 0)
            }
            mainControls
            if !isPodcast {
                Spacer(minLength: 0)
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .bottom) { if player.repeatMode != .off { activeDot } }
                }
                .accessibilityLabel(["off": "Ripeti", "all": "Ripeti tutto", "one": "Ripeti brano"][player.repeatMode.rawValue] ?? "Ripeti")
            }
        }
    }

    private var activeDot: some View {
        Circle().fill(Color.accentColor).frame(width: 4, height: 4).offset(y: 2)
    }

    private var mainControls: some View {
        HStack(spacing: isPodcast ? 46 : 34) {
            if isPodcast {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 30))
                }
            } else {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 30))
                }
            }
            Button { player.togglePlay() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                    }
                }
                .frame(width: 78, height: 78)
                .glassCircle(interactive: true)
            }
            if isPodcast {
                Button { player.skip(by: 30) } label: {
                    Image(systemName: "goforward.30").font(.system(size: 30))
                }
            } else {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 30))
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                Button {
                    player.playbackRate = Float(r)
                } label: {
                    if abs(Double(player.playbackRate) - r) < 0.01 {
                        Label(speedText(Float(r)), systemImage: "checkmark")
                    } else {
                        Text(speedText(Float(r)))
                    }
                }
            }
        } label: {
            Text(speedText(player.playbackRate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassCapsule(interactive: true)
        }
        .foregroundStyle(.secondary)
    }

    private func speedText(_ r: Float) -> String {
        let s = r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)
        return s.replacingOccurrences(of: ".", with: ",") + "×"
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Button { player.toggleShuffle() } label: {
                            Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .tint(player.shuffleEnabled ? .accentColor : .gray)
                        Button { player.cycleRepeat() } label: {
                            Label(player.repeatMode == .one ? "Ripeti brano" : (player.repeatMode == .all ? "Ripeti tutto" : "Ripeti"),
                                  systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(player.repeatMode == .off ? .gray : .accentColor)
                    }
                    .glassButton()
                    .listRowSeparator(.hidden)
                    Toggle("Radio automatica", isOn: $player.autoRadio)
                } footer: {
                    Text("Radio automatica: quando la coda sta per finire aggiunge brani simili. Si sospende mentre è attivo \"Ripeti\".")
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


/// Barra di avanzamento: è l'unica parte che si aggiorna mentre la musica scorre.
struct PlaybackProgress: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var clock = PlaybackClock.shared
    @State private var scrub: Double?

    var body: some View {
        let total = max(clock.duration, 1)
        let value = min(scrub ?? clock.time, total)
        VStack(spacing: 4) {
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
                Text(clock.duration > 0 ? "-" + formatTime(clock.duration - value) : (player.current?.duration ?? ""))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// Sottile linea di avanzamento sotto il mini player.
struct MiniProgressLine: View {
    @ObservedObject private var clock = PlaybackClock.shared

    var body: some View {
        GeometryReader { g in
            let f = clock.duration > 0 ? min(clock.time / clock.duration, 1) : 0
            Capsule().fill(Color.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor).frame(width: g.size.width * f)
                }
        }
        .frame(height: 2)
    }
}
