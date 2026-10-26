import Foundation
import DSMKit

/// Jellyfin and Emby share the same REST API (Jellyfin forked from Emby).
public enum MediaSort: String, CaseIterable, Sendable {
    case name = "SortName"
    case added = "DateCreated"
    case premiere = "PremiereDate"
    case rating = "CommunityRating"
    case year = "ProductionYear"
    case runtime = "Runtime"
    case episode = "IndexNumber"

    public var label: String {
        switch self {
        case .name: return "名称"
        case .added: return "最近添加"
        case .premiere: return "上映日期"
        case .rating: return "评分"
        case .year: return "年份"
        case .runtime: return "时长"
        case .episode: return "集数"
        }
    }

    /// Name, year and episode order read better ascending; dates and ratings read better descending.
    public var ascendingByDefault: Bool {
        switch self {
        case .name, .year, .episode: return true
        default: return false
        }
    }
}

public struct MediaLibrary: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let collectionType: String?

    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name", collectionType = "CollectionType" }

    public var isMusic: Bool { collectionType == "music" }
}

public struct MediaEntry: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let isFolder: Bool
    public let year: Int?
    public let overview: String?
    /// Runtime in seconds.
    public let runtime: Double?
    public let seriesName: String?
    public let indexNumber: Int?
    public let seasonNumber: Int?
    public let artist: String?
    public let album: String?
    public let hasPrimaryImage: Bool
    /// File name from the server, used when the scraped episode number is missing.
    public let fileName: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", isFolder = "IsFolder", year = "ProductionYear"
        case overview = "Overview", runTimeTicks = "RunTimeTicks", seriesName = "SeriesName"
        case indexNumber = "IndexNumber", seasonNumber = "ParentIndexNumber", albumArtist = "AlbumArtist"
        case album = "Album", imageTags = "ImageTags", path = "Path", mediaSources = "MediaSources"
    }

    private struct MediaSourceName: Decodable {
        let Name: String?
        let Path: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        runtime = try c.decodeIfPresent(Double.self, forKey: .runTimeTicks).map { $0 / 10_000_000 }
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        indexNumber = Self.flexInt(c, .indexNumber)
        seasonNumber = Self.flexInt(c, .seasonNumber)
        artist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        hasPrimaryImage = (try c.decodeIfPresent([String: String].self, forKey: .imageTags))?["Primary"] != nil
        let path = try c.decodeIfPresent(String.self, forKey: .path)
        let source = try c.decodeIfPresent([MediaSourceName].self, forKey: .mediaSources)?.first
        fileName = Self.fileName(source?.Name) ?? Self.fileName(source?.Path) ?? Self.fileName(path)
    }

    private static func fileName(_ path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func flexInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    public var isPlayableVideo: Bool { ["Movie", "Episode", "Video", "MusicVideo"].contains(type) }
    public var isAudio: Bool { type == "Audio" }

    /// Season and episode for ordering. Scraped `IndexNumber` wins; otherwise the file name, then the title.
    public var episodeOrder: (season: Int, episode: Int) {
        mediaEpisodeOrder(name: name, fileName: fileName, season: seasonNumber, episode: indexNumber)
    }
}

public struct MediaPerson: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let hasImage: Bool
}

public struct MediaDetail: Sendable {
    public let item: MediaEntry
    public let people: [MediaPerson]
    public let genres: [String]
    public let officialRating: String?
    public let communityRating: Double?
}

