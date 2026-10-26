import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DSMKit

final class VideoStationTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.FileStation.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.VideoStation.Movie":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.VideoStation.TVRecording":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.VideoStation.WatchStatus":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.VideoStation.Subtitle":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
         "SYNO.VideoStation2.Streaming":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testPlayOrderReadsEpisodeFromTitle() {
        XCTAssertEqual(videoPlayOrder(title: "S01E18", season: nil, episode: nil).episode, 18)
        XCTAssertEqual(videoPlayOrder(title: "S01E18", season: nil, episode: nil).season, 1)
        XCTAssertEqual(videoPlayOrder(title: "S1E2", season: nil, episode: nil).episode, 2)
        XCTAssertEqual(videoPlayOrder(title: "剧名 第18集", season: nil, episode: nil).episode, 18)
        XCTAssertEqual(videoPlayOrder(title: "第 3 集", season: 1, episode: nil).episode, 3)
        XCTAssertEqual(videoPlayOrder(title: "", season: nil, episode: nil).episode, 0)
        XCTAssertEqual(videoPlayOrder(title: "片头", season: nil, episode: nil).episode, 0)
        XCTAssertEqual(videoPlayOrder(title: "片头", season: 2, episode: 4).season, 2)
        XCTAssertEqual(videoPlayOrder(title: "片头", season: 2, episode: 4).episode, 4)
    }

    func testMovieDetailFields() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.VideoStation.Movie.list"] = #"""
        {"success":true,"data":{"total":42,"movies":[{"id":7,"title":"流浪地球","original_available":"2019-02-05","certificate":"PG-13",
          "additional":{"watched_ratio":0.4,"genre":[{"name":"科幻"}],"actor":[{"name":"吴京"}],"director":[{"name":"郭帆"}],
            "extra":"{\"com.synology.TheMovieDb\":{\"rating\":{\"themoviedb\":7.3}}}",
            "file":[{"id":9,"sharepath":"/video/流浪地球.mkv","filesize":"4000000000","duration":"7500.5",
                     "video_codec":"hevc","audio_codec":"aac","resolutionx":3840,"resolutiony":2160,"container_type":"matroska"}]}},
          {"id":"broken"}]}}
        """#
        let page = try await client.videoPage(.movie, sort: .title, ascending: true, keyword: "地球")
        let bodies = t.requests.compactMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } }
        XCTAssertTrue(bodies.contains { $0.contains("keyword") && $0.contains("SYNO.VideoStation.Movie") })
        XCTAssertEqual(page.total, 42)
        XCTAssertEqual(page.items.count, 1, "an undecodable item is skipped, not fatal")
        let movie = try XCTUnwrap(page.items.first)
        XCTAssertEqual(movie.genres, ["科幻"])
        XCTAssertEqual(movie.actors, ["吴京"])
        XCTAssertEqual(movie.directors, ["郭帆"])
        XCTAssertEqual(movie.rating, 7.3)
        XCTAssertTrue(movie.isInProgress)
        let file = try XCTUnwrap(movie.videoFiles.first)
        XCTAssertEqual(file.id, 9)
        XCTAssertEqual(file.size, 4_000_000_000)
        XCTAssertEqual(file.duration, 7500.5)
        XCTAssertEqual(file.resolutionLabel, "4K")
        XCTAssertEqual(file.fileExtension, "mkv")
        let form = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(form["sort_by"], "title")
        XCTAssertEqual(form["sort_direction"], "asc")
    }

    func testRecordingsAcceptOtherKey() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.VideoStation.TVRecording.list"] = #"""
        {"success":true,"data":{"total":1,"recordings":[{"id":3,"title":"新闻联播","additional":{"file":[{"id":5,"path":"/volume1/video/rec.ts"}]}}]}}
        """#
        let items = try await client.videos(.tvRecord)
        XCTAssertEqual(items.first?.files, ["/volume1/video/rec.ts"])
    }

    func testWatchStatus() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.VideoStation.WatchStatus.getinfo"] = #"{"success":true,"data":{"watch_status":{"position":1234}}}"#
        t.responses["SYNO.VideoStation.WatchStatus.setinfo"] = #"{"success":true}"#
        let position = try await client.watchPosition(fileID: 9)
        XCTAssertEqual(position, 1234)
        try await client.saveWatchPosition(fileID: 9, position: 99.6)
        let form = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(form["id"], "9")
        XCTAssertEqual(form["position"], "100")
    }

    func testSubtitleList() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.VideoStation.Subtitle.list"] = #"""
        {"success":true,"data":[{"id":"/volume1/video/a.chs.srt","title":"","lang":"chs","format":"srt","embedded":false},
                                {"id":2,"title":"English","lang":"eng","format":"subrip","embedded":true}]}
        """#
        let subs = try await client.subtitles(fileID: 9)
        XCTAssertEqual(subs.map(\.id), ["/volume1/video/a.chs.srt", "2"])
        XCTAssertEqual(subs[0].title, "chs")
        XCTAssertTrue(subs[1].embedded)
    }

    func testOriginalUsesFileStationAndTranscodeOpensSession() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        let file = VideoFile(id: 9, path: "/video/a.mkv")
        let raw = try await client.videoStream(for: file, quality: .original)
        XCTAssertFalse(raw.isHLS)
        XCTAssertTrue(raw.url.absoluteString.contains("SYNO.FileStation.Download"))

        t.responses["SYNO.VideoStation2.Streaming.open"] = #"{"success":true,"data":{"stream_id":"abc","format":"hls"}}"#
        let hls = try await client.videoStream(for: file, quality: .medium)
        XCTAssertTrue(hls.isHLS)
        XCTAssertEqual(hls.streamID, "abc")
        XCTAssertTrue(hls.url.path.hasSuffix(".m3u8"))
        let form = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(form["file"], #"{"id":9,"path":""}"#)
        XCTAssertEqual(form["profile"], #""hls_medium""#)
    }

    func testParseSRT() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>你好</i>\r\n世界\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nBye\r\n"
        let track = SubtitleTrack.parse(srt)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].text, "你好\n世界")
        XCTAssertEqual(track.cue(at: 2)?.text, "你好\n世界")
        XCTAssertNil(track.cue(at: 3.7))
        XCTAssertEqual(track.cue(at: 4.5)?.text, "Bye")
        XCTAssertNil(track.cue(at: 0.5))
    }

    func testParseVTT() {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nHi\n\n01:00:00.000 --> 01:00:01.000\nLate"
        let track = SubtitleTrack.parse(vtt)
        XCTAssertEqual(track.cues.map(\.start), [1, 3600])
        XCTAssertEqual(track.cue(at: 1.5)?.text, "Hi")
    }

    func testParseASS() {
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\an8}第一行\\N第二行, 带逗号
        """
        let track = SubtitleTrack.parse(ass)
        XCTAssertEqual(track.cues.count, 1)
        XCTAssertEqual(track.cues[0].end, 2.5)
        XCTAssertEqual(track.cues[0].text, "第一行\n第二行, 带逗号")
    }

    func testSidecarMatchesSameStemAndLanguageSuffix() {
        let paths = DSMClient.sidecarSubtitlePaths(videoPath: "/video/show.mkv",
                                                   fileNames: ["Show.srt", "show.zh.ass", "other.srt", "show.nfo", "note.txt"])
        XCTAssertEqual(paths, ["/video/Show.srt", "/video/show.zh.ass"])
    }
}
