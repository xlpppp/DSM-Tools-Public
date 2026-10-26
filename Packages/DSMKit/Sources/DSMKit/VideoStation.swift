import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Video Station (DSM 6.2–7.2.1; Synology removed it in 7.2.2). Original-quality playback uses the
/// file's File Station path, so it works exactly like the file manager; transcoding, watch progress
/// and subtitles go through Video Station's own APIs.
public struct VideoLibrary: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let type: String

    enum CodingKeys: String, CodingKey { case id, title, type }

    public init(id: Int, title: String, type: String) {
        self.id = id
        self.title = title
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "movie"
        let raw = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
        title = raw ?? VideoKind(rawValue: type)?.label ?? "电影"
    }

    public var kind: VideoKind? { VideoKind(rawValue: type) }

    /// Tabs use this so two built-in libraries that both report id 0 stay distinct.
    public var key: String { "\(type)#\(id)#\(title)" }

    /// API used to list this library. Unknown custom types fall back to home video.
    public var playbackKind: VideoKind { kind ?? .homeVideo }
}

/// A directory attached to one video library. The menu switches these, not other libraries.
public struct VideoFolder: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String

    enum CodingKeys: String, CodingKey { case id, title, path, sharepath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        let path = try c.decodeIfPresent(String.self, forKey: .sharepath)?.nilIfEmpty
            ?? c.decodeIfPresent(String.self, forKey: .path)?.nilIfEmpty
        let name = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
        title = name ?? path.map { ($0 as NSString).lastPathComponent } ?? "目录"
    }
}

/// Sidebar lists under Video Station's 播放列表.
public enum VideoPlaylist: String, CaseIterable, Identifiable, Sendable {
    case favorite = "SYNO.VideoStation.Collection"
    case watchlist = "SYNO.VideoStation.Watching"
    case shared = "SYNO.VideoStation.Sharing"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .favorite: return "收藏夹"
        case .watchlist: return "跟踪列表"
        case .shared: return "共享视频"
        }
    }
}

/// Play order for a TV episode. Missing season/episode fields are read from titles such as S01E18 or 第18集.
public func videoPlayOrder(title: String, season: Int?, episode: Int?) -> (season: Int, episode: Int) {
    let parsed = videoPlayNumbers(in: title)
    return (season ?? parsed.season ?? 0, episode ?? parsed.episode ?? 0)
}

func videoPlayNumbers(in title: String) -> (season: Int?, episode: Int?) {
    if let groups = regexCaptureGroups("[Ss](\\d{1,3})\\s*[Ee](\\d{1,4})", in: title), groups.count == 2 {
        return (Int(groups[0]), Int(groups[1]))
    }
    if let groups = regexCaptureGroups("第\\s*(\\d{1,4})\\s*集", in: title), let episode = groups.first {
        return (nil, Int(episode))
    }
    return (nil, nil)
}

/// Capture groups from the first match. Literal patterns stay compatible with Swift 5.10 and Linux Swift 6.
public func regexCaptureGroups(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let full = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: full) else { return nil }
    var groups: [String] = []
    for index in 1..<match.numberOfRanges {
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        groups.append(String(text[range]))
    }
    return groups
}

public enum VideoKind: String, CaseIterable, Sendable {
    case movie, tvshow, homeVideo = "home_video", tvRecord = "tv_record"

    public var label: String {
        switch self {
        case .movie: return "电影"
        case .tvshow: return "电视节目"
        case .homeVideo: return "家庭视频"
        case .tvRecord: return "录像"
        }
    }

    var api: String {
        switch self {
        case .movie: return "SYNO.VideoStation.Movie"
        case .tvshow: return "SYNO.VideoStation.TVShow"
        case .homeVideo: return "SYNO.VideoStation.HomeVideo"
        case .tvRecord: return "SYNO.VideoStation.TVRecording"
        }
    }

    /// Key of the item array in a list/getinfo answer. Recordings are not confirmed on a real NAS,
    /// so decoding also accepts the other known keys.
    var listKey: String {
        switch self {
        case .movie: return "movies"
        case .tvshow: return "tvshows"
        case .homeVideo, .tvRecord: return "videos"
        }
    }

