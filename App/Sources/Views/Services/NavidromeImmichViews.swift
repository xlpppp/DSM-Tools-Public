import SwiftUI
import MediaKit

// MARK: Navidrome

struct NavidromeView: View {
    enum Tab: String, CaseIterable { case newest = "最新", alphabetical = "全部专辑", playlists = "播放列表" }

    let client: SubsonicClient
    let account: ServiceAccount
    @State private var tab: Tab = .newest
    @State private var albums: [SubsonicAlbum] = []
    @State private var playlists: [SubsonicPlaylist] = []
    @State private var search = ""
    @State private var found: (albums: [SubsonicAlbum], songs: [SubsonicSong])?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if found == nil {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
                if let found {
                    if !found.songs.isEmpty {
                        VStack(spacing: 0) { SubsonicSongRows(client: client, songs: found.songs) }
                            .card(padding: 8)
                    }
                    albumGrid(found.albums)
                } else if tab == .playlists {
                    VStack(spacing: 0) {
                        ForEach(playlists) { p in
                            NavigationLink { SubsonicSongsView(client: client, title: p.name) { try await client.songs(inPlaylist: p.id) } } label: {
                                HStack {
                                    Label(p.name, systemImage: "music.note.list")
                                    Spacer()
                                    if let n = p.songCount { Text("\(n) 首").font(.caption).foregroundStyle(Theme.secondaryText) }
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .card(padding: 12)
                } else {
                    albumGrid(albums)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .searchable(text: $search, prompt: "歌曲、专辑")
        .onSubmit(of: .search) { Task { found = try? await client.search(search) } }
        .onChange(of: search) { if search.isEmpty { found = nil } }
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .task(id: tab) { await load() }
    }

    private func albumGrid(_ list: [SubsonicAlbum]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
            ForEach(list) { album in
                NavigationLink {
                    SubsonicSongsView(client: client, title: album.name, coverArt: album.coverArt) { try await client.songs(inAlbum: album.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        cover(album.coverArt)
                        Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(album.artist ?? "").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cover(_ art: String?) -> some View {
        RemoteImage(url: art.map { client.coverURL($0, size: 400) }, fetcher: { try await client.fetch($0) }) {
            ZStack {
                ServiceKind.navidrome.color.opacity(0.25)
                Image(systemName: "music.note").font(.largeTitle).foregroundStyle(ServiceKind.navidrome.color)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() async {
        do {
            switch tab {
            case .newest: albums = try await client.albums("newest")
            case .alphabetical: albums = try await client.albums("alphabeticalByName", size: 500)
            case .playlists: playlists = try await client.playlists()
            }
            error = nil
        } catch {
            self.error = error.serviceMessage
        }
    }
}

private struct SubsonicSongsView: View {
    let client: SubsonicClient
    let title: String
    var coverArt: String? = nil
    let load: () async throws -> [SubsonicSong]
    @Environment(MusicPlayer.self) private var player
    @State private var songs: [SubsonicSong] = []

    var body: some View {
        List {
            Section {
                Button {
                    player.play(songs.map { $0.track(client) })
                } label: {
                    Label("播放全部", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(songs.isEmpty)
                .listRowBackground(Color.clear)
            }
            Section { SubsonicSongRows(client: client, songs: songs) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .task { songs = (try? await load()) ?? [] }
    }
}

private struct SubsonicSongRows: View {
    let client: SubsonicClient
    let songs: [SubsonicSong]
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            Button {
                player.play(songs.map { $0.track(client) }, startAt: index)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.subheadline)
                            .foregroundStyle(player.current?.id == song.id ? Theme.accent : .primary).lineLimit(1)
                        Text([song.artist, song.album].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if let d = song.duration {
                        Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }
}

extension SubsonicSong {
    func track(_ client: SubsonicClient) -> MusicPlayer.Track {
        let song = self
        return MusicPlayer.Track(
            id: song.id, title: song.title, artist: song.artist, album: song.album,
            duration: song.duration.map(Double.init),
            resolve: { client.streamURL(for: song) },
            artwork: {
                guard let art = song.coverArt, let data = try? await client.fetch(client.coverURL(art)) else { return nil }
                return UIImage(data: data)
            }
        )
    }
}

// MARK: Immich

struct ImmichView: View {
    enum Tab: String, CaseIterable { case timeline = "照片", albums = "相册" }

    let client: ImmichClient
    @State private var tab: Tab = .timeline
    @State private var assets: [ImmichAsset] = []
    @State private var albums: [ImmichAlbum] = []
    @State private var page = 1
    @State private var exhausted = false
    @State private var viewing: ImmichViewerState?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
                if tab == .timeline {
                    ImmichGrid(client: client, assets: assets) { viewing = ImmichViewerState(assets: assets, start: $0) } onReachEnd: {
                        Task { await loadMore() }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink { ImmichAlbumView(client: client, album: album) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    RemoteImage(url: album.albumThumbnailAssetId.map { client.thumbnailURL($0) },
                                                fetcher: { try await client.fetch($0) })
                                        .frame(height: 150)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    Text(album.albumName).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(album.assetCount) 项").font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
        .background(Theme.background)
        .task {
            do {
                assets = try await client.timeline(page: 1)
                exhausted = assets.count < 200
                albums = (try? await client.albums()) ?? []
            } catch {
                self.error = error.serviceMessage
            }
        }
        .fullScreenCover(item: $viewing) { ImmichViewer(client: client, assets: $0.assets, start: $0.start) }
    }

    private func loadMore() async {
        guard !exhausted else { return }
        exhausted = true
        if let more = try? await client.timeline(page: page + 1) {
            page += 1
            assets += more
            exhausted = more.count < 200
        }
    }
}

struct ImmichViewerState: Identifiable {
    let id = UUID()
    let assets: [ImmichAsset]
    let start: Int
}

private struct ImmichAlbumView: View {
    let client: ImmichClient
    let album: ImmichAlbum
    @State private var assets: [ImmichAsset] = []
    @State private var viewing: ImmichViewerState?

    var body: some View {
        ScrollView {
            ImmichGrid(client: client, assets: assets) { viewing = ImmichViewerState(assets: assets, start: $0) } onReachEnd: {}
        }
        .navigationTitle(album.albumName)
        .navigationBarTitleDisplayMode(.inline)
        .task { assets = (try? await client.assets(inAlbum: album.id)) ?? [] }
        .fullScreenCover(item: $viewing) { ImmichViewer(client: client, assets: $0.assets, start: $0.start) }
    }
}

private struct ImmichGrid: View {
    let client: ImmichClient
    let assets: [ImmichAsset]
    let onOpen: (Int) -> Void
    let onReachEnd: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                Button { onOpen(index) } label: {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { RemoteImage(url: client.thumbnailURL(asset.id), fetcher: { try await client.fetch($0) }) }
                        .clipped()
                        .overlay(alignment: .bottomTrailing) {
                            if asset.isVideo {
                                Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).padding(5).shadow(radius: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .onAppear { if index == assets.count - 1 { onReachEnd() } }
            }
        }
    }
}

private struct ImmichViewer: View {
    let client: ImmichClient
    let assets: [ImmichAsset]
    let start: Int
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var video: PlayURL?

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { i, asset in
                    ZStack {
                        RemoteImage(url: client.thumbnailURL(asset.id, preview: true), contentMode: .fit,
                                    fetcher: { try await client.fetch($0) }) { ProgressView().tint(.white) }
                        if asset.isVideo {
                            Button { video = PlayURL(url: client.videoURL(asset.id)) } label: {
                                Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(assets.indices.contains(index) ? assets[index].originalFileName : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .fullScreenCover(item: $video) { StreamPlayerView(url: $0.url, headers: client.headers) }
        }
        .onAppear { index = start }
    }
}
