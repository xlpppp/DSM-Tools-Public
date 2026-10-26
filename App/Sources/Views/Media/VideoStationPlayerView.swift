import SwiftUI
import AVKit
import DSMKit

/// Full-screen player for Video Station items. On top of the system player it adds what Video
/// Station offers: resume from the saved position (shared with the web and TV apps), text
/// subtitles drawn by the app, and a quality menu that switches to server-side HLS transcoding.
struct VideoStationPlayerView: View {
    let title: String
    let file: VideoFile
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var stream: VideoStream?
    @State private var quality: VideoQuality = .original
    @State private var subtitles: [VideoSubtitle] = []
    @State private var subtitleID: String?
    @State private var track: SubtitleTrack?
    @State private var caption: String?
    @State private var status: String? = "正在准备…"
    @State private var notice: String?
    @State private var resumeAt: Double?
    @State private var observer: Any?
    @State private var lastSaved: Double = 0
    @State private var mediaLoader: PinnedMediaLoader?
    @Environment(\.openURL) private var openURL
    @State private var externalError: String?

    /// Containers AVPlayer opens directly; anything else (mkv, avi, rmvb…) needs transcoding.
    static let nativeContainers: Set<String> = ["mp4", "m4v", "mov"]
    /// The File Station URL ends in entry.cgi, so AVFoundation is told the type instead of guessing.
    static let mimeTypes: [String: String] = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player) { captionOverlay }
                    .ignoresSafeArea()
            } else if let resumeAt {
                resumeCard(resumeAt)
            } else {
                VStack(spacing: 12) {
                    if status == "正在准备…" { ProgressView().tint(.white) }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    }
                }
                .padding(32)
            }
        }
        .overlay(alignment: .top) { topBar }
        .task { await prepare() }
        .onDisappear { teardown() }
    }

    // MARK: Views

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                optionsMenu
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .padding()
    }

    private var optionsMenu: some View {
        Menu {
            if session.endpoint?.pinnedCertificateSHA256 == nil {
                Button("用 VLC 打开原画") { openExternal("vlc-x-callback://x-callback-url/stream?url=") }
                Button("用 Infuse 打开原画") { openExternal("infuse://x-callback-url/play?url=") }
            }
            Section(subtitles.isEmpty ? "字幕（无）" : "字幕") {
                Picker("字幕", selection: Binding(get: { subtitleID }, set: { selectSubtitle($0) })) {
                    Text("关闭").tag(String?.none)
                    ForEach(subtitles) { sub in
                        Text(subtitleLabel(sub)).tag(Optional(sub.id))
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var captionOverlay: some View {
        VStack {
            Spacer()
            if let caption {
                Text(caption)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func resumeCard(_ position: Double) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.white)
            Text("上次看到 \(VideoTime.clock(position))").font(.headline).foregroundStyle(.white)
            HStack(spacing: 12) {
                Button("从头播放") { begin(at: 0) }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("继续播放") { begin(at: position) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func subtitleLabel(_ sub: VideoSubtitle) -> String {
        var text = sub.title
        if let lang = sub.language, lang != sub.title { text += "（\(lang)）" }
        if sub.embedded { text += " · 内嵌" }
        return text
    }

    // MARK: Flow

    private func prepare() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        guard let client = session.client else { return }
        quality = .original
        if !Self.nativeContainers.contains(file.fileExtension) {
            notice = "按原画播放。iOS 自带播放器和本页是同一套解码器，.\(file.fileExtension) 可能只有声音或无法播放。可用 VLC 或 Infuse 打开原画；自签证书时其他 App 仍要自行信任证书。"
        }
        Task { await loadSubtitles() }
        let saved = try? await client.watchPosition(fileID: file.id)
        if let saved, saved > 30, saved < (file.duration ?? .infinity) - 60 {
            resumeAt = saved
        } else {
            await start(at: 0)
        }
    }

    private func begin(at position: Double) {
        resumeAt = nil
        Task { await start(at: position) }
    }

    /// Opens (or reopens, after a quality change) the stream and plays from `position`.
    private func start(at position: Double, fallback: Bool = true) async {
        guard let client = session.client else { return }
        if player == nil { status = "正在准备…" }
        if let old = stream {
            stream = nil
            await client.closeVideoStream(old)
        }
        do {
            let s = try await client.videoStream(for: file, quality: quality)
            stream = s
            var options: [String: Any] = [:]
            if s.isHLS {
                options[AVURLAssetOverrideMIMETypeKey] = "application/vnd.apple.mpegurl"
            } else if let mime = Self.mimeTypes[file.fileExtension] {
                options[AVURLAssetOverrideMIMETypeKey] = mime
            }
            let asset = await playableAsset(client: client, stream: s, options: options)
            let item = AVPlayerItem(asset: asset)
            let p = player ?? AVPlayer()
            p.replaceCurrentItem(with: item)
            if player == nil {
                attachObserver(to: p)
                player = p
            }
            // Seeking only sticks once the item is ready; give it up to 15 s.
            for _ in 0..<150 {
                guard item.status == .unknown else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if item.status == .failed {
                throw item.error ?? DSMError.invalidResponse
            }
            if position > 0 {
                _ = await p.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            p.play()
            status = nil
        } catch {
            if quality != .original && fallback {
                quality = .original
                notice = "转码失败（\(error.userMessage)），已切回原画"
                await start(at: position, fallback: false)
                return
            }
            player?.pause()
            player = nil
            status = "无法播放：\(error.userMessage)"
        }
    }

    /// Original files on a pinned certificate cannot be opened by AVPlayer's own loader.
    private func playableAsset(client: DSMClient, stream: VideoStream, options: [String: Any]) async -> AVURLAsset {
        guard !stream.isHLS, session.endpoint?.pinnedCertificateSHA256 != nil else {
            return AVURLAsset(url: stream.url, options: options)
        }
        var probe = URLRequest(url: stream.url)
        probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        if let (file, response) = try? await client.download(probe) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if response.statusCode != 206 && bytes > 64 {
                let named = file.deletingLastPathComponent().appendingPathComponent("original.\(self.file.fileExtension)")
                if (try? FileManager.default.moveItem(at: file, to: named)) != nil { return AVURLAsset(url: named) }
                return AVURLAsset(url: file)
            }
            try? FileManager.default.removeItem(at: file)
            let mime = Self.mimeTypes[fileExtension(stream.url)] ?? "video/mp4"
            let loader = PinnedMediaLoader(client: client, source: stream.url, mime: mime)
            mediaLoader = loader
            let asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            return asset
        }
        return AVURLAsset(url: stream.url, options: options)
    }

    private func fileExtension(_ url: URL) -> String {
        url.pathExtension.isEmpty ? file.fileExtension : url.pathExtension.lowercased()
    }

    private func openExternal(_ prefix: String) {
        guard let client = session.client else { return }
        Task {
            guard let url = try? await client.downloadURL(for: file.path),
                  let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let target = URL(string: prefix + encoded) else { return }
            openURL(target) { accepted in
                externalError = accepted ? nil : "没有安装该播放器"
                if externalError != nil { notice = externalError }
            }
        }
    }

    // MARK: Subtitles

    private func loadSubtitles() async {
        guard let client = session.client else { return }
        var list = (try? await client.subtitles(fileID: file.id)) ?? []
        if let sidecars = try? await client.sidecarSubtitles(near: file.path) {
            let known = Set(list.map(\.id))
            list += sidecars.filter { !known.contains($0.id) }
        }
        guard !list.isEmpty else { return }
        subtitles = list
        // Pick a Chinese track by default, preferring an external file (faster than extracting).
        let chinese = list.filter { sub in
            let text = ((sub.language ?? "") + " " + sub.title + " " + sub.id).lowercased()
            return ["chi", "chs", "cht", "zh", "中文", "简", "繁"].contains { text.contains($0) }
        }
        if let pick = chinese.first(where: { !$0.embedded }) ?? chinese.first {
            selectSubtitle(pick.id)
        }
    }

    private func selectSubtitle(_ id: String?) {
        subtitleID = id
        track = nil
        caption = nil
        guard let id, let sub = subtitles.first(where: { $0.id == id }), let client = session.client else { return }
        Task {
            do {
                let loaded = try await client.subtitleTrack(fileID: file.id, subtitle: sub)
                guard subtitleID == id else { return }
                track = loaded
                if loaded.cues.isEmpty { notice = "该字幕为空，或是图形字幕（PGS/VobSub），暂不支持" }
            } catch {
                guard subtitleID == id else { return }
                notice = "字幕加载失败：\(error.userMessage)"
            }
        }
    }

    // MARK: Progress

    private func attachObserver(to p: AVPlayer) {
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated { tick(time.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        caption = track?.cue(at: seconds)?.text
        // Saved every 15 s, so a crash or a killed app loses little.
        if seconds > 5, abs(seconds - lastSaved) >= 15 {
            lastSaved = seconds
            let id = file.id
            Task { try? await session.client?.saveWatchPosition(fileID: id, position: seconds) }
        }
    }

    private func teardown() {
        let position = player?.currentTime().seconds ?? 0
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        let client = session.client
        let s = stream
        let id = file.id
        Task {
            if position.isFinite, position > 5 { try? await client?.saveWatchPosition(fileID: id, position: position) }
            if let s { await client?.closeVideoStream(s) }
        }
    }
}

/// Feeds an original file to AVPlayer through the pinned URLSession, so a trusted self-signed certificate works.
final class PinnedMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let client: DSMClient
    let source: URL
    let queue = DispatchQueue(label: "nashelper.media")
    private let mime: String
    private var length: Int64?

    var assetURL: URL {
        var parts = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        parts.scheme = "nasmedia"
        return parts.url ?? source
    }

    init(client: DSMClient, source: URL, mime: String) {
        self.client = client
        self.source = source
        self.mime = mime
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        Task {
            do {
                try await respond(to: loadingRequest)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    private func respond(to loadingRequest: AVAssetResourceLoadingRequest) async throws {
        if length == nil {
            var probe = URLRequest(url: source)
            probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            let (data, response) = try await client.fetchResponse(probe)
            length = Self.totalLength(response) ?? Int64(data.count)
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = mime
            info.contentLength = length ?? 0
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else { return }
        let start = dataRequest.requestedOffset
        var end = start + Int64(dataRequest.requestedLength) - 1
        if let length, end >= length { end = max(start, length - 1) }
        var request = URLRequest(url: source)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await client.fetchResponse(request)
        if response.statusCode == 206 || response.value(forHTTPHeaderField: "Content-Range") != nil {
            dataRequest.respond(with: data)
        } else if Int64(data.count) > end {
            let from = Int(start)
            let to = min(data.count, Int(end) + 1)
            dataRequest.respond(with: from < to ? data.subdata(in: from..<to) : data)
        } else {
            dataRequest.respond(with: data)
        }
    }

    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total), value > 0 {
            return value
        }
        return nil
    }
}