    var posterType: String { self == .tvshow ? "tvshow" : rawValue }
}

public enum VideoSort: String, CaseIterable, Sendable {
        case added, title, year = "original_available", resolution, duration

    public var label: String {
        switch self {
        case .added: return "最近添加"
        case .title: return "片名"
        case .year: return "上映日期"
        case .resolution: return "分辨率"
        case .duration: return "时长"
        }
    }
}

/// One file of a video (a movie can have several versions).
public struct VideoFile: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    /// File Station path ("/video/a.mkv"); falls back to the volume path.
    public let path: String
    public let size: Int64?
    /// Seconds.
    public let duration: Double?
    public let videoCodec: String?
    public let audioCodec: String?
    public let width: Int?
    public let height: Int?
    public let container: String?

    enum CodingKeys: String, CodingKey {
        case id, sharepath, path, filesize, duration, video_codec, audio_codec, resolutionx, resolutiony, container_type
    }

    public init(id: Int, path: String, size: Int64? = nil, duration: Double? = nil, videoCodec: String? = nil,
                audioCodec: String? = nil, width: Int? = nil, height: Int? = nil, container: String? = nil) {
        self.id = id
        self.path = path
        self.size = size
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.container = container
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(FlexInt.self, forKey: .id))??.value ?? 0
        path = try c.decodeIfPresent(String.self, forKey: .sharepath)?.nilIfEmpty
            ?? c.decodeIfPresent(String.self, forKey: .path) ?? ""
        size = ((try? c.decodeIfPresent(FlexInt.self, forKey: .filesize)) ?? nil).map { Int64($0.value) }
        let d = (try? c.decodeIfPresent(FlexDouble.self, forKey: .duration))??.value
        duration = d.flatMap { $0 > 0 ? $0 : nil }
        videoCodec = try c.decodeIfPresent(String.self, forKey: .video_codec)?.nilIfEmpty
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audio_codec)?.nilIfEmpty
        width = (try? c.decodeIfPresent(FlexInt.self, forKey: .resolutionx))??.value
        height = (try? c.decodeIfPresent(FlexInt.self, forKey: .resolutiony))??.value
        container = try c.decodeIfPresent(String.self, forKey: .container_type)?.nilIfEmpty
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }

    /// "4K", "1080p"… from the frame size; nil when Video Station did not index it.
    public var resolutionLabel: String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        switch max(w, h * 16 / 9) {
        case 3500...: return "4K"
        case 2400..<3500: return "2K"
        case 1800..<2400: return "1080p"
        case 1200..<1800: return "720p"
        default: return "SD"
        }
    }
}

