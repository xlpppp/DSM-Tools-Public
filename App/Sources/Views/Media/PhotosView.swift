import SwiftUI
import AVKit
import Photos
import DSMKit

struct PhotosView: View {
    enum Tab: String, CaseIterable { case timeline = "照片", albums = "相册", folders = "文件夹", explore = "发现" }

    @Environment(SessionManager.self) private var session
    @State private var tab: Tab = .timeline
    @State private var space: PhotoSpace = .personal
    @State private var items: [PhotoItem] = []
    @State private var albums: [PhotoAlbum] = []
    @State private var loaded = false
    @State private var unavailable = false
    @State private var exhausted = false
    @State private var viewer: ViewerState?
    @State private var error: String?

    struct ViewerState: Identifiable {
        let id = UUID()
        let items: [PhotoItem]
        let start: Int
        let space: PhotoSpace
    }

    var body: some View {
        VStack(spacing: 0) {
            if unavailable {
                ContentUnavailableView("未安装 Synology Photos", systemImage: "photo.on.rectangle",
                                       description: Text("请先在套件中心安装 Synology Photos。"))
                    .padding(.top, 60)
                Spacer()
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                switch tab {
                case .timeline:
                    ScrollView {
                        if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
                        PhotoDayGrid(items: items, space: space) { index in
                            viewer = ViewerState(items: items, start: index, space: space)
                        } onReachEnd: {
                            Task { await loadMore() }
                        }
                    }
                    .refreshable { await reload() }
                case .albums:
                    ScrollView { albumGrid.padding(.top, 4) }
                        .refreshable { await reload() }
                case .folders:
                    PhotoFolderView(space: space, folder: nil, embedded: true)
                        .id(space)
                case .explore:
                    ScrollView { PhotoExploreView(space: space) }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .background(Theme.background)
        .navigationTitle("相册")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !unavailable {
                    PhotoUploadButton(space: space) { await reload() }
                }
                Picker("空间", selection: $space) {
                    ForEach(PhotoSpace.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(tab == .albums)
            }
        }
        .task(id: space) { await reload() }
        .onChange(of: tab) { if tab == .albums { space = .personal } }
        .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
    }

    private var albumGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumPhotosView(album: album)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AlbumCover(album: album)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                        Text("\(album.itemCount) 项").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func reload() async {
        guard let client = session.client else { return }
        guard await client.hasPhotos(space) else {
            unavailable = true
            loaded = true
            return
        }
        exhausted = false
        do {
            items = try await client.photos(space: space, offset: 0, limit: 200)
            exhausted = items.count < 200
            if space == .personal { albums = (try? await client.photoAlbums()) ?? [] }
            error = nil
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }

    private func loadMore() async {
        guard let client = session.client, !exhausted else { return }
        exhausted = true
        if let more = try? await client.photos(space: space, offset: items.count, limit: 200) {
            items += more
            exhausted = more.count < 200
        }
    }
}

private struct AlbumCover: View {
    let album: PhotoAlbum
    @Environment(SessionManager.self) private var session
    @State private var url: URL?

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                Theme.subtle
                Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.secondaryText)
            }
        }
        .task(id: album.id) {
            guard let client = session.client, let id = album.coverID, let key = album.coverCacheKey else { return }
            url = try? await client.photoThumbnailURL(space: .personal, id: id, cacheKey: key, size: .medium)
        }
    }
}

private struct AlbumPhotosView: View {
    let album: PhotoAlbum
    @Environment(SessionManager.self) private var session
    @State private var items: [PhotoItem] = []
    @State private var viewer: PhotosView.ViewerState?

    var body: some View {
        ScrollView {
            PhotoGrid(items: items, space: .personal) { index in
                viewer = PhotosView.ViewerState(items: items, start: index, space: .personal)
            } onReachEnd: {}
        }
        .background(Theme.background)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let client = session.client else { return }
            items = (try? await client.photos(albumID: album.id, limit: 5000)) ?? []
        }
        .fullScreenCover(item: $viewer) { PhotoViewer(items: $0.items, start: $0.start, space: $0.space) }
    }
}

/// Square thumbnails grouped in a tight grid like the Photos app.
struct PhotoGrid: View {
    let items: [PhotoItem]
    let space: PhotoSpace
    let onOpen: (Int) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onOpen(index) } label: {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { PhotoThumb(item: item, space: space, size: .small) }
                        .clipped()
                        .overlay(alignment: .bottomTrailing) {
                            if item.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .shadow(radius: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .onAppear { if index == items.count - 1 { onReachEnd() } }
            }
        }
    }
}

/// Resolves the thumbnail URL (an actor call) and shows it.
struct PhotoThumb: View {
    let item: PhotoItem
    let space: PhotoSpace
    let size: ThumbnailSize
    var contentMode: ContentMode = .fill

    @Environment(SessionManager.self) private var session
    @State private var url: URL?

    var body: some View {
        RemoteImage(url: url, contentMode: contentMode)
            .task(id: item.id) {
                guard let client = session.client, let key = item.cacheKey else { return }
                url = try? await client.photoThumbnailURL(space: space, id: item.id, cacheKey: key, size: size)
            }
    }
}