/// Scraped episode number first, then S01E02 / 1x02 / 第12集 / a leading number in the file name.
public func mediaEpisodeOrder(name: String, fileName: String? = nil, season: Int? = nil, episode: Int? = nil) -> (season: Int, episode: Int) {
    var parsedSeason: Int?
    var parsedEpisode: Int?
    for text in [fileName, name].compactMap({ $0 }) {
        if let groups = regexCaptureGroups("[Ss](\\d{1,3})[ ._-]*[Ee](\\d{1,4})", in: text), groups.count == 2 {
            parsedSeason = Int(groups[0])
            parsedEpisode = Int(groups[1])
            break
        }
        if let groups = regexCaptureGroups("(\\d{1,2})[xX](\\d{1,4})", in: text), groups.count == 2 {
            parsedSeason = Int(groups[0])
            parsedEpisode = Int(groups[1])
            break
        }
        if let groups = regexCaptureGroups("第\\s*(\\d{1,4})\\s*[集话]", in: text), let episode = groups.first {
            parsedEpisode = Int(episode)
            break
        }
        if let groups = regexCaptureGroups("(?:^|[^\\p{L}])[Ee][Pp]?(\\d{1,4})(?:\\D|$)", in: text), let episode = groups.first {
            parsedEpisode = Int(episode)
            break
        }
        if let groups = regexCaptureGroups("(?:^|/)(\\d{1,3})(?:\\D|$)", in: text), let episode = groups.first {
            parsedEpisode = Int(episode)
            break
        }
    }
    return (season ?? parsedSeason ?? 0, episode ?? parsedEpisode ?? Int.max)
}

public final class JellyfinClient: @unchecked Sendable {
    public let kind: ServiceKind
    let http: ServiceHTTP
    let deviceID: String
    private let lock = NSLock()
    private var _token: String?
    private var _userID: String?

    public var token: String? { lock.lock(); defer { lock.unlock() }; return _token }
    public var userID: String? { lock.lock(); defer { lock.unlock() }; return _userID }

    /// Emby serves its API under /emby; Jellyfin at the root.
    public init(account: ServiceAccount, transport: HTTPTransport, deviceID: String) throws {
        guard var base = account.baseURL else { throw ServiceError.invalidAddress }
        if account.kind == .emby && !base.path.lowercased().hasSuffix("/emby") {
            base = base.appendingPathComponent("emby")
        }
        kind = account.kind
        http = ServiceHTTP(base: base, transport: transport)
        self.deviceID = deviceID
    }

    var authHeader: String {
        var value = #"MediaBrowser Client="NAS Helper", Device="iOS", DeviceId="\#(deviceID)", Version="1.0""#
        if let token { value += #", Token="\#(token)""# }
        return value
    }

    var headers: [String: String] {
        var h = ["X-Emby-Authorization": authHeader, "Authorization": authHeader]
        if let token { h["X-Emby-Token"] = token }
        return h
    }

    public func login(username: String, password: String) async throws {
        struct R: Decodable {
            struct U: Decodable { let Id: String }
            let AccessToken: String
            let User: U
        }
        let data = try await http.data("POST", http.url("Users/AuthenticateByName"), headers: headers,
                                       json: ["Username": username, "Pw": password])
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw ServiceError.invalidResponse }
        store(token: r.AccessToken, userID: r.User.Id)
    }

    private func store(token: String, userID: String) {
        lock.lock(); defer { lock.unlock() }
        _token = token
        _userID = userID
    }

    public func libraries() async throws -> [MediaLibrary] {
        struct R: Decodable { let Items: [MediaLibrary] }
        guard let uid = userID else { throw ServiceError.unauthorized }
        return try await http.get(R.self, http.url("Users/\(uid)/Views"), headers: headers).Items
    }

    /// Children of a library, series, season or folder.
    public func items(parent: String, recursive: Bool = false, types: [String] = [], offset: Int = 0, limit: Int = 300,
                      sort: MediaSort = .name, ascending: Bool = true, search: String = "") async throws -> [MediaEntry] {
        struct R: Decodable { let Items: [MediaEntry] }
        guard let uid = userID else { throw ServiceError.unauthorized }
        var query = [
            "ParentId": parent, "StartIndex": String(offset), "Limit": String(limit),
            "SortBy": sort.rawValue, "SortOrder": ascending ? "Ascending" : "Descending",
            "Fields": "Overview,ProductionYear,Path,MediaSources", "EnableImageTypes": "Primary",
        ]
        if recursive { query["Recursive"] = "true" }
        if !types.isEmpty { query["IncludeItemTypes"] = types.joined(separator: ",") }
        let word = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !word.isEmpty { query["SearchTerm"] = word }
        return try await http.get(R.self, http.url("Users/\(uid)/Items", query: query), headers: headers).Items
    }

