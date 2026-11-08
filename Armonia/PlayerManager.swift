import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import UIKit

/// Tempo di riproduzione, separato dal player: lo osservano solo le barre di avanzamento.
@MainActor
final class PlaybackClock: ObservableObject {
    static let shared = PlaybackClock()
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    /// Tempo e durata NON sono @Published: cambiano due volte al secondo e farebbero ridisegnare
    /// tutta l'app. Le barre di avanzamento li leggono da `PlaybackClock`.
    private(set) var currentTime: Double = 0 {
        didSet { if abs(clock.time - currentTime) >= 0.25 || currentTime == 0 { clock.time = currentTime } }
    }
    private(set) var duration: Double = 0 {
        didSet { if clock.duration != duration { clock.duration = duration } }
    }
    let clock = PlaybackClock.shared
    @Published var errorMessage: String?
    @Published var showFullPlayer = false
    /// Qualità del brano in riproduzione, es. "AAC 128 kbps" o "FLAC · locale".
    @Published private(set) var qualityLabel: String = ""
    @Published var streamQuality: AudioQuality = AudioQuality.stored("streamQuality", legacyLowKey: "streamLowQuality") {
        didSet { UserDefaults.standard.set(streamQuality.rawValue, forKey: "streamQuality") }
    }
    /// Velocità di riproduzione dei podcast (la musica va sempre a 1×).
    @Published var playbackRate: Float = UserDefaults.standard.object(forKey: "podcastRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "podcastRate")
            if current?.isPodcast == true {
                player.defaultRate = playbackRate
                if isPlaying { player.rate = playbackRate }
                updateNowPlaying()
            }
        }
    }
    enum RepeatMode: String, CaseIterable {
        case off, all, one
    }

    /// Modalità casuale: la coda viene mescolata, l'ordine originale resta in `originalQueue`.
    @Published private(set) var shuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "shuffleEnabled")
    @Published private(set) var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off
    private var originalQueue: [Track] = []

    @Published var autoRadio: Bool = UserDefaults.standard.object(forKey: "autoRadio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRadio, forKey: "autoRadio") }
    }

    weak var library: LibraryStore?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var controlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var artworkID: String?
    private var pendingAdvance = false
    private var generation = 0
    private var failures = 0

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        configureRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let s = time.seconds
            Task { @MainActor in
                if s.isFinite {
                    self?.currentTime = s
                    self?.savePositionIfNeeded()
                }
            }
        }

        controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in self?.controlStatusChanged(status) }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.handleInterruption(type: type, options: options) }
        }
    }

    // MARK: - Comandi pubblici

    func play(_ tracks: [Track], startAt i: Int = 0) {
        guard tracks.indices.contains(i) else { return }
        generation += 1
        radioTask?.cancel()
        radioTask = nil
        pendingAdvance = false
        failures = 0
        originalQueue = tracks
        if shuffleEnabled {
            var rest = tracks
            let first = rest.remove(at: i)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = i
        }
        loadCurrent()
    }

    /// "Casuale" delle liste: attiva la modalità casuale e parte da un brano a caso.
    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        setShuffle(true)
        play(tracks, startAt: Int.random(in: 0..<tracks.count))
    }

    func toggleShuffle() { setShuffle(!shuffleEnabled) }

    func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        UserDefaults.standard.set(on, forKey: "shuffleEnabled")
        guard !queue.isEmpty else { updateShuffleRepeatCommands(); return }
        if on {
            // Il brano attuale resta in testa, il resto si mescola.
            originalQueue = queue
            let cur = queue[index]
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            // Si torna all'ordine originale, ripartendo dal brano attuale.
            let cur = current
            let extra = queue.filter { t in !originalQueue.contains { $0.id == t.id } }
            queue = originalQueue + extra
            index = cur.flatMap { c in queue.firstIndex { $0.id == c.id } } ?? 0
        }
        updateShuffleRepeatCommands()
    }

    /// Ripeti: no → tutta la coda → solo questo brano → no.
    func cycleRepeat() {
        switch repeatMode {
        case .off: setRepeat(.all)
        case .all: setRepeat(.one)
        case .one: setRepeat(.off)
        }
    }

    func setRepeat(_ m: RepeatMode) {
        repeatMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "repeatMode")
        updateShuffleRepeatCommands()
    }

    /// Riproduce il brano e riempie la coda con brani simili.
    func startRadio(from track: Track) {
        play([track])
        extendWithRadio(from: track)
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]) } else {
            queue.insert(track, at: index + 1)
            if shuffleEnabled, let cur = current, let j = originalQueue.firstIndex(where: { $0.id == cur.id }) {
                originalQueue.insert(track, at: j + 1)
            }
        }
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]) } else {
            queue.append(track)
            if shuffleEnabled { originalQueue.append(track) }
        }
    }

    func togglePlay() {
        if player.currentItem == nil {
            if current != nil { failures = 0; loadCurrent() }
        } else if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            startPlayer()
        }
    }

    func resume() {
        guard player.currentItem != nil else { togglePlay(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        startPlayer()
    }

    func pause() { player.pause() }

    func next() {
        failures = 0
        advance()
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent()
        }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        failures = 0
        index = i
        loadCurrent()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    func removeFromQueue(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i != index && queue.indices.contains(i) {
            let id = queue[i].id
            if let j = originalQueue.firstIndex(where: { $0.id == id }) { originalQueue.remove(at: j) }
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        let currentID = current?.id
        let currentPos = index
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentID {
            let candidates = queue.indices.filter { queue[$0].id == currentID }
            index = candidates.min(by: { abs($0 - currentPos) < abs($1 - currentPos) }) ?? 0
        }
    }

    /// Avanti/indietro di qualche secondo (podcast).
    func skip(by delta: Double) {
        let target = max(0, min(currentTime + delta, duration > 0 ? duration - 1 : currentTime + delta))
        seek(to: target)
        savePosition()
    }

    private func startPlayer() {
        let rate: Float = current?.isPodcast == true ? playbackRate : 1
        player.defaultRate = rate
        player.play()
        if player.rate != rate { player.rate = rate }
    }

    // MARK: - Posizione negli episodi

    private var pendingResume: Double = 0
    private var lastSavedAt: Double = 0

    private func savePositionIfNeeded() {
        guard abs(currentTime - lastSavedAt) >= 5 else { return }
        savePosition()
    }

    private func savePosition() {
        guard let t = current, t.isPodcast, currentTime > 0, pendingResume == 0 else { return }
        lastSavedAt = currentTime
        if duration > 0 && currentTime > duration - 30 {
            PodcastStore.shared.setPlayed(t, true)
        } else {
            PlaybackPositions.set(t.id, currentTime)
        }
    }

    // MARK: - Caricamento

    private func advance() {
        if index + 1 < queue.count {
            index += 1
            loadCurrent()
        } else if repeatMode != .off, !queue.isEmpty {
            // Ripeti la coda: in casuale la si rimescola a ogni giro.
            if shuffleEnabled && queue.count > 1 {
                let last = queue[index]
                var q = queue.shuffled()
                if q.first?.id == last.id { q.swapAt(0, q.count - 1) }
                queue = q
            }
            index = 0
            loadCurrent()
        } else if autoRadio, let cur = current {
            pendingAdvance = true
            extendWithRadio(from: cur)
        } else {
            player.pause()
            seek(to: 0)
        }
    }

    private func loadCurrent() {
        guard let track = current else { return }
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isLoading = true
        currentTime = 0
        duration = 0
        errorMessage = nil
        qualityLabel = ""
        loadArtwork(for: track)
        updateNowPlaying()
        if !track.isLocal && !track.isPodcast { library?.addRecent(track) }
        updateRemoteCommands(for: track)
        pendingResume = track.isPodcast ? PlaybackPositions.get(track.id) : 0

        // Brano scaricato o file importato: si riproduce dal telefono, senza rete.
        if let file = Storage.playableFile(for: track) {
            let ext = file.pathExtension.uppercased()
            qualityLabel = track.isLocal ? "\(ext == "M4A" ? "ALAC/AAC" : ext) · file locale" : (ext == "CAF" ? "Scaricato · Opus" : "Scaricato · AAC")
            let item = AVPlayerItem(url: file)
            observe(item)
            player.replaceCurrentItem(with: item)
            try? AVAudioSession.sharedInstance().setActive(true)
            startPlayer()
            if track.isPodcast { qualityLabel = "Podcast · scaricato" }
            if autoRadio && repeatMode == .off && !track.isLocal && !track.isPodcast && index >= queue.count - 2 { extendWithRadio(from: track) }
            return
        }
        if track.isLocal {
            handleFailure("File non trovato sul telefono.")
            return
        }
        // Episodio di un podcast: si ascolta direttamente dal suo indirizzo.
        if track.isPodcast {
            guard let m = track.mediaURL, let url = URL(string: m) else {
                handleFailure("Episodio non disponibile.")
                return
            }
            qualityLabel = "Podcast"
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "Armonia/1.0 (iPhone; podcast player)"]])
            let item = AVPlayerItem(asset: asset)
            observe(item)
            player.replaceCurrentItem(with: item)
            try? AVAudioSession.sharedInstance().setActive(true)
            startPlayer()
            return
        }

        playingOpusFile = false
        let quality = forceNormalOnce ? .normal : streamQuality
        forceNormalOnce = false
        // Alta qualità già pronta in cache: parte subito, senza rete.
        if quality == .high, let cached = OpusCache.cachedFile(for: track.id) {
            playFile(cached, label: OpusCache.label(for: track.id))
            if autoRadio && repeatMode == .off && index >= queue.count - 2 { extendWithRadio(from: track) }
            return
        }
        loadTask = Task { [weak self] in
            do {
                var stream = try await Innertube.shared.stream(for: track.id, quality: quality)
                var fallbackNote = stream.note.map { "Alta qualità non disponibile: " + $0 }
                if stream.isOpus {
                    do {
                        let file = try await OpusCache.shared.file(for: track.id, info: stream)
                        guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                        self.playFile(file, label: stream.label)
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        // Conversione non riuscita: si ascolta in AAC, ma lo si dice.
                        fallbackNote = "Conversione Opus non riuscita: " + error.localizedDescription
                        stream = try await Innertube.shared.stream(for: track.id, quality: .normal)
                    }
                }
                guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                self.qualityLabel = stream.label
                if let fallbackNote { self.errorMessage = fallbackNote }
                let asset = AVURLAsset(url: stream.url,
                                       options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": stream.userAgent]])
                let item = AVPlayerItem(asset: asset)
                self.observe(item)
                self.player.replaceCurrentItem(with: item)
                try? AVAudioSession.sharedInstance().setActive(true)
                self.startPlayer()
            } catch {
                guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                self.handleFailure(error.localizedDescription)
            }
        }

        if autoRadio && repeatMode == .off && index >= queue.count - 2 {
            extendWithRadio(from: track)
        }
    }

    /// true mentre si riproduce un file Opus convertito (per ripiegare sull'AAC se iOS lo rifiuta).
    private var playingOpusFile = false
    private var forceNormalOnce = false

    private func playFile(_ file: URL, label: String, isOpus: Bool = true) {
        playingOpusFile = isOpus && file.pathExtension == "caf"
        qualityLabel = label
        let item = AVPlayerItem(url: file)
        observe(item)
        player.replaceCurrentItem(with: item)
        try? AVAudioSession.sharedInstance().setActive(true)
        startPlayer()
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let dur = item.duration.seconds
            let err = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, duration: dur, error: err) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let t = self.current, t.isPodcast { PodcastStore.shared.setPlayed(t, true) }
                if self.repeatMode == .one, self.current?.isPodcast != true {
                    self.seek(to: 0)
                    self.startPlayer()
                } else {
                    self.next()
                }
            }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, duration dur: Double, error: String?) {
        switch status {
        case .readyToPlay:
            isLoading = false
            failures = 0
            if dur.isFinite && dur > 0 { duration = dur }
            if pendingResume > 15, duration == 0 || pendingResume < duration - 20 {
                seek(to: pendingResume)
            }
            pendingResume = 0
            updateNowPlaying()
            prefetchNext()
        case .failed:
            if playingOpusFile, let t = current {
                // Il file Opus convertito non è stato accettato: lo si elimina e si riprova in AAC.
                playingOpusFile = false
                try? FileManager.default.removeItem(at: OpusCache.url(for: t.id))
                errorMessage = "Alta qualità non riuscita per questo brano: uso l'AAC."
                forceNormalOnce = true
                loadCurrent()
                errorMessage = "Alta qualità non riuscita per questo brano: uso l'AAC."
                return
            }
            handleFailure(error ?? "errore di riproduzione")
        default:
            break
        }
    }

    private func handleFailure(_ message: String) {
        isLoading = false
        errorMessage = message
        failures += 1
        // Salta automaticamente al brano successivo, ma senza scorrere tutta la coda se è tutto rotto.
        if failures < 3 && index + 1 < queue.count {
            index += 1
            loadCurrent()
        }
    }

    private func prefetchNext() {
        guard queue.indices.contains(index + 1) else { return }
        let next = queue[index + 1]
        guard Storage.playableFile(for: next) == nil, !next.isLocal, !next.isPodcast else { return }
        let id = next.id
        let quality = streamQuality
        Task.detached(priority: .utility) {
            guard let info = try? await Innertube.shared.stream(for: id, quality: quality) else { return }
            // In alta qualità si prepara già il file del brano successivo, così parte senza attesa.
            if info.isOpus { _ = try? await OpusCache.shared.file(for: id, info: info) }
        }
    }

    private func extendWithRadio(from seed: Track) {
        if seed.isLocal || seed.isPodcast {
            // Niente radio per file locali e podcast: a fine coda si ferma.
            if pendingAdvance { pendingAdvance = false; player.pause(); seek(to: 0) }
            return
        }
        guard radioTask == nil else { return }
        let gen = generation
        radioTask = Task { [weak self] in
            let related = (try? await Innertube.shared.radio(for: seed.id)) ?? []
            guard let self, gen == self.generation else { return }
            self.radioTask = nil
            let existing = Set(self.queue.map(\.id))
            let fresh = related.filter { !existing.contains($0.id) }
            self.queue.append(contentsOf: fresh.prefix(25))
            if self.shuffleEnabled { self.originalQueue.append(contentsOf: fresh.prefix(25)) }
            if self.pendingAdvance {
                self.pendingAdvance = false
                if self.index + 1 < self.queue.count {
                    self.index += 1
                    self.loadCurrent()
                }
            }
        }
    }

    // MARK: - Stato di sistema

    private func controlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        let playing = status != .paused
        if !playing { savePosition() }
        if playing != isPlaying {
            isPlaying = playing
            updateNowPlaying()
        }
        if status == .playing { isLoading = false }
    }

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        if kind == .ended, let options,
           AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            resume()
        }
    }

    private func updateShuffleRepeatCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.currentShuffleType = shuffleEnabled ? .items : .off
        c.changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : (repeatMode == .all ? .all : .off)
    }

    /// Schermata di blocco: per i podcast salti di 15/30 s al posto di brano precedente/successivo.
    private func updateRemoteCommands(for t: Track) {
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.isEnabled = t.isPodcast
        c.skipForwardCommand.isEnabled = t.isPodcast
        c.previousTrackCommand.isEnabled = !t.isPodcast
        c.nextTrackCommand.isEnabled = !t.isPodcast
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 30) }
            return .success
        }
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = e.shuffleType != .off
            Task { @MainActor in self?.setShuffle(on) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = e.repeatType == .one ? .one : (e.repeatType == .all ? .all : .off)
            Task { @MainActor in self?.setRepeat(mode) }
            return .success
        }
        DispatchQueue.main.async { [weak self] in self?.updateShuffleRepeatCommands() }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        artwork = nil
        artworkID = nil
        guard let url = track.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0) else { return }
            guard let self, self.current?.id == track.id else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artworkID = track.id
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(t.isPodcast ? playbackRate : 1) : 0.0
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artworkID == t.id { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