public struct VideoItem: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let year: Int?
    public let summary: String?
    public let videoFiles: [VideoFile]
    public let hasPoster: Bool
    public let season: Int?
    public let episode: Int?
    /// 0…1, how much of the item has been watched (Video Station's own progress).
    public let watchedRatio: Double?
    public let genres: [String]
    public let actors: [String]
    public let directors: [String]
    public let rating: Double?
    public let certificate: String?
    public let tagline: String?

    /// File Station paths of the item's files.
    public var files: [String] { videoFiles.map(\.path) }

    enum CodingKeys: String, CodingKey {
        case id, title, tagline, original_available, year, season, episode, certificate, additional
    }
    struct Named: Decodable { let name: String? }
    struct Additional: Decodable {
        let file: [VideoFile]?
        let summary: String?
        let poster_mtime: String?
        let watched_ratio: FlexDouble?
        let genre: [Named]?
        let actor: [Named]?
        let director: [Named]?
        let extra: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        season = (try? c.decodeIfPresent(FlexInt.self, forKey: .season))??.value
        episode = (try? c.decodeIfPresent(FlexInt.self, forKey: .episode))??.value
        let tagline = try c.decodeIfPresent(String.self, forKey: .tagline)?.nilIfEmpty
        self.tagline = tagline
        title = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty ?? tagline ?? ""
        certificate = try c.decodeIfPresent(String.self, forKey: .certificate)?.nilIfEmpty
        if let y = (try? c.decodeIfPresent(FlexInt.self, forKey: .year))??.value, y > 0 {
            year = y
        } else if let date = try c.decodeIfPresent(String.self, forKey: .original_available), let y = Int(date.prefix(4)), y > 0 {
            year = y
        } else {
            year = nil
        }
        let a = try? c.decodeIfPresent(Additional.self, forKey: .additional)
        summary = a?.summary?.nilIfEmpty
        videoFiles = (a?.file ?? []).filter { !$0.path.isEmpty }
        hasPoster = (a?.poster_mtime?.isEmpty == false)
        watchedRatio = a?.watched_ratio?.value
        genres = a?.genre?.compactMap { $0.name?.nilIfEmpty } ?? []
        actors = a?.actor?.compactMap { $0.name?.nilIfEmpty } ?? []
        directors = a?.director?.compactMap { $0.name?.nilIfEmpty } ?? []
        rating = a?.extra.flatMap(Self.rating(fromExtra:))
    }

    /// `extra` is a JSON string written by the metadata plugin, e.g.
    /// {"com.synology.TheMovieDb":{"rating":{"themoviedb":7.3}}}. Takes the first rating found.
    static func rating(fromExtra extra: String) -> Double? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(extra.utf8)),
              case .object(let plugins) = value else { return nil }
        for key in plugins.keys.sorted() {
            guard case .object(let ratings)? = plugins[key]?["rating"] else { continue }
            for k in ratings.keys.sorted() {
                if case .number(let n)? = ratings[k], n > 0 { return n }
                if let s = ratings[k]?.string, let n = Double(s), n > 0 { return n }
            }
        }
        return nil
    }

    /// Watched part of the item worth offering "continue": started, not finished.
    public var isInProgress: Bool {
        guard let r = watchedRatio else { return false }
        return r > 0.02 && r < 0.95
    }
}

public struct VideoPage: Sendable {
    public let items: [VideoItem]
    public let total: Int

    public init(items: [VideoItem], total: Int) {
        self.items = items
        self.total = total
    }
}

// MARK: Subtitles

public struct VideoSubtitle: Decodable, Identifiable, Hashable, Sendable {
    /// External subtitles use their path as id; embedded ones a track number.
    public let id: String
    public let title: String
    public let language: String?
    public let format: String?
    public let embedded: Bool

    public init(id: String, title: String, language: String? = nil, format: String? = nil, embedded: Bool = false) {
        self.id = id
        self.title = title
        self.language = language
        self.format = format
        self.embedded = embedded
    }

    enum CodingKeys: String, CodingKey { case id, title, lang, language, format, embedded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(JSONValue.self, forKey: .id))?.string ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .lang)?.nilIfEmpty
            ?? c.decodeIfPresent(String.self, forKey: .language)?.nilIfEmpty
        format = try c.decodeIfPresent(String.self, forKey: .format)?.nilIfEmpty
        embedded = (try? c.decodeIfPresent(Bool.self, forKey: .embedded)) ?? false
        let raw = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
        title = raw ?? language ?? ((id as NSString).lastPathComponent.nilIfEmpty ?? "字幕")
    }
}

public struct SubtitleCue: Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Parsed text subtitles (SRT, WebVTT, ASS/SSA), shown by the app over the system player.
public struct SubtitleTrack: Sendable {
    public let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) { self.cues = cues.sorted { $0.start < $1.start } }

    public static func parse(_ text: String) -> SubtitleTrack {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        if normalized.contains("[Events]") || normalized.contains("\nDialogue:") || normalized.hasPrefix("Dialogue:") {
            return SubtitleTrack(cues: parseASS(normalized))
        }
        return SubtitleTrack(cues: parseTimed(normalized))
    }

    /// SRT and WebVTT: blocks separated by blank lines, a "start --> end" line, then text.
    static func parseTimed(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n")
            let clean = stripTags(body)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues
    }

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [SubtitleCue] = []
        var inEvents = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            if inEvents, line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: max(fields.count - 1, 0),
                                                 omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end"),
                  let ti = fields.firstIndex(of: "text"), values.count > max(si, ei, ti),
                  let start = timestamp(values[si]), let end = timestamp(values[ei]) else { continue }
            var body = values[ti].replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            body = body.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456" (WebVTT), "1:02:03.45" (ASS).
    static func timestamp(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cue showing at `time`, if any.
    public func cue(at time: Double) -> SubtitleCue? {
        var low = 0, high = cues.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard let i = found else { return nil }
        // Overlapping cues: walk back to the latest one still on screen.
        var j = i
        while j >= 0 {
            if cues[j].end > time { return cues[j] }
            if i - j > 5 { break }
            j -= 1
        }
        return nil
    }

    /// Subtitle files are often GBK/Big5 in Chinese releases; try UTF-8 first.
    public static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        #if canImport(Darwin)
        for cf in [CFStringEncodings.GB_18030_2000, .big5] {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let s = String(data: data, encoding: enc) { return s }
        }
        #endif
        return String(data: data, encoding: .isoLatin1)
    }
}