    public func search(_ text: String) async throws -> [MediaEntry] {
        struct R: Decodable { let Items: [MediaEntry] }
        guard let uid = userID else { throw ServiceError.unauthorized }
        return try await http.get(R.self, http.url("Users/\(uid)/Items", query: [
            "SearchTerm": text, "Recursive": "true", "Limit": "100",
            "IncludeItemTypes": "Movie,Series,Episode,Audio,MusicAlbum", "Fields": "Overview,ProductionYear",
        ]), headers: headers).Items
    }

    public func detail(id: String) async throws -> MediaDetail {
        guard let uid = userID else { throw ServiceError.unauthorized }
        let data = try await http.data("GET", http.url("Users/\(uid)/Items/\(id)", query: [
            "Fields": "Overview,People,Genres,OfficialRating,CommunityRating,ProductionYear,RunTimeTicks,Path,MediaSources",
        ]), headers: headers)
        let item = try JSONDecoder().decode(MediaEntry.self, from: data)
        let extra = try JSONDecoder().decode(DetailExtra.self, from: data)
        let people = (extra.People ?? []).compactMap { person -> MediaPerson? in
            let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            if let type = person.kind, type != "Actor" { return nil }
            return MediaPerson(id: person.id ?? name, name: name, role: person.role, hasImage: person.primaryImageTag != nil)
        }
        let genres = extra.Genres ?? extra.NamedGenres?.map(\.Name).filter { !$0.isEmpty } ?? []
        return MediaDetail(item: item, people: people, genres: genres,
                           officialRating: extra.OfficialRating, communityRating: extra.CommunityRating)
    }

