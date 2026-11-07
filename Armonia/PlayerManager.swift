import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import UIKit

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?
    @Published var showFullPlayer = false
    /// Qualità del brano in riproduzione, es. "AAC 128 kbps" o "FLAC · locale".
    @Published private(set) var qualityLabel: String = ""
    @Published var streamQuality: AudioQuality = AudioQuality.stored("streamQuality", legacyLowKey: "streamLowQuality") {
        didSet { UserDefaults.standard.set(streamQuality.rawValue, forKey: "streamQuality") }
    }
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
                if s.isFinite { self?.currentTime = s }
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
        queue = tracks
        index = i
        loadCurrent()
    }

    /// Riproduce il brano e riempie la coda con brani simili.
    func startRadio(from track: Track) {
        play([track])
        extendWithRadio(from: track)
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]) } else { queue.insert(track, at: index + 1) }
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]) } else { queue.append(track) }
    }

    func togglePlay() {
        if player.currentItem == nil {
            if current != nil { failures = 0; loadCurrent() }
        } else if isPlaying {
            player.pause()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
    }

    func resume() {
        guard player.currentItem != nil else { togglePlay(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
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

    // MARK: - Caricamento

    private func advance() {
        if index + 1 < queue.count {
            index += 1
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
        if !track.isLocal { library?.addRecent(track) }

        // Brano scaricato o file importato: si riproduce dal telefono, senza rete.
        if let file = Storage.playableFile(for: track) {
            let ext = file.pathExtension.uppercased()
            qualityLabel = track.isLocal ? "\(ext == "M4A" ? "ALAC/AAC" : ext) · file locale" : (ext == "CAF" ? "Scaricato · Opus" : "Scaricato · AAC")
            let item = AVPlayerItem(url: file)
            observe(item)
            player.replaceCurrentItem(with: item)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            if autoRadio && !track.isLocal && index >= queue.count - 2 { extendWithRadio(from: track) }
            return
        }
        if track.isLocal {
            handleFailure("File non trovato sul telefono.")
            return
        }

        playingOpusFile = false
        let quality = forceNormalOnce ? .normal : streamQuality
        forceNormalOnce = false
        // Alta qualità già pronta in cache: parte subito, senza rete.
        if quality == .high, let cached = OpusCache.cachedFile(for: track.id) {
            playFile(cached, label: OpusCache.label(for: track.id))
            if autoRadio && index >= queue.count - 2 { extendWithRadio(from: track) }
            return
        }
        loadTask = Task { [weak self] in
            do {
                var stream = try await Innertube.shared.stream(for: track.id, quality: quality)
                if stream.isOpus {
                    do {
                        let file = try await OpusCache.shared.file(for: track.id, info: stream)
                        guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                        self.playFile(file, label: stream.label)
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        // Conversione non riuscita: si ascolta in AAC.
                        stream = try await Innertube.shared.stream(for: track.id, quality: .normal)
                    }
                }
                guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                self.qualityLabel = stream.label
                let asset = AVURLAsset(url: stream.url,
                                       options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": stream.userAgent]])
                let item = AVPlayerItem(asset: asset)
                self.observe(item)
                self.player.replaceCurrentItem(with: item)
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player.play()
            } catch {
                guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
                self.handleFailure(error.localizedDescription)
            }
        }

        if autoRadio && index >= queue.count - 2 {
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
        player.play()
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
            Task { @MainActor in self?.next() }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, duration dur: Double, error: String?) {
        switch status {
        case .readyToPlay:
            isLoading = false
            failures = 0
            if dur.isFinite && dur > 0 { duration = dur }
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
        guard Storage.playableFile(for: next) == nil, !next.isLocal else { return }
        let id = next.id
        let quality = streamQuality
        Task.detached(priority: .utility) {
            guard let info = try? await Innertube.shared.stream(for: id, quality: quality) else { return }
            // In alta qualità si prepara già il file del brano successivo, così parte senza attesa.
            if info.isOpus { _ = try? await OpusCache.shared.file(for: id, info: info) }
        }
    }

    private func extendWithRadio(from seed: Track) {
        if seed.isLocal {
            // Niente radio per i file locali: a fine coda si ferma.
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

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artworkID == t.id { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
