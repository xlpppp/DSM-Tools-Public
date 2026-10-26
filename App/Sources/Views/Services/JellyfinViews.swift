import SwiftUI
import AVKit
import MediaKit

struct JellyfinLibrariesView: View {
    let client: JellyfinClient
    let account: ServiceAccount
    @State private var libraries: [MediaLibrary] = []
    @State private var search = ""
    @State private var results: [MediaEntry]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.warning) }
            if let results {
                Section("搜索结果") {
                    ForEach(results) { item in EntryLink(client: client, account: account, item: item, siblings: results) }
                }
            } else {
                ForEach(libraries) { lib in
                    NavigationLink {
                        JellyfinItemsView(client: client, account: account, parentID: lib.id, title: lib.name, isMusic: lib.isMusic)
                    } label: {
                        Label(lib.name, systemImage: icon(lib.collectionType))
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索 \(account.kind.title)")
        .onSubmit(of: .search) { Task { results = try? await client.search(search) } }
        .onChange(of: search) { if search.isEmpty { results = nil } }
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .task {
            do { libraries = try await client.libraries() } catch { self.error = error.serviceMessage }
        }
    }

    private func icon(_ type: String?) -> String {
        switch type {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "homevideos", "photos": return "photo.on.rectangle"
        default: return "folder"
        }
    }
}

struct JellyfinItemsView: View {
    let client: JellyfinClient
    let account: ServiceAccount
    let parentID: String
    let title: String
    var isMusic = false
    @State private var items: [MediaEntry] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var query = ""
    @State private var sort: MediaSort
    @State private var ascending: Bool
    @State private var stickToEpisode = true

    init(client: JellyfinClient, account: ServiceAccount, parentID: String, title: String, isMusic: Bool = false) {
        self.client = client
        self.account = account
        self.parentID = parentID
        self.title = title
        self.isMusic = isMusic
        let episodes = title.contains("季")
        _sort = State(initialValue: episodes ? .episode : .name)
        _ascending = State(initialValue: episodes ? true : MediaSort.name.ascendingByDefault)
    }

    private var posterRatio: CGFloat { isMusic ? 1 : 2.0 / 3.0 }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isMusic ? 150 : 110), spacing: 14)], spacing: 18) {
                ForEach(items) { item in
                    EntryLink(client: client, account: account, item: item, siblings: items, grid: true, posterRatio: posterRatio)
                }
            }
            .padding(16)
        }
        .overlay { if !loaded { ProgressView() } }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "在此分类中搜索")
        .onSubmit(of: .search) { query = search }
        .onChange(of: search) { _, _ in if search.isEmpty { query = "" } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sort) {
                        ForEach(MediaSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Button(ascending ? "改为倒序" : "改为正序") { ascending.toggle() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
        .onChange(of: sort) { _, new in
            ascending = new.ascendingByDefault
            if new != .episode { stickToEpisode = false }
        }
        .task(id: "\(sort.rawValue)-\(ascending)-\(query)") {
            loaded = false
            var loadedItems = (try? await client.items(parent: parentID, recursive: !query.isEmpty, sort: sort,
                                                       ascending: ascending, search: query)) ?? []
            if stickToEpisode, loadedItems.contains(where: { $0.type == "Episode" }), sort != .episode {
                sort = .episode
                ascending = true
                return
            }
            if sort == .episode {
                loadedItems.sort { lhs, rhs in
                    let a = lhs.episodeOrder
                    let b = rhs.episodeOrder
                    if a.season != b.season { return ascending ? a.season < b.season : a.season > b.season }
                    if a.episode != b.episode { return ascending ? a.episode < b.episode : a.episode > b.episode }
                    let left = lhs.fileName ?? lhs.name
                    let right = rhs.fileName ?? rhs.name
                    return ascending ? left < right : left > right
                }
            }
            items = loadedItems
            loaded = true
        }
    }
}

/// One item: folders navigate, videos open a detail page, songs go to the music player.
private struct EntryLink: View {
    let client: JellyfinClient
    let account: ServiceAccount
    let item: MediaEntry
    let siblings: [MediaEntry]
    var grid = false
    var posterRatio: CGFloat = 2.0 / 3.0
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        Group {
            if item.isFolder {
                NavigationLink {
                    JellyfinItemsView(client: client, account: account, parentID: item.id, title: item.name,
                                      isMusic: item.type == "MusicAlbum" || item.type == "MusicArtist")
                } label: { label }
            } else if item.isPlayableVideo {
                NavigationLink {
                    MediaDetailView(client: client, account: account, item: item)
                } label: { label }
            } else {
                Button { open() } label: { label }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var label: some View {
        if grid {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(item.type == "Episode" ? 16.0 / 9.0 : posterRatio, contentMode: .fit)
                    .overlay {
                        RemoteImage(url: item.hasPrimaryImage ? client.imageURL(for: item) : nil, fetcher: { try await client.fetch($0) }) {
                            ZStack {
                                account.kind.color.opacity(0.25)
                                Image(systemName: item.isAudio ? "music.note" : item.isFolder ? "folder" : "film")
                                    .font(.title).foregroundStyle(account.kind.color)
                            }
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(displayName).font(.caption.weight(.medium)).lineLimit(2)
                if let year = item.year { Text(String(year)).font(.caption2).foregroundStyle(Theme.secondaryText) }
            }
        } else {
            HStack {
                Image(systemName: item.isAudio ? "music.note" : item.isFolder ? "folder" : "film").foregroundStyle(account.kind.color)
                Text(displayName).lineLimit(1)
                Spacer()
                if let year = item.year { Text(String(year)).font(.caption).foregroundStyle(Theme.secondaryText) }
            }
        }
    }

    private var displayName: String {
        if item.type == "Episode" {
            let order = item.episodeOrder
            if order.episode != Int.max {
                return "S\(order.season)E\(order.episode) \(item.name)"
            }
        }
        return item.name
    }

    private func open() {
        if item.isAudio {
            let songs = siblings.filter(\.isAudio)
            let tracks = songs.map { song in
                MusicPlayer.Track(id: song.id, title: song.name, artist: song.artist, album: song.album, duration: song.runtime,
                                  resolve: { client.audioURL(for: song) },
                                  artwork: {
                                      guard song.hasPrimaryImage, let data = try? await client.fetch(client.imageURL(for: song)) else { return nil }
                                      return UIImage(data: data)
                                  })
            }
            player.play(tracks, startAt: songs.firstIndex(of: item) ?? 0)
        }
    }
}

private struct MediaDetailView: View {
    let client: JellyfinClient
    let account: ServiceAccount
    let item: MediaEntry
    @State private var detail: MediaDetail?
    @State private var playing: URL?
    @State private var starting = false
    @State private var playError: String?

    private var shown: MediaEntry { detail?.item ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                poster
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.name).font(.title2.bold())
                    Text(meta).font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                Button { Task { await play() } } label: {
                    Label(starting ? "正在准备…" : "播放", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(starting)
                if let playError { Text(playError).font(.footnote).foregroundStyle(Theme.warning) }
                if let genres = detail?.genres, !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(genres, id: \.self) { genre in
                                Text(genre).font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.card, in: Capsule())
                            }
                        }
                    }
                }
                if let overview = shown.overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介").font(.headline)
                        Text(overview).font(.subheadline)
                    }
                }
                if let people = detail?.people, !people.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("演员").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(people) { person in
                                    VStack(spacing: 6) {
                                        RemoteImage(url: client.personImageURL(person), fetcher: { try await client.fetch($0) }) {
                                            ZStack {
                                                account.kind.color.opacity(0.2)
                                                Image(systemName: "person.fill").foregroundStyle(account.kind.color)
                                            }
                                        }
                                        .frame(width: 72, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        Text(person.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                        if let role = person.role, !role.isEmpty {
                                            Text(role).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                        }
                                    }
                                    .frame(width: 76)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(item.type == "Episode" ? "剧集" : "详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detail = try? await client.detail(id: item.id)
        }
        .fullScreenCover(item: Binding(get: { playing.map(PlayURL.init) }, set: { playing = $0?.url })) { page in
            StreamPlayerView(url: page.url)
        }
    }

    private var poster: some View {
        RemoteImage(url: shown.hasPrimaryImage ? client.imageURL(for: shown, maxHeight: 800) : nil, fetcher: { try await client.fetch($0) }) {
            ZStack {
                account.kind.color.opacity(0.25)
                Image(systemName: "film").font(.largeTitle).foregroundStyle(account.kind.color)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: 220)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var meta: String {
        var parts: [String] = []
        if let year = shown.year { parts.append(String(year)) }
        if let runtime = shown.runtime, runtime > 0 {
            let minutes = Int(runtime / 60)
            parts.append(minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟")
        }
        if let rating = detail?.officialRating { parts.append(rating) }
        if let score = detail?.communityRating { parts.append(String(format: "评分 %.1f", score)) }
        if item.type == "Episode" {
            let order = shown.episodeOrder
            if order.episode != Int.max { parts.append("第 \(order.episode) 集") }
        }
        return parts.joined(separator: " · ")
    }

    private func play() async {
        starting = true
        playError = nil
        defer { starting = false }
        do {
            playing = try await client.playbackURL(for: shown)
        } catch {
            playError = error.serviceMessage
        }
    }
}

struct PlayURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Full-screen system player for HLS or direct streams.
struct StreamPlayerView: View {
    let url: URL
    var headers: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let asset = headers.isEmpty
                ? AVURLAsset(url: url)
                // Needed for servers that authenticate media requests by header (Immich).
                : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