    /// Asks Emby or Jellyfin which URL to play. Native mp4/mov stay direct; anything else uses the server's HLS URL.
    public func playbackURL(for item: MediaEntry) async throws -> URL {
        guard userID != nil else { throw ServiceError.unauthorized }
        let data = try await http.data("POST", http.url("Items/\(item.id)/PlaybackInfo", query: [
            "UserId": userID ?? "", "MaxStreamingBitrate": "120000000", "AutoOpenLiveStream": "true",
        ]), headers: headers, json: Self.playbackBody(userID: userID ?? ""))
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: data)
        guard let source = info.MediaSources.first else { throw ServiceError.invalidResponse }
        let container = source.Container?.lowercased() ?? ""
        let native = ["mp4", "m4v", "mov"].contains(container)
        if native, let direct = source.DirectStreamUrl, let url = resolve(direct) { return url }
        if let transcode = source.TranscodingUrl, let url = resolve(transcode) { return url }
        return videoURL(for: item, mediaSourceID: source.Id ?? item.id, playSessionID: info.PlaySessionId)
    }

    public func imageURL(for item: MediaEntry, maxHeight: Int = 600) -> URL {
        http.url("Items/\(item.id)/Images/Primary", query: ["maxHeight": String(maxHeight), "quality": "85"])
    }

    /// Fallback when PlaybackInfo does not return a URL. MPEG-TS HLS is what AVPlayer plays.
    /// The token is in the URL because AVPlayer cannot add headers; don't log it.
    public func videoURL(for item: MediaEntry, mediaSourceID: String? = nil, playSessionID: String? = nil) -> URL {
        var query = [
            "MediaSourceId": mediaSourceID ?? item.id, "DeviceId": deviceID, "api_key": token ?? "",
            "VideoCodec": "h264", "AudioCodec": "aac", "TranscodingMaxAudioChannels": "2",
            "SegmentContainer": "ts", "MaxStreamingBitrate": "120000000",
        ]
        if let playSessionID { query["PlaySessionId"] = playSessionID }
        return http.url("Videos/\(item.id)/master.m3u8", query: query)
    }

    public func personImageURL(_ person: MediaPerson, maxHeight: Int = 400) -> URL? {
        guard person.hasImage else { return nil }
        return http.url("Items/\(person.id)/Images/Primary", query: ["maxHeight": String(maxHeight), "quality": "80"])
    }

    private func resolve(_ raw: String) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        var path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        let prefix = http.base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty, path.hasPrefix(prefix + "/") {
            path = String(path.dropFirst(prefix.count + 1))
        }
        var base = http.base.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + path)
    }

    private static func playbackBody(userID: String) -> [String: Any] {
        [
            "UserId": userID,
            "MaxStreamingBitrate": 120_000_000,
            "StartTimeTicks": 0,
            "AutoOpenLiveStream": true,
            "DeviceProfile": [
                "MaxStreamingBitrate": 120_000_000,
                "MaxStaticBitrate": 120_000_000,
                "DirectPlayProfiles": [[
                    "Container": "mp4,m4v,mov",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc",
                    "AudioCodec": "aac,mp3,ac3,eac3",
                ]],
                "TranscodingProfiles": [[
                    "Container": "ts",
                    "Type": "Video",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "MaxAudioChannels": "2",
                ]],
                "SubtitleProfiles": [
                    ["Format": "vtt", "Method": "External"],
                    ["Format": "srt", "Method": "External"],
                ],
            ],
        ]
    }

    public func audioURL(for item: MediaEntry) -> URL {
        http.url("Audio/\(item.id)/universal", query: [
            "UserId": userID ?? "", "DeviceId": deviceID, "api_key": token ?? "",
            "Container": "mp3,aac,m4a,flac,alac,wav", "TranscodingContainer": "mp3", "AudioCodec": "mp3",
            "MaxStreamingBitrate": "320000",
        ])
    }

    /// Image requests need the token too; use this to fetch through the pinned transport.
    public func fetch(_ url: URL) async throws -> Data {
        try await http.data("GET", url, headers: headers)
    }
}

private struct DetailExtra: Decodable {
    struct Person: Decodable {
        let id: String?
        let name: String?
        let role: String?
        let kind: String?
        let primaryImageTag: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", role = "Role", kind = "Type", primaryImageTag = "PrimaryImageTag"
        }
    }
    struct Named: Decodable { let Name: String }

    let People: [Person]?
    let Genres: [String]?
    let NamedGenres: [Named]?
    let OfficialRating: String?
    let CommunityRating: Double?

    enum CodingKeys: String, CodingKey {
        case People, Genres, OfficialRating, CommunityRating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        People = try c.decodeIfPresent([Person].self, forKey: .People)
        OfficialRating = try c.decodeIfPresent(String.self, forKey: .OfficialRating)
        if let number = try? c.decode(Double.self, forKey: .CommunityRating) {
            CommunityRating = number
        } else if let number = try? c.decode(Int.self, forKey: .CommunityRating) {
            CommunityRating = Double(number)
        } else {
            CommunityRating = nil
        }
        if let names = try? c.decode([String].self, forKey: .Genres) {
            Genres = names
            NamedGenres = nil
        } else if let named = try? c.decode([Named].self, forKey: .Genres) {
            Genres = nil
            NamedGenres = named
        } else {
            Genres = nil
            NamedGenres = nil
        }
    }
}

private struct PlaybackInfo: Decodable {
    struct Source: Decodable {
        let Id: String?
        let Container: String?
        let DirectStreamUrl: String?
        let TranscodingUrl: String?
    }
    let MediaSources: [Source]
    let PlaySessionId: String?
}
