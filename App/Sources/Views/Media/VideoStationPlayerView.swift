import SwiftUI
import AVKit
import UniformTypeIdentifiers
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
                let local = (try? FileManager.default.moveItem(at: file, to: named)) != nil ? named : file
                await PinnedMediaLoader.rewriteHev1(in: local)
                return AVURLAsset(url: local)
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

/// Feeds media to AVPlayer through an app URLSession.
/// A pinned certificate, nginx basic auth, and Emby/Jellyfin tokens cannot be handed to AVPlayer itself.
/// `contentType` must be a UTI: a MIME type such as `video/mp4` makes iOS play the audio and drop the picture.
final class PinnedMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let source: URL
    let queue = DispatchQueue(label: "nashelper.media")
    private let mime: String
    /// Writes the response to a file. A movie must not be accumulated in memory.
    private let pull: @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    private var length: Int64?
    private var fullFile: URL?
    private var patched = false
    private var didLocate = false
    private var hev1: [Int] = []

    var assetURL: URL {
        var parts = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        parts.scheme = "nasmedia"
        return parts.url ?? source
    }

    init(client: DSMClient, source: URL, mime: String) {
        self.source = source
        self.mime = mime
        self.pull = { try await client.download($0) }
    }

    init(pull: @escaping @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse), source: URL, mime: String) {
        self.source = source
        self.mime = mime
        self.pull = pull
    }

    /// When the server ignores Range, the probe already saved the whole file. Play that file.
    /// A real 206 stays on the resource loader so playback can start before the file ends.
    static func prepare(pull: @escaping @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse),
                        source: URL, mime: String) async throws -> (file: URL?, loader: PinnedMediaLoader?) {
        if source.path.lowercased().contains(".m3u8") || mime.contains("mpegurl") {
            return (nil, PinnedMediaLoader(pull: pull, source: source, mime: mime))
        }
        var probe = URLRequest(url: source)
        probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (file, response) = try await pull(probe)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        if response.statusCode == 206 || size <= 4096 {
            try? FileManager.default.removeItem(at: file)
            return (nil, PinnedMediaLoader(pull: pull, source: source, mime: mime))
        }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let named = folder.appendingPathComponent("media." + ext)
        let local = (try? FileManager.default.moveItem(at: file, to: named)) != nil ? named : file
        await rewriteHev1(in: local)
        return (local, nil)
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
        let remote = originalURL(from: loadingRequest.request.url) ?? source
        try await ensureLength(of: remote)
        let playlist = remote.path.lowercased().contains(".m3u8") || mime.contains("mpegurl")
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.uti(url: remote, mime: mime)
            info.contentLength = playlist ? 0 : (length ?? 0)
            info.isByteRangeAccessSupported = !playlist && length != nil
        }
        guard let dataRequest = loadingRequest.dataRequest else { return }
        if playlist {
            let (file, response) = try await pull(URLRequest(url: remote))
            defer { try? FileManager.default.removeItem(at: file) }
            guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
            let data = try Data(contentsOf: file)
            let text = String(data: data, encoding: .utf8) ?? ""
            let rewritten = text.hasPrefix("#EXTM3U") ? rewriteMediaPlaylist(text, upstream: remote, scheme: "nasmedia") : text
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(rewritten.utf8.count)
                info.isByteRangeAccessSupported = false
            }
            dataRequest.respond(with: Data(rewritten.utf8))
            return
        }
        let start = dataRequest.currentOffset
        let asked = dataRequest.requestedLength
        var end = start
        if asked > 0, asked < 32_000_000 {
            end = dataRequest.requestedOffset + Int64(asked) - 1
        } else if let length {
            end = length - 1
        } else {
            end = start + 1_048_575
        }
        if let length, end >= length { end = max(start, length - 1) }
        guard end >= start else { return }
        if fullFile == nil, Self.uti(url: remote, mime: mime) == "public.mpeg-4", !didLocate {
            didLocate = true
            hev1 = (try? await MP4Hev1.locate(length: length.map(Int.init)) { offset, count in
                try await self.bytes(of: remote, start: Int64(offset), end: Int64(offset + max(count, 1) - 1))
            }) ?? []
        }
        var cursor = start
        while cursor <= end {
            let pieceEnd = min(end, cursor + 1_048_575)
            var data = try await bytes(of: remote, start: cursor, end: pieceEnd)
            if Self.uti(url: remote, mime: mime) == "public.mpeg-4" {
                try await patchOriginalIfNeeded()
                if fullFile != nil { data = try read(fullFile!, cursor, pieceEnd) }
            }
            if fullFile == nil, !hev1.isEmpty { MP4Hev1.apply(&data, rangeStart: Int(cursor), offsets: hev1) }
            dataRequest.respond(with: data)
            cursor = pieceEnd + 1
        }
    }

    /// A 2-byte probe. When the server ignores Range it returns the whole file, which is kept on disk.
    private func ensureLength(of remote: URL) async throws {
        if length != nil || fullFile != nil { return }
        var probe = URLRequest(url: remote)
        probe.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let (file, response) = try await pull(probe)
        if let total = Self.totalLength(response), response.statusCode == 206 {
            length = total
            try? FileManager.default.removeItem(at: file)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        length = size
        if size > 4096 { fullFile = file } else { try? FileManager.default.removeItem(at: file) }
    }

    private func bytes(of remote: URL, start: Int64, end: Int64) async throws -> Data {
        if let fullFile { return try read(fullFile, start, end) }
        var request = URLRequest(url: remote)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (file, response) = try await pull(request)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let asked = end - start + 1
        if response.statusCode != 206, size > asked + 4096 {
            fullFile = file
            if length == nil || length == 0 { length = size }
            return try read(file, start, end)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    private func read(_ file: URL, _ start: Int64, _ end: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, start)))
        return handle.readData(ofLength: Int(max(0, end - start + 1)))
    }

    /// iOS plays HEVC when the sample entry says hvc1. The four bytes are rewritten in the saved file.
    private func patchOriginalIfNeeded() async throws {
        guard !patched, let fullFile, Self.uti(url: source, mime: mime) == "public.mpeg-4" else { return }
        patched = true
        await Self.rewriteHev1(in: fullFile)
    }

    /// iOS plays HEVC when the sample entry says hvc1. The four bytes are the same length, so the file stays valid.
    static func rewriteHev1(in file: URL) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 32 else { return }
        let offsets = (try? await MP4Hev1.locate(length: size) { start, count in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            return handle.readData(ofLength: count)
        }) ?? []
        guard !offsets.isEmpty, let handle = try? FileHandle(forUpdating: file) else { return }
        defer { try? handle.close() }
        for offset in offsets {
            try? handle.seek(toOffset: UInt64(offset))
            try? handle.write(Data("hvc1".utf8))
        }
    }

    private func originalURL(from custom: URL?) -> URL? {
        guard let custom, var parts = URLComponents(url: custom, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = source.scheme
        return parts.url
    }

    /// AVAssetResourceLoadingContentInformationRequest.contentType is a UTI, not a MIME type.
    static func uti(url: URL, mime: String) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || mime.contains("mpegurl") { return "public.m3u-playlist" }
        if ext == "ts" { return "public.mpeg-2-transport-stream" }
        if let type = UTType(filenameExtension: ext), !ext.isEmpty { return type.identifier }
        if let type = UTType(mimeType: mime) { return type.identifier }
        switch mime {
        case "video/mp4", "video/x-m4v", "audio/mp4": return "public.mpeg-4"
        case "video/quicktime": return "com.apple.quicktime-movie"
        case "audio/mpeg": return "public.mp3"
        default: return "public.mpeg-4"
        }
    }

    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total), value > 0 {
            return value
        }
        let given = response.expectedContentLength
        return given > 0 ? given : nil
    }
}
