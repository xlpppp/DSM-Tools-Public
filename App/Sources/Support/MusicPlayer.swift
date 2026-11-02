import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit
import DSMKit

/// App-wide audio player for Audio Station and third-party music servers.
/// Plays in the background and shows on the lock screen.
@MainActor
@Observable
final class MusicPlayer {
    struct Track: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let duration: Double?
        /// Resolves the playable URL when the track starts (session URLs expire).
        let resolve: @Sendable () async throws -> URL
        let artwork: (@Sendable () async -> UIImage?)?

        static func == (a: Track, b: Track) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var artwork: UIImage?
    private(set) var error: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        setupRemoteCommands()
    }

    func play(_ tracks: [Track], startAt start: Int = 0) {
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        startCurrent()
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
        guard index + 1 < queue.count else { return }
        index += 1
        startCurrent()
    }

    func previous() {
        if elapsed > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            startCurrent()
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
        updateNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaLoader = nil
        isPlaying = false
        queue = []
        cleanupLocal()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func startCurrent() {
        guard let track = current else { return }
        loadTask?.cancel()
        player.pause()
        isLoading = true
        error = nil
        elapsed = 0
        duration = track.duration ?? 0
        artwork = nil
        cleanupLocal()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        loadTask = Task {
            do {
                var url = try await track.resolve()
                if !url.isFileURL && requiresDownload(url) {
                    // The system player can't use a certificate trusted only inside the app.
                    let ext = url.pathExtension
                    let fileName = ext.isEmpty || (track.title as NSString).pathExtension.lowercased() == ext.lowercased()
                        ? track.title : "\(track.title).\(ext)"
                    url = try await downloadForPlayback(url, name: fileName)
                    localFile = url
                }
                guard !Task.isCancelled else { return }
                let item: AVPlayerItem
                if let mediaFetch, !url.isFileURL {
                    let loader = PinnedMediaLoader(fetch: mediaFetch, source: url, mime: Self.mime(url))
                    let asset = AVURLAsset(url: loader.assetURL)
                    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                    item = AVPlayerItem(asset: asset)
                    player.replaceCurrentItem(with: item)
                    mediaLoader = loader
                } else {
                    item = AVPlayerItem(url: url)
                    player.replaceCurrentItem(with: item)
                    mediaLoader = nil
                }
                observeEnd(of: item)
                player.play()
                isPlaying = true
                isLoading = false
                updateNowPlaying()
                if let art = await track.artwork?(), !Task.isCancelled {
                    artwork = art
                    updateNowPlaying()
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                self.error = error.userMessage
            }
        }
    }

    /// Set when AVPlayer cannot open the URL itself (pinned certificate or nginx basic auth).
    @ObservationIgnored var mediaFetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?
    /// Set by the app for servers whose certificate is pinned; those URLs are fetched first.
    @ObservationIgnored var downloader: (@Sendable (URL, String) async throws -> URL)?
    @ObservationIgnored var pinnedHosts: Set<String> = []
    @ObservationIgnored private var mediaLoader: PinnedMediaLoader?

    private func requiresDownload(_ url: URL) -> Bool {
        // Host strings differ between the saved endpoint and the stream URL (IP, QuickConnect, port).
        // A downloader is installed only when the DSM certificate is pinned.
        !url.isFileURL && mediaFetch == nil && downloader != nil
    }

    private static func mime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    private func downloadForPlayback(_ url: URL, name: String) async throws -> URL {
        guard let downloader else { return url }
        return try await downloader(url, name)
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.index + 1 < self.queue.count { self.next() } else { self.isPlaying = false }
            }
        }
    }

    private func cleanupLocal() {
        if let localFile { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
        localFile = nil
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { self?.togglePlay() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == true { self?.togglePlay() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }
}