// MARK: Streaming

/// Playback quality. `.original` streams the file itself; the others ask Video Station to
/// transcode to HLS (needs a model with hardware transcoding or a fast CPU).
public enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case original, high, medium, low

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .original: return "原画"
        case .high: return "高清 1080p（转码）"
        case .medium: return "标清 720p（转码）"
        case .low: return "流畅 480p（转码）"
        }
    }

    /// Video Station's HLS profile names. Inferred from the web client, not verified on a NAS.
    var profile: String {
        switch self {
        case .original: return "raw"
        case .high: return "hls_high"
        case .medium: return "hls_medium"
        case .low: return "hls_low"
        }
    }
}

public struct VideoStream: Hashable, Sendable {
    public let url: URL
    public let isHLS: Bool
    /// Set for a Video Station streaming session, which must be closed afterwards.
    public let streamID: String?
    let api: String?
}

extension DSMClient {
    public var hasVideoStation: Bool { supports("SYNO.VideoStation.Movie") || supports("SYNO.VideoStation2.Movie") }

    /// Whether this NAS offers the Video Station HLS transcoding session (VideoStation2.Streaming).
    public var canTranscodeVideo: Bool { supports("SYNO.VideoStation2.Streaming") }

    public func supportsVideoKind(_ kind: VideoKind) -> Bool { supports(kind.api) }

    public func videoLibraries() async throws -> [VideoLibrary] {
        struct R: Decodable { let libraries: [VideoLibrary] }
        let r: R = try await call("SYNO.VideoStation.Library", method: "list", version: 1, params: ["offset": "0", "limit": "100"])
        // Built-in libraries come back with id 0 per type when there is no custom library.
        return r.libraries
    }

    static let listAdditional = ["poster_mtime", "summary", "file", "watched_ratio"]
    static let detailAdditional = ["poster_mtime", "summary", "file", "watched_ratio", "genre", "actor", "director", "extra"]

    public func videoFolders(libraryID: Int) async throws -> [VideoFolder] {
        guard supports("SYNO.VideoStation.Folder") else { return [] }
        struct R: Decodable { let folders: [VideoFolder]? }
        let r: R = try await call("SYNO.VideoStation.Folder", method: "list", version: 1, params: [
            "library_id": String(libraryID), "offset": "0", "limit": "200",
        ])
        return r.folders ?? []
    }

    /// Items for 收藏夹, 跟踪列表 or 共享视频. Empty when the API exists but returns no videos.
    public func videoPlaylist(_ playlist: VideoPlaylist) async throws -> [VideoItem] {
        guard supports(playlist.rawValue) else { throw DSMError.apiUnavailable(playlist.rawValue) }
        let r: [String: JSONValue] = try await call(playlist.rawValue, method: "list", version: 1, params: [
            "offset": "0", "limit": "200",
            "additional": FSParam.strings(Self.listAdditional),
        ])
        for key in ["movies", "tvshows", "videos", "episodes", "sharings", "items"] {
            if let list = r[key]?.decode([LossyItem].self) {
                let items = list.compactMap(\.value)
                if !items.isEmpty { return items }
            }
        }
        return []
    }

