import SwiftUI
import DSMKit

/// Audio Station: albums, songs, playlists and search, played by the shared MusicPlayer.
struct MusicView: View {
    @Environment(SessionManager.self) private var session
    @Environment(MusicPlayer.self) private var player
    @State private var albums: [MusicAlbum] = []
    @State private var songs: [Song] = []
    @State private var playlists: [MusicPlaylist] = []
    @State private var search = ""
    @State private var results: [Song]?
    @State private var loaded = false
    @State private var unavailable = false
    @State private var error: String?
    @State private var hotAlbums: [MusicAlbum] = []
    @State private var randomSongs: [Song] = []

    var body: some View {
        Group {
            if unavailable {
                ContentUnavailableView("未安装 Audio Station", systemImage: "music.note",
                                       description: Text("请先在套件中心安装 Audio Station。"))
            } else if let results {
                List { SongRows(songs: results) }
            } else {
                content
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .navigationTitle("音乐")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MusicLibraryView(albums: albums, songs: songs, playlists: playlists)
                } label: {
                    Image(systemName: "square.stack")
                }
                .accessibilityLabel("资料库")
            }
        }
        .searchable(text: $search, prompt: "歌曲、歌手、专辑")
        .onSubmit(of: .search) { Task { await runSearch() } }
        .onChange(of: search) { if search.isEmpty { results = nil } }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
                randomCard
                if !hotAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("热门专辑").font(.headline)
                        Text("最近添加").font(.caption).foregroundStyle(Theme.secondaryText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(hotAlbums) { album in
                                    NavigationLink { AlbumView(album: album) } label: { AlbumTile(album: album).frame(width: 140) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("随机歌曲").font(.headline)
                            Text("点击歌曲开始播放").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button { refreshRandom() } label: { Label("换一批", systemImage: "arrow.triangle.2.circlepath") }
                            .font(.subheadline)
                            .disabled(songs.isEmpty)
                    }
                    SongRows(songs: randomSongs)
                }
            }
            .padding(16)
        }
    }

    private var randomCard: some View {
        Button {
            guard let client = session.client, !songs.isEmpty else { return }
            player.play(songs.shuffled().map { $0.track(using: client) })
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("随心听", systemImage: "shuffle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("随机播放").font(.title2.bold()).foregroundStyle(.white)
                    Text("从音乐资料库中发现下一首喜欢的歌")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                    Text("播放")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.top, 6)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(hex: 0x7F1D1D), Color(hex: 0x111827)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(songs.isEmpty)
    }

    private func refreshRandom() {
        randomSongs = Array(songs.shuffled().prefix(8))
    }

    private func load() async {
        guard let client = session.client else { return }
        guard await client.hasAudioStation else {
            unavailable = true
            loaded = true
            return
        }
        configurePlayer(client)
        do {
            async let a = client.musicAlbums()
            async let s = client.songs(limit: 1000)
            albums = try await a
            songs = try await s
            playlists = (try? await client.musicPlaylists()) ?? []
            hotAlbums = (try? await client.musicAlbums(limit: 12, sort: "time")) ?? Array(albums.prefix(12))
            refreshRandom()
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }

    /// Self-signed (pinned) NAS: songs are downloaded through the app before playing.
    private func configurePlayer(_ client: DSMClient) {
        if session.endpoint?.pinnedCertificateSHA256 != nil, let host = session.endpoint?.host {
            player.pinnedHosts.insert(host)
            player.downloader = { url, name in try await client.download(url, as: name) }
        }
    }

    private func runSearch() async {
        guard let client = session.client, !search.isEmpty else { return }
        results = (try? await client.songs(keyword: search)) ?? []
    }
}

extension Song {
    /// A player track that resolves its stream URL through the current session when it starts.
    func track(using client: DSMClient) -> MusicPlayer.Track {
        let song = self
        return MusicPlayer.Track(
            id: song.id, title: song.title, artist: song.artist, album: song.album,
            duration: song.duration.map(Double.init),
            resolve: { try await client.streamURL(for: song) },
            artwork: {
                guard let url = try? await client.coverURL(for: song), let data = try? await client.fetch(url) else { return nil }
                return UIImage(data: data)
            }
        )
    }
}

private struct SongRows: View {
    let songs: [Song]
    @Environment(SessionManager.self) private var session
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            Button {
                guard let client = session.client else { return }
                player.play(songs.map { $0.track(using: client) }, startAt: index)
            } label: {
                HStack(spacing: 12) {
                    if let track = song.track {
                        Text("\(track)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline)
                            .foregroundStyle(player.current?.id == song.id ? Theme.accent : .primary)
                            .lineLimit(1)
                        Text([song.artist, song.album].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let d = song.duration {
                        Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MusicLibraryView: View {
    let albums: [MusicAlbum]
    let songs: [Song]
    let playlists: [MusicPlaylist]

    var body: some View {
        List {
            Section("我的音乐") {
                NavigationLink { SongListPage(title: "所有音乐", songs: songs) } label: { Label("所有音乐", systemImage: "music.note") }
                NavigationLink { MusicFolderPageView() } label: { Label("按文件夹分类", systemImage: "folder") }
                NavigationLink { AlbumGridPage(albums: albums) } label: { Label("按专辑分类", systemImage: "square.stack") }
                NavigationLink { MusicGroupPage(title: "演出者", api: "SYNO.AudioStation.Artist", listKey: "artists", kind: .artist) } label: {
                    Label("按演出者分类", systemImage: "person.wave.2")
                }
                NavigationLink { MusicGroupPage(title: "作曲者", api: "SYNO.AudioStation.Composer", listKey: "composers", kind: .composer) } label: {
                    Label("按作曲者分类", systemImage: "music.mic")
                }
                NavigationLink { MusicGroupPage(title: "类型", api: "SYNO.AudioStation.Genre", listKey: "genres", kind: .genre) } label: {
                    Label("按类型分类", systemImage: "square.grid.2x2")
                }
            }
            Section("播放列表") {
                if playlists.isEmpty {
                    Text("没有播放列表").foregroundStyle(Theme.secondaryText)
                }
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistView(playlist: playlist) } label: { Label(playlist.name, systemImage: "music.note.list") }
                }
            }
            Section("INTERNET 广播") {
                NavigationLink { MusicRadioPage() } label: { Label("网络广播", systemImage: "dot.radiowaves.left.and.right") }
            }
        }
        .navigationTitle("资料库")
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}

private struct SongListPage: View {
    let title: String
    let songs: [Song]
    var body: some View {
        List { SongRows(songs: songs) }
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}

private struct AlbumGridPage: View {
    let albums: [MusicAlbum]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink { AlbumView(album: album) } label: { AlbumTile(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("专辑")
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}

private struct MusicGroupPage: View {
    enum Kind { case artist, composer, genre }
    let title: String
    let api: String
    let listKey: String
    let kind: Kind
    @Environment(SessionManager.self) private var session
    @State private var names: [MusicName] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.warning) }
            ForEach(names) { group in
                NavigationLink {
                    MusicFilteredSongs(title: group.name, kind: kind, value: group.name)
                } label: {
                    Text(group.name)
                }
            }
        }
        .navigationTitle(title)
        .overlay { if names.isEmpty && error == nil { ProgressView() } }
        .task {
            do { names = try await session.client?.musicGroups(api: api, listKey: listKey) ?? [] }
            catch { self.error = error.userMessage }
        }
    }
}

private struct MusicFilteredSongs: View {
    let title: String
    let kind: MusicGroupPage.Kind
    let value: String
    @Environment(SessionManager.self) private var session
    @State private var songs: [Song] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.warning) }
            SongRows(songs: songs)
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .task {
            guard let client = session.client else { return }
            do {
                switch kind {
                case .artist: songs = try await client.songs(artist: value)
                case .composer: songs = try await client.songs(composer: value)
                case .genre: songs = try await client.songs(genre: value)
                }
            } catch { self.error = error.userMessage }
        }
    }
}

private struct MusicFolderPageView: View {
    var folderID = ""
    var title = "文件夹"
    @Environment(SessionManager.self) private var session
    @State private var page = MusicFolderPage(folders: [], songs: [])
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.warning) }
            ForEach(page.folders) { folder in
                NavigationLink { MusicFolderPageView(folderID: folder.token, title: folder.name) } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            SongRows(songs: page.songs)
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .task {
            do { page = try await session.client?.musicFolderPage(id: folderID) ?? page }
            catch { self.error = error.userMessage }
        }
    }
}

private struct MusicRadioPage: View {
    @Environment(SessionManager.self) private var session
    @State private var radios: [MusicRadio] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.warning) }
            ForEach(radios) { radio in
                Text(radio.title)
            }
        }
        .navigationTitle("网络广播")
        .task {
            do { radios = try await session.client?.musicRadios() ?? [] }
            catch { self.error = error.userMessage }
        }
    }
}

