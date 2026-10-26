import SwiftUI
import DSMKit

/// Video Station library: movies, TV shows, home videos and recordings as poster walls, with
/// details, watch progress and the Video Station player (resume, subtitles, transcoding).
struct VideoLibraryView: View {
    @Environment(SessionManager.self) private var session
    @State private var libraries: [VideoLibrary] = []
    @State private var selectedKey = ""
    @State private var folders: [VideoFolder] = []
    /// -1 means every directory of the selected library.
    @State private var folderChoice = -1
    @State private var showingPlaylists = false
    @State private var sort: VideoSort = .added
    @State private var items: [VideoItem] = []
    @State private var total = 0
    @State private var search = ""
    @State private var query = ""
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var unavailable = false
    @State private var error: String?
    /// Bumped on every reload so a late page for a tab the user already left is dropped.
    @State private var generation = 0
    @State private var libraryOfItem: [Int: Int] = [:]

    private static let pageSize = 120

    private var visible: [VideoItem] {
        search.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var currentLibrary: VideoLibrary? {
        libraries.first { $0.key == selectedKey } ?? libraries.first
    }
    private var kind: VideoKind { currentLibrary?.playbackKind ?? .movie }

    private func libraryID(for item: VideoItem) -> Int {
        libraryOfItem[item.id] ?? currentLibrary?.id ?? 0
    }
    private var continueWatching: [VideoItem] { items.filter(\.isInProgress) }

    var body: some View {
        ScrollView {
            if unavailable {
                ContentUnavailableView("未安装 Video Station", systemImage: "film",
                                       description: Text("Video Station 只支持到 DSM 7.2.1；更高版本请用文件管理直接播放，或接入 Emby / Jellyfin。"))
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    libraryPicker
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
                    if showingPlaylists {
                        playlistList
                    } else {
                    if search.isEmpty && kind != .tvshow && !continueWatching.isEmpty {
                        continueRow
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 18) {
                        ForEach(visible) { item in
                            NavigationLink {
                                VideoDetailView(item: item, kind: kind, libraryID: libraryID(for: item))
                            } label: {
                                PosterTile(item: item, kind: kind)
                            }
                            .buttonStyle(.plain)
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                    if loadingMore { ProgressView().frame(maxWidth: .infinity) }
                    if loaded && visible.isEmpty {
                        Text(search.isEmpty ? "没有内容" : "没有匹配的片名")
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if loaded && search.isEmpty && total > 0 {
                        Text("共 \(total) 部").font(.caption).foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity)
                    }
                    }
                }
                .padding(16)
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .background(Theme.background)
        .navigationTitle("Video Station")
        .searchable(text: $search, prompt: "搜索片名")
        .onSubmit(of: .search) { query = search }
        .onChange(of: search) { _, _ in if search.isEmpty { query = "" } }
        .onChange(of: selectedKey) { _, _ in
            folderChoice = -1
            Task { await loadFolders() }
        }
        .toolbar { if !unavailable && !showingPlaylists { toolbarMenu } }
        .task { await prepare() }
        .task(id: "\(selectedKey)-\(folderChoice)-\(sort.rawValue)-\(query)-\(showingPlaylists)") {
            if !showingPlaylists { await reload() }
        }
        .refreshable { await reload() }
    }

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !folders.isEmpty {
                    Picker("目录", selection: $folderChoice) {
                        Text("全部目录").tag(-1)
                        ForEach(folders) { Text($0.title).tag($0.id) }
                    }
                }
                Picker("排序", selection: $sort) {
                    ForEach(VideoSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续观看").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(continueWatching) { item in
                        NavigationLink {
                            VideoDetailView(item: item, kind: kind, libraryID: libraryID(for: item))
                        } label: {
                            PosterTile(item: item, kind: kind).frame(width: 100)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Which tabs and libraries this NAS has. Runs once; the list itself loads per tab.
    private func prepare() async {
        guard let client = session.client else { return }
        guard await client.hasVideoStation else {
            unavailable = true
            loaded = true
            return
        }
        let found = (try? await client.videoLibraries())?.filter { $0.type != VideoKind.tvRecord.rawValue } ?? []
        libraries = found.isEmpty ? Self.fallbackLibraries : found
        if currentLibrary == nil { selectedKey = libraries.first?.key ?? "" }
        await loadFolders()
    }

    private static let fallbackLibraries = [
        VideoLibrary(id: 0, title: "电影", type: "movie"),
        VideoLibrary(id: 0, title: "电视节目", type: "tvshow"),
        VideoLibrary(id: 0, title: "家庭视频", type: "home_video"),
    ]

    private var libraryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(libraries, id: \.key) { library in
                    chip(library.title, selected: !showingPlaylists && currentLibrary?.key == library.key) {
                        showingPlaylists = false
                        selectedKey = library.key
                    }
                }
                chip("播放列表", selected: showingPlaylists) { showingPlaylists = true }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.subtle, in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var playlistList: some View {
        VStack(spacing: 0) {
            ForEach(VideoPlaylist.allCases) { playlist in
                NavigationLink {
                    VideoPlaylistPage(playlist: playlist)
                } label: {
                    HStack {
                        Text(playlist.title)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func loadFolders() async {
        guard let client = session.client, let library = currentLibrary else {
            folders = []
            return
        }
        folders = (try? await client.videoFolders(libraryID: library.id)) ?? []
    }

    private func reload() async {
        guard let client = session.client else { return }
        guard await client.hasVideoStation else {
            unavailable = true
            loaded = true
            return
        }
        generation += 1
        let started = generation
        loaded = false
        do {
            let page = try await loadPage(client, offset: 0)
            guard started == generation else { return }
            items = page.items
            total = page.total
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard started == generation else { return }
            items = []
            total = 0
            self.error = error.userMessage
        }
        loaded = true
    }

    private func loadMore() async {
        guard let client = session.client, loaded, !loadingMore, items.count < total else { return }
        let started = generation
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await loadPage(client, offset: items.count),
              started == generation else { return }
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        total = page.items.isEmpty ? items.count : page.total
    }

    /// One library, optionally one of its directories. Other libraries are separate tabs.
    private func loadPage(_ client: DSMClient, offset: Int) async throws -> VideoPage {
        let id = currentLibrary?.id ?? 0
        let folder = folderChoice < 0 ? nil : folderChoice
        let page = try await client.videoPage(kind, libraryID: id, folderID: folder, sort: sort, ascending: sort == .title,
                                              keyword: query, offset: offset, limit: Self.pageSize)
        remember(page.items, library: id)
        return page
    }

    private func remember(_ pageItems: [VideoItem], library: Int) {
        for item in pageItems { libraryOfItem[item.id] = library }
    }
}

private struct VideoPlaylistPage: View {
    let playlist: VideoPlaylist
    @Environment(SessionManager.self) private var session
    @State private var items: [VideoItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("无法读取\(playlist.title)", systemImage: "film", description: Text(error))
            } else if loaded && items.isEmpty {
                ContentUnavailableView("没有内容", systemImage: "film", description: Text(playlist.title))
            } else {
                List(items) { item in
                    NavigationLink {
                        VideoDetailView(item: item, kind: playlist == .watchlist ? .tvshow : .movie, libraryID: 0)
                    } label: {
                        Text(item.title)
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(playlist.title)
        .task {
            do {
                items = try await session.client?.videoPlaylist(playlist) ?? []
            } catch {
                self.error = error.userMessage
            }
            loaded = true
        }
    }
}

struct PosterTile: View {
    let item: VideoItem
    let kind: VideoKind
    var showsCaption = true
    @Environment(SessionManager.self) private var session
    @State private var url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                RemoteImage(url: url) {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0xEF4444), Color(hex: 0x7C3AED)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: kind == .tvshow ? "tv" : "film").font(.title).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let ratio = item.watchedRatio, ratio > 0.02 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.45))
                            Rectangle().fill(Theme.accent).frame(width: geo.size.width * min(ratio, 1))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            if showsCaption {
                Text(item.title).font(.caption.weight(.medium)).lineLimit(2)
                if let year = item.year { Text(String(year)).font(.caption2).foregroundStyle(Theme.secondaryText) }
            }
        }
        .task(id: item.id) {
            guard item.hasPoster else { return }
            url = try? await session.client?.posterURL(for: item, kind: kind)
        }
    }
}

/// What the player sheet should open.
struct VideoPlayRequest: Identifiable {
    let title: String
    let file: VideoFile
    var id: Int { file.id }
}

private struct VideoDetailView: View {
    let item: VideoItem
    let kind: VideoKind
    let libraryID: Int
    @Environment(SessionManager.self) private var session
    @State private var detail: VideoItem?
    @State private var episodes: [VideoItem] = []
    @State private var season: Int?
    @State private var episodeAscending = true
    @State private var posterURL: URL?
    @State private var playing: VideoPlayRequest?

    private var info: VideoItem { detail ?? item }
    private var seasons: [Int] { Array(Set(episodes.compactMap(\.season))).sorted() }
    private var seasonEpisodes: [VideoItem] {
        let rows = season == nil ? episodes : episodes.filter { $0.season == season }
        return rows.sorted { lhs, rhs in
            let a = videoPlayOrder(title: lhs.title, season: lhs.season, episode: lhs.episode)
            let b = videoPlayOrder(title: rhs.title, season: rhs.season, episode: rhs.episode)
            if a.season != b.season { return episodeAscending ? a.season < b.season : a.season > b.season }
            return episodeAscending ? a.episode < b.episode : a.episode > b.episode
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if kind != .tvshow, let file = info.videoFiles.first {
                    playButton(file)
                }
                if !info.genres.isEmpty { genreChips }
                if let summary = info.summary {
                    section("简介") { Text(summary).font(.subheadline).foregroundStyle(.primary.opacity(0.85)) }
                }
                if !info.directors.isEmpty || !info.actors.isEmpty {
                    section("演职员") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !info.directors.isEmpty { InfoRow(label: "导演", value: info.directors.joined(separator: "、")) }
                            if !info.actors.isEmpty { InfoRow(label: "演员", value: info.actors.prefix(8).joined(separator: "、")) }
                        }
                    }
                }
                if kind != .tvshow, !info.videoFiles.isEmpty {
                    section(info.videoFiles.count > 1 ? "版本" : "文件") {
                        VStack(spacing: 10) {
                            ForEach(info.videoFiles) { file in
                                Button { play(file) } label: { VideoFileRow(file: file) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if kind == .tvshow { episodeSection }
            }
            .padding(16)
        }
        .background(alignment: .top) { backdrop }
        .background(Theme.background)
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if item.hasPoster { posterURL = try? await session.client?.posterURL(for: item, kind: kind) }
            if let full = try? await session.client?.videoDetail(item, kind: kind) { detail = full }
            if kind == .tvshow {
                episodes = (try? await session.client?.episodes(of: item, libraryID: libraryID)) ?? []
                season = episodes.first(where: \.isInProgress)?.season ?? seasons.first
            }
        }
        .fullScreenCover(item: $playing) { VideoStationPlayerView(title: $0.title, file: $0.file) }
    }

    private var backdrop: some View {
        RemoteImage(url: posterURL) { Color.clear }
            .frame(height: 320)
            .blur(radius: 40)
            .opacity(0.45)
            .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterTile(item: item, kind: kind, showsCaption: false).frame(width: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.title).font(.title2.weight(.bold)).lineLimit(3)
                if let tagline = info.tagline, tagline != info.title {
                    Text(tagline).font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                Text(metaLine).font(.caption).foregroundStyle(Theme.secondaryText)
                if let rating = info.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(hex: 0xF59E0B))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = info.year { parts.append(String(year)) }
        if let d = info.videoFiles.first?.duration { parts.append(VideoTime.duration(d)) }
        if let r = info.videoFiles.first?.resolutionLabel { parts.append(r) }
        if let c = info.certificate { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    private func playButton(_ file: VideoFile) -> some View {
        Button { play(file) } label: {
            Label(info.isInProgress ? "继续播放" : "播放", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(info.genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.card, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var episodeSection: some View {
        section("剧集") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(episodeAscending ? "正序" : "倒序").font(.subheadline.weight(.medium))
                    Spacer()
                    Button(episodeAscending ? "改为倒序" : "改为正序") { episodeAscending.toggle() }
                        .font(.subheadline)
                }
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons, id: \.self) { s in
                                Button("第 \(s) 季") { season = s }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(season == s ? Theme.accent : Theme.subtle, in: Capsule())
                                    .foregroundStyle(season == s ? .white : .primary)
                            }
                        }
                    }
                }
                if episodes.isEmpty {
                    Text("正在读取剧集…").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                ForEach(seasonEpisodes) { ep in
                    Button {
                        if let file = ep.videoFiles.first { playing = VideoPlayRequest(title: episodeTitle(ep), file: file) }
                    } label: {
                        EpisodeRow(episode: ep)
                    }
                    .buttonStyle(.plain)
                    .disabled(ep.videoFiles.isEmpty)
                }
            }
        }
    }

    private func episodeTitle(_ ep: VideoItem) -> String {
        "\(info.title) S\(ep.season ?? 0)E\(ep.episode ?? 0)"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func play(_ file: VideoFile) {
        playing = VideoPlayRequest(title: info.title, file: file)
    }
}

private struct VideoFileRow: View {
    let file: VideoFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts: [String] = []
        if let r = file.resolutionLabel { parts.append(r) }
        if let v = file.videoCodec { parts.append(v.uppercased()) }
        if let a = file.audioCodec { parts.append(a.uppercased()) }
        if let s = file.size { parts.append(Format.bytes(s)) }
        return parts.isEmpty ? file.fileExtension.uppercased() : parts.joined(separator: " · ")
    }
}

private struct EpisodeRow: View {
    let episode: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", episode.episode ?? 0))
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title.isEmpty ? "第 \(episode.episode ?? 0) 集" : episode.title).font(.subheadline).lineLimit(1)
                if let summary = episode.summary {
                    Text(summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
                if let ratio = episode.watchedRatio, ratio > 0.02 {
                    ProgressView(value: min(ratio, 1)).tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: (episode.watchedRatio ?? 0) >= 0.95 ? "checkmark.circle.fill" : "play.circle")
                .foregroundStyle((episode.watchedRatio ?? 0) >= 0.95 ? Theme.good : Theme.accent)
        }
        .contentShape(Rectangle())
    }
}

enum VideoTime {
    /// "1:02:03" or "2:03".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "2 小时 5 分" or "45 分钟".
    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(max(m, 1)) 分钟"
    }
}