    public func videoPage(_ kind: VideoKind, libraryID: Int = 0, folderID: Int? = nil, sort: VideoSort = .added, ascending: Bool = false,
                          keyword: String = "", offset: Int = 0, limit: Int = 200) async throws -> VideoPage {
        var params = [
            "offset": String(offset), "limit": String(limit), "library_id": String(libraryID),
            "sort_by": sort.rawValue, "sort_direction": ascending ? "asc" : "desc",
            "additional": FSParam.strings(Self.listAdditional),
        ]
        if let folderID { params["folder_id"] = String(folderID) }
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !word.isEmpty { params["keyword"] = word }
        let r: [String: JSONValue] = try await call(kind.api, method: "list", version: 4, params: params)
        let items = Self.items(in: r, kind: kind)
        let total = r["total"]?.string.flatMap { Int($0) } ?? (offset + items.count)
        return VideoPage(items: items, total: total)
    }

    public func videos(_ kind: VideoKind, libraryID: Int = 0, offset: Int = 0, limit: Int = 500) async throws -> [VideoItem] {
        try await videoPage(kind, libraryID: libraryID, offset: offset, limit: limit).items
    }

    /// Full metadata for the detail screen (genres, cast, rating). Falls back to nil when the NAS
    /// does not answer `getinfo`, so the caller keeps what the list gave it.
    public func videoDetail(_ item: VideoItem, kind: VideoKind) async throws -> VideoItem? {
        let r: [String: JSONValue] = try await call(kind.api, method: "getinfo", version: 2, params: [
            "id": "[\(item.id)]",
            "additional": FSParam.strings(Self.detailAdditional),
        ])
        return Self.items(in: r, kind: kind).first
    }

    static func items(in r: [String: JSONValue], kind: VideoKind) -> [VideoItem] {
        for key in [kind.listKey, "videos", "recordings", "tv_recordings"] {
            if let list = r[key]?.decode([LossyItem].self) { return list.compactMap(\.value) }
        }
        return []
    }

    /// Skips an item that fails to decode instead of losing the whole page.
    struct LossyItem: Decodable {
        let value: VideoItem?
        init(from decoder: Decoder) throws { value = try? VideoItem(from: decoder) }
    }