private struct AlbumTile: View {
    let album: MusicAlbum
    @Environment(SessionManager.self) private var session
    @State private var url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: url) {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x22C55E), Color(hex: 0x0EA5E9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(album.name.isEmpty ? "未知专辑" : album.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(album.artist.isEmpty ? "未知歌手" : album.artist).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .task(id: album.id) {
            url = try? await session.client?.coverURL(for: album)
        }
    }
}

private struct AlbumView: View {
    let album: MusicAlbum
    @Environment(SessionManager.self) private var session
    @Environment(MusicPlayer.self) private var player
    @State private var songs: [Song] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AlbumTile(album: album).frame(maxWidth: 220)
                    Button {
                        guard let client = session.client, !songs.isEmpty else { return }
                        player.play(songs.map { $0.track(using: client) })
                    } label: {
                        Label("播放全部", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section { SongRows(songs: songs) }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { songs = (try? await session.client?.songs(album: album)) ?? [] }
    }
}

private struct PlaylistView: View {
    let playlist: MusicPlaylist
    @Environment(SessionManager.self) private var session
    @State private var songs: [Song] = []

    var body: some View {
        List { SongRows(songs: songs) }
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
            .navigationTitle(playlist.name)
            .task { songs = (try? await session.client?.playlistSongs(playlist.id)) ?? [] }
    }
}

/// Compact now-playing bar; tap for the full player.
struct MiniPlayer: View {
    @Environment(MusicPlayer.self) private var player
    @State private var expanded = false

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Group {
                    if let art = player.artwork {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(hex: 0x22C55E).gradient)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(player.error ?? track.artist ?? "").font(.caption)
                        .foregroundStyle(player.error == nil ? Theme.secondaryText : Theme.danger).lineLimit(1)
                }
                Spacer()
                if player.isLoading {
                    ProgressView()
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }
            .sheet(isPresented: $expanded) { NowPlayingView() }
        }
    }
}

struct NowPlayingView: View {
    @Environment(MusicPlayer.self) private var player
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            Group {
                if let art = player.artwork {
                    Image(uiImage: art).resizable().scaledToFit()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0x22C55E), Color(hex: 0x0EA5E9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.white.opacity(0.9))
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(radius: 20, y: 10)
            .padding(.horizontal, 32)

            VStack(spacing: 4) {
                Text(player.current?.title ?? "").font(.title3.weight(.semibold)).lineLimit(1)
                Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrubbing ?? player.elapsed }, set: { scrubbing = $0 }),
                       in: 0...max(player.duration, 1)) { editing in
                    if !editing, let s = scrubbing {
                        player.seek(to: s)
                        scrubbing = nil
                    }
                }
                HStack {
                    Text(Duration.seconds(Int(scrubbing ?? player.elapsed)).formatted(.time(pattern: .minuteSecond)))
                    Spacer()
                    Text(Duration.seconds(Int(player.duration)).formatted(.time(pattern: .minuteSecond)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 28)

            HStack(spacing: 48) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            }
            .foregroundStyle(.primary)
            Spacer()
        }
        .presentationDragIndicator(.hidden)
    }
}
