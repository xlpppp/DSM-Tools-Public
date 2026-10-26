import SwiftUI
import AVKit
import CoreMedia
import DSMKit

/// Opens a NAS file in place: text and logs, images, audio and video; anything else shows its details.
struct FilePreviewView: View {
    let file: RemoteFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch file.kind {
                case .text: TextFileView(file: file)
                case .image: ImageFileView(file: file)
                case .audio, .video: MediaFileView(file: file)
                default: FileDetailView(file: file)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

// MARK: Text and logs

private struct TextFileView: View {
    let file: RemoteFile
    /// Larger files are slow to render on a phone; offer a download instead.
    static let limit: Int64 = 8 * 1024 * 1024

    @Environment(SessionManager.self) private var session
    @State private var text: String?
    @State private var error: String?
    @State private var proxy = TextViewProxy()
    @State private var wrap = true

    var body: some View {
        Group {
            if let text {
                ReadOnlyTextView(text: text, wrap: wrap, proxy: proxy)
            } else if let error {
                ContentUnavailableView("无法打开", systemImage: "doc.questionmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { proxy.find() } label: { Image(systemName: "magnifyingglass") }
                Menu {
                    Toggle("自动换行", isOn: $wrap)
                    Button { proxy.scrollToTop() } label: { Label("回到开头", systemImage: "arrow.up.to.line") }
                    Button { proxy.scrollToBottom() } label: { Label("跳到末尾", systemImage: "arrow.down.to.line") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let size = file.size, size > Self.limit {
            error = "文件有 \(Format.bytes(size))，超过在线查看上限 \(Format.bytes(Self.limit))。请下载到手机后查看。"
            return
        }
        guard let client = session.client else { return }
        do {
            let data = try await client.fileData(at: file.path)
            text = Self.decode(data)
        } catch {
            self.error = error.userMessage
        }
    }

    /// UTF-8 first, then GB18030 (common for Chinese Windows text files), then Latin-1 so something always shows.
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Lets SwiftUI toolbar buttons drive the underlying UITextView.
@MainActor
final class TextViewProxy {
    weak var textView: UITextView?

    func find() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func scrollToTop() {
        textView?.setContentOffset(.zero, animated: true)
    }

    func scrollToBottom() {
        guard let view = textView, !view.text.isEmpty else { return }
        view.scrollRangeToVisible(NSRange(location: (view.text as NSString).length - 1, length: 1))
    }
}

/// UITextView handles multi-megabyte logs far better than SwiftUI Text, and brings system find.
private struct ReadOnlyTextView: UIViewRepresentable {
    let text: String
    let wrap: Bool
    let proxy: TextViewProxy

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        view.alwaysBounceVertical = true
        view.text = text
        proxy.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        // Without wrapping, let lines run as wide as they need and scroll sideways.
        view.textContainer.widthTracksTextView = wrap
        view.textContainer.size.width = wrap ? view.bounds.width : 100_000
        view.textContainer.lineBreakMode = wrap ? .byWordWrapping : .byClipping
        view.layoutManager.ensureLayout(for: view.textContainer)
    }
}

// MARK: Images

private struct ImageFileView: View {
    let file: RemoteFile
    @Environment(SessionManager.self) private var session
    @State private var image: UIImage?
    @State private var error: String?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                    }
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = min(max(baseScale * $0.magnification, 1), 6) }
                            .onEnded { _ in baseScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            scale = scale > 1 ? 1 : 2.5
                            baseScale = scale
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("无法打开", systemImage: "photo", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            guard let client = session.client else { return }
            do {
                let data = try await client.fileData(at: file.path)
                if let decoded = UIImage(data: data) { image = decoded } else { error = "不支持的图片格式" }
            } catch {
                self.error = error.userMessage
            }
        }
    }
}

// MARK: Audio and video

private struct MediaFileView: View {
    let file: RemoteFile
    @Environment(SessionManager.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var player: AVPlayer?
    @State private var localCopy: URL?
    @State private var status: String?
    /// Set when the file has a picture the system player cannot show (it then plays only the sound).
    @State private var videoIssue: String?
    @State private var externalError: String?

    /// Containers and codecs AVPlayer plays natively. Others (mkv, avi, rmvb, ape…) need the media phase's player.
    /// MPEG-TS is left out: AVPlayer only plays it inside HLS, a bare .ts file gives sound at best.
    static let playable: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aiff", "flac", "alac", "caf"]

    static let mimeTypes: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav",
        "aiff": "audio/aiff", "flac": "audio/flac", "alac": "audio/mp4", "caf": "audio/x-caf",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !Self.playable.contains(file.fileExtension) {
                ContentUnavailableView {
                    Label("暂不支持在线播放", systemImage: "play.slash")
                } description: {
                    Text("系统播放器不支持 .\(file.fileExtension) 格式。可以交给 VLC 或 Infuse 播放，或下载后用其他 App 打开。")
                } actions: {
                    externalPlayers
                }
            } else if let player {
                VideoPlayer(player: player) {
                    if file.kind == .audio { audioArtwork }
                }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if let videoIssue { issueBanner(videoIssue) }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    if let status { Text(status).font(.footnote).foregroundStyle(Theme.secondaryText) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await prepare() }
        .onDisappear {
            player?.pause()
            if let localCopy { try? FileManager.default.removeItem(at: localCopy.deletingLastPathComponent()) }
        }
    }

    private func issueBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.white)
            externalPlayers.tint(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(12)
    }

    /// Hands the stream to a player app that decodes more formats. Not offered for a pinned
    /// self-signed certificate: other apps would not trust it.
    @ViewBuilder
    private var externalPlayers: some View {
        if session.endpoint?.pinnedCertificateSHA256 == nil {
            HStack(spacing: 10) {
                Button("用 VLC 打开") { openExternal("vlc-x-callback://x-callback-url/stream?url=") }
                Button("用 Infuse 打开") { openExternal("infuse://x-callback-url/play?url=") }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            if let externalError { Text(externalError).font(.caption).foregroundStyle(Theme.warning) }
        }
    }

    private func openExternal(_ prefix: String) {
        guard let client = session.client else { return }
        Task {
            guard let url = try? await client.downloadURL(for: file.path),
                  let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let target = URL(string: prefix + encoded) else { return }
            openURL(target) { accepted in
                externalError = accepted ? nil : "没有安装该播放器"
            }
        }
    }

    private var audioArtwork: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 160, height: 160)
                .background(Color(hex: 0x22C55E).gradient, in: RoundedRectangle(cornerRadius: 28))
            Text(file.name)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepare() async {
        guard Self.playable.contains(file.fileExtension), let client = session.client else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: file.kind == .video ? .moviePlayback : .default)
        do {
            let url: URL
            if session.endpoint?.pinnedCertificateSHA256 != nil {
                // The system player cannot use a certificate trusted only inside this app, so fetch the file first.
                status = "该设备使用自签证书，正在下载后播放…"
                url = try await client.downloadFile(at: file.path)
                localCopy = url
            } else {
                url = try await client.downloadURL(for: file.path)
            }
            // The streaming URL ends in entry.cgi, so tell AVFoundation the type instead of letting it guess.
            var options: [String: Any] = [:]
            if let mime = Self.mimeTypes[file.fileExtension] { options[AVURLAssetOverrideMIMETypeKey] = mime }
            let asset = AVURLAsset(url: url, options: options)
            if file.kind == .video { videoIssue = await Self.videoIssue(in: asset) }
            let item = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = item
            item.play()
        } catch {
            status = error.userMessage
        }
    }

    /// Why the picture would not show, if it would not. AVPlayer plays the audio track of a file whose
    /// video it cannot decode and shows only a speaker icon, which is what users see as "sound, no picture".
    static func videoIssue(in asset: AVURLAsset) async -> String? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return nil }
        guard let track = tracks.first else { return "文件里没有可识别的视频画面，只能播放声音。" }
        guard let loaded = try? await track.load(.isPlayable, .isDecodable, .formatDescriptions) else { return nil }
        let (playable, decodable, formats) = loaded
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "未知"
        if codec == "hev1" || codec == "dvhe" {
            return "该视频为 HEVC（\(codec) 标记），iOS 系统播放器只能放出声音，无法显示画面。"
        }
        if !playable || !decodable {
            return "视频编码 \(codec) 不受系统播放器支持，只能播放声音。"
        }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? String(code) : text
    }
}

// MARK: Other files

private struct FileDetailView: View {
    let file: RemoteFile
    @Environment(SessionManager.self) private var session
    @State private var export: ExportItem?
    @State private var downloading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    FileIcon(kind: file.kind)
                    Text(file.name).font(.headline)
                }
                .padding(.vertical, 6)
            }
            Section {
                InfoRow(label: "大小", value: file.size.map { Format.bytes($0) } ?? "—")
                InfoRow(label: "修改时间", value: file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                InfoRow(label: "位置", value: (file.path as NSString).deletingLastPathComponent)
            }
            Section {
                Button {
                    download()
                } label: {
                    HStack {
                        Label("下载到手机", systemImage: "arrow.down.circle")
                        if downloading { Spacer(); ProgressView() }
                    }
                }
                .disabled(downloading)
            } footer: {
                if let error { Text(error).foregroundStyle(Theme.warning) }
            }
        }
        .sheet(item: $export) { ActivityView(items: $0.items) }
    }

    private func download() {
        guard let client = session.client else { return }
        downloading = true
        Task {
            do {
                export = ExportItem(items: [try await client.downloadFile(at: file.path)])
            } catch {
                self.error = error.userMessage
            }
            downloading = false
        }
    }
}