    public func episodes(of show: VideoItem, libraryID: Int = 0) async throws -> [VideoItem] {
        struct R: Decodable { let episodes: [LossyItem] }
        let r: R = try await call("SYNO.VideoStation.TVShowEpisode", method: "list", version: 2, params: [
            "tvshow_id": String(show.id), "library_id": String(libraryID), "offset": "0", "limit": "1000",
            "additional": FSParam.strings(["summary", "file", "watched_ratio"]),
        ])
        return r.episodes.compactMap(\.value)
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    public func posterURL(for item: VideoItem, kind: VideoKind) throws -> URL {
        try authenticatedURL(api: "SYNO.VideoStation.Poster", method: "getimage", preferredVersion: 2, params: [
            "id": String(item.id), "type": kind.posterType,
        ])
    }

    // MARK: Watch progress

    /// Saved playback position of a file, in seconds; nil when never played.
    public func watchPosition(fileID: Int) async throws -> Double? {
        let r: [String: JSONValue] = try await call("SYNO.VideoStation.WatchStatus", method: "getinfo", version: 1,
                                                    params: ["id": String(fileID)])
        let status = r["watch_status"] ?? .object(r)
        guard let s = status["position"]?.string, let p = Double(s), p > 0 else { return nil }
        return p
    }

    /// Stores the position so Video Station (web, TV apps) and this app resume from the same place.
    public func saveWatchPosition(fileID: Int, position: Double) async throws {
        let _: EmptyData = try await call("SYNO.VideoStation.WatchStatus", method: "setinfo", version: 1, params: [
            "id": String(fileID), "position": String(Int(position.rounded())),
        ])
    }

    // MARK: Subtitles

    public func subtitles(fileID: Int) async throws -> [VideoSubtitle] {
        let r: JSONValue = try await call("SYNO.VideoStation.Subtitle", method: "list", version: 2,
                                          params: ["id": String(fileID)])
        let list = r.decode([VideoSubtitle].self) ?? r["subtitles"]?.decode([VideoSubtitle].self) ?? []
        return list.filter { !$0.id.isEmpty }
    }

    /// Subtitle files sitting next to `videoPath` (`name.srt`, `name.zh.ass`, …).
    public static func sidecarSubtitlePaths(videoPath: String, fileNames: [String]) -> [String] {
        let stem = ((videoPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = (videoPath as NSString).deletingLastPathComponent
        guard !stem.isEmpty else { return [] }
        let extensions = ["srt", "ass", "ssa", "vtt"]
        return fileNames.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { return false }
            let base = (name as NSString).deletingPathExtension.lowercased()
            let stemFolded = stem.lowercased()
            return base == stemFolded || base.hasPrefix(stemFolded + ".")
        }.map { dir == "/" ? "/\($0)" : "\(dir)/\($0)" }
    }

    public func sidecarSubtitles(near videoPath: String) async throws -> [VideoSubtitle] {
        let dir = (videoPath as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return [] }
        let files = try await listFolder(dir, limit: 3000).files.filter { !$0.isDirectory }
        return Self.sidecarSubtitlePaths(videoPath: videoPath, fileNames: files.map(\.name)).map { path in
            VideoSubtitle(id: path, title: (path as NSString).lastPathComponent,
                          format: (path as NSString).pathExtension, embedded: false)
        }
    }

    /// Downloads and parses a subtitle. Embedded tracks are extracted by Video Station, which can
    /// take a few seconds on large files. A path id is a sidecar file from File Station.
    public func subtitleTrack(fileID: Int, subtitle: VideoSubtitle) async throws -> SubtitleTrack {
        if subtitle.id.hasPrefix("/") { return try await textSubtitle(at: subtitle.id) }
        let url = try authenticatedURL(api: "SYNO.VideoStation.Subtitle", method: "get", preferredVersion: 2, params: [
            "id": String(fileID), "subtitle_id": subtitle.id, "preview": "false",
        ])
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        if let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
            throw DSMError.api(code: envelope.error?.code ?? 100, api: "SYNO.VideoStation.Subtitle")
        }
        guard let text = SubtitleTrack.decodeText(data) else { throw DSMError.invalidResponse }
        return SubtitleTrack.parse(text)
    }

    private func textSubtitle(at path: String) async throws -> SubtitleTrack {
        let url = try downloadURL(for: path)
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        guard let text = SubtitleTrack.decodeText(data) else { throw DSMError.invalidResponse }
        return SubtitleTrack.parse(text)
    }

    // MARK: Streaming

    /// A playable URL for `file`. `.original` is the File Station download URL (no transcoding).
    /// Other qualities open a Video Station HLS session; the request shape is inferred from the web
    /// client and still needs checking on a real NAS.
    public func videoStream(for file: VideoFile, quality: VideoQuality, audioTrack: Int? = nil) async throws -> VideoStream {
        if quality == .original {
            return VideoStream(url: try downloadURL(for: file.path), isHLS: false, streamID: nil, api: nil)
        }
        let api = "SYNO.VideoStation2.Streaming"
        var params: [String: String] = [
            "file": #"{"id":\#(file.id),"path":""}"#,
            "force_open": "true",
            "format": FSParam.string("hls"),
            "profile": FSParam.string(quality.profile),
        ]
        if let audioTrack { params["audio_track"] = String(audioTrack) }
        let r: [String: JSONValue] = try await call(api, method: "open", version: 1, params: params)
        guard let id = r["stream_id"]?.string?.nilIfEmpty else { throw DSMError.invalidResponse }
        let url = try authenticatedURL(api: api, method: "stream", preferredVersion: 1, params: [
            "stream_id": FSParam.string(id), "format": FSParam.string("hls"),
        ], pathSuffix: "/vte/playlist.m3u8")
        return VideoStream(url: url, isHLS: true, streamID: id, api: api)
    }

    /// Ends a transcoding session so the NAS stops encoding. No-op for original quality.
    public func closeVideoStream(_ stream: VideoStream) async {
        guard let id = stream.streamID, let api = stream.api else { return }
        _ = try? await call(api, method: "close", version: 1, params: [
            "stream_id": FSParam.string(id), "format": FSParam.string("hls"),
        ]) as EmptyData
    }
}