/// Full-screen pager with zoom, video playback, save to the phone and share.
struct PhotoViewer: View {
    let items: [PhotoItem]
    let start: Int
    let space: PhotoSpace

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session
    @State private var index = 0
    @State private var busy: String?
    @State private var export: ExportItem?
    @State private var message: String?
    /// Personal space only: ids in the "收藏" album, nil until loaded.
    @State private var favorites: Set<Int>?

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    Group {
                        if item.isVideo {
                            PhotoVideoPage(item: item, space: space, active: i == index)
                        } else {
                            PhotoThumb(item: item, space: space, size: .large, contentMode: .fit)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .task { await loadFavorites() }
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let text = busy ?? message {
                    Text(text)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 30)
                }
            }
            .navigationTitle(items.indices.contains(index) ? items[index].filename : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { saveToLibrary() } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(busy != nil)
                    Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(busy != nil)
                    if space == .personal, let favorites, items.indices.contains(index) {
                        let on = favorites.contains(items[index].id)
                        Button { toggleFavorite() } label: { Image(systemName: on ? "heart.fill" : "heart") }
                            .disabled(busy != nil)
                    }
                    Menu {
                        Button { makeShareLink() } label: { Label("生成分享链接", systemImage: "link") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(busy != nil)
                }
            }
            .sheet(item: $export) { ActivityView(items: $0.items) }
        }
        .onAppear { index = start; recordView() }
        .onChange(of: index) { recordView() }
    }

    private func recordView() {
        guard items.indices.contains(index) else { return }
        RecentStore.shared.record(items[index], space: space, device: session.deviceID)
    }

    private func downloadOriginal() async throws -> URL {
        guard let client = session.client else { throw DSMError.notAuthenticated }
        let item = items[index]
        let url = try await client.photoOriginalURL(space: space, id: item.id)
        return try await client.download(url, as: item.filename)
    }

    private func loadFavorites() async {
        guard space == .personal, let client = session.client else { return }
        favorites = (try? await client.favoritePhotoIDs()) ?? []
    }

    /// Adds to or removes from the "收藏" album, creating the album the first time.
    private func toggleFavorite() {
        guard let client = session.client, let current = favorites, items.indices.contains(index) else { return }
        let id = items[index].id
        let adding = !current.contains(id)
        Task {
            do {
                guard let album = try await client.favoritesAlbum(create: adding) else { return }
                if adding {
                    try await client.addPhotos([id], toAlbum: album.id)
                    favorites?.insert(id)
                    message = "已加入收藏"
                } else {
                    try await client.removePhotos([id], fromAlbum: album.id)
                    favorites?.remove(id)
                    message = "已取消收藏"
                }
            } catch {
                message = error.userMessage
            }
        }
    }

    /// File Station share link of the original; the link is copied and offered to the share sheet.
    private func makeShareLink() {
        guard let client = session.client, items.indices.contains(index) else { return }
        let item = items[index]
        busy = "正在生成分享链接…"
        Task {
            do {
                guard let path = try await client.photoFileStationPath(of: item, space: space) else {
                    throw DSMError.transport("找不到照片所在文件夹")
                }
                let link = try await client.createShareLink(for: path)
                UIPasteboard.general.string = link.url
                message = "分享链接已复制"
                if let url = URL(string: link.url) { export = ExportItem(items: [url]) }
            } catch {
                message = error.userMessage
            }
            busy = nil
        }
    }

    private func share() {
        busy = "正在下载原图…"
        Task {
            do { export = ExportItem(items: [try await downloadOriginal()]) } catch { message = error.userMessage }
            busy = nil
        }
    }

    private func saveToLibrary() {
        busy = "正在保存到相册…"
        Task {
            do {
                let file = try await downloadOriginal()
                let isVideo = items[index].isVideo
                guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                    message = "没有相册写入权限，请在 设置 › 隐私 › 照片 中允许"
                    busy = nil
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
                }
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                message = "已保存到相册"
            } catch {
                message = error.userMessage
            }
            busy = nil
        }
    }
}

private struct PhotoVideoPage: View {
    let item: PhotoItem
    let space: PhotoSpace
    let active: Bool
    @Environment(SessionManager.self) private var session
    @State private var player: AVPlayer?
    @State private var local: URL?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                PhotoThumb(item: item, space: space, size: .large, contentMode: .fit)
                ProgressView().tint(.white)
            }
        }
        .task(id: active) {
            guard active else {
                player?.pause()
                return
            }
            guard player == nil, let client = session.client,
                  let url = try? await client.photoOriginalURL(space: space, id: item.id) else { return }
            if session.endpoint?.pinnedCertificateSHA256 != nil {
                guard let file = try? await client.download(url, as: item.filename) else { return }
                local = file
                player = AVPlayer(url: file)
            } else {
                player = AVPlayer(url: url)
            }
            player?.play()
        }
        .onDisappear {
            player?.pause()
            if let local { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        }
    }
}
