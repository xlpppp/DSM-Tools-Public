import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DSMKit
@testable import MediaKit

/// Replies by URL path and records requests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses[request.url!.path] ?? (404, "")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) { fatalError() }
}

final class JellyfinTests: XCTestCase {
    func testLoginLibrariesAndURLs() async throws {
        let t = StubTransport()
        t.responses["/Users/AuthenticateByName"] = (200, #"{"AccessToken":"TOK","User":{"Id":"U1","Name":"me"}}"#)
        t.responses["/Users/U1/Views"] = (200, #"{"Items":[{"Id":"L1","Name":"电影","CollectionType":"movies"},{"Id":"L2","Name":"音乐","CollectionType":"music"}]}"#)
        t.responses["/Users/U1/Items"] = (200, #"{"Items":[{"Id":"M1","Name":"Dune","Type":"Movie","IsFolder":false,"ProductionYear":2021,"RunTimeTicks":93000000000,"ImageTags":{"Primary":"abc"}}],"TotalRecordCount":1}"#)
        let account = ServiceAccount(kind: .jellyfin, name: "家", address: "192.0.2.5:8096/")
        let client = try JellyfinClient(account: account, transport: t, deviceID: "D1")
        try await client.login(username: "me", password: "pw")
        let login = t.requests[0]
        XCTAssertEqual(login.url?.absoluteString, "http://192.0.2.5:8096/Users/AuthenticateByName")
        XCTAssertTrue(login.value(forHTTPHeaderField: "X-Emby-Authorization")!.contains(#"DeviceId="D1""#))
        let body = try JSONSerialization.jsonObject(with: login.httpBody!) as! [String: String]
        XCTAssertEqual(body["Pw"], "pw")

        let libs = try await client.libraries()
        XCTAssertTrue(libs[1].isMusic)
        XCTAssertTrue(t.requests.last!.value(forHTTPHeaderField: "X-Emby-Authorization")!.contains(#"Token="TOK""#))
        let items = try await client.items(parent: "L1")
        XCTAssertEqual(items.first?.runtime, 9300)
        XCTAssertTrue(items.first!.hasPrimaryImage)
        XCTAssertTrue(items.first!.isPlayableVideo)
        let video = client.videoURL(for: items[0]).absoluteString
        XCTAssertTrue(video.hasPrefix("http://192.0.2.5:8096/Videos/M1/master.m3u8?"))
        XCTAssertTrue(video.contains("api_key=TOK"))
        XCTAssertTrue(video.contains("SegmentContainer=ts"))

        t.responses["/Items/M1/PlaybackInfo"] = (200, #"{"MediaSources":[{"Id":"MS","Container":"mkv","TranscodingUrl":"videos/M1/master.m3u8?PlaySessionId=P1"}],"PlaySessionId":"P1"}"#)
        let playback = try await client.playbackURL(for: items[0])
        XCTAssertEqual(playback.absoluteString, "http://192.0.2.5:8096/videos/M1/master.m3u8?PlaySessionId=P1")
    }

    func testEpisodeOrderUsesScrapedNumberThenFileName() {
        XCTAssertEqual(mediaEpisodeOrder(name: "命运逆转", fileName: "Show.S01E02.mkv").episode, 2)
        XCTAssertEqual(mediaEpisodeOrder(name: "第 18 集", episode: 18).episode, 18)
        XCTAssertEqual(mediaEpisodeOrder(name: "片头", fileName: "18.mkv", season: 1).episode, 18)
        XCTAssertEqual(mediaEpisodeOrder(name: "片头", fileName: "18.mkv", season: 1).season, 1)
    }

    func testEmbyUsesEmbyPrefixAndBadLogin() async throws {
        let t = StubTransport()
        t.responses["/emby/Users/AuthenticateByName"] = (401, "")
        let client = try JellyfinClient(account: ServiceAccount(kind: .emby, name: "e", address: "https://media.example.com"),
                                        transport: t, deviceID: "D")
        do {
            try await client.login(username: "a", password: "b")
            XCTFail("expected unauthorized")
        } catch let e as ServiceError {
            XCTAssertEqual(e, .unauthorized)
        }
        XCTAssertEqual(t.requests[0].url?.path, "/emby/Users/AuthenticateByName")
    }
}

final class SubsonicTests: XCTestCase {
    func testTokenAuthAlbumsAndFailure() async throws {
        let t = StubTransport()
        t.responses["/rest/getAlbumList2.view"] = (200, #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[{"id":"a1","name":"范特西","artist":"周杰伦","year":2001,"coverArt":"al-a1","songCount":10}]}}}"#)
        let account = ServiceAccount(kind: .navidrome, name: "n", address: "http://nas:4533", username: "me")
        let client = try SubsonicClient(account: account, password: "sesame", transport: t, salt: "c19b2d")
        let albums = try await client.albums()
        XCTAssertEqual(albums.first?.name, "范特西")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        // Example from the Subsonic API documentation: password "sesame", salt "c19b2d".
        XCTAssertEqual(q["t"], "26719a1196d2a940705a59634eb18eab")
        XCTAssertNil(q["p"])

        t.responses["/rest/ping.view"] = (200, #"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password"}}}"#)
        do {
            try await client.ping()
            XCTFail("expected unauthorized")
        } catch let e as ServiceError {
            XCTAssertEqual(e, .unauthorized)
        }
    }
}

final class ImmichTests: XCTestCase {
    func testKeyInHeaderNotURL() async throws {
        let t = StubTransport()
        t.responses["/api/users/me"] = (200, #"{"id":"u","name":"Alice","email":"a@x"}"#)
        t.responses["/api/search/metadata"] = (200, #"{"assets":{"items":[{"id":"x1","type":"VIDEO","originalFileName":"a.mov","fileCreatedAt":"2024-01-01T00:00:00Z"}],"nextPage":null}}"#)
        let client = try ImmichClient(account: ServiceAccount(kind: .immich, name: "i", address: "http://nas:2283"), apiKey: "K", transport: t)
        let name = try await client.me()
        XCTAssertEqual(name, "Alice")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "x-api-key"), "K")
        let assets = try await client.timeline()
        XCTAssertTrue(assets[0].isVideo)
        XCTAssertFalse(client.thumbnailURL("x1").absoluteString.contains("K"))
        XCTAssertEqual(client.thumbnailURL("x1").absoluteString, "http://nas:2283/api/assets/x1/thumbnail?size=thumbnail")
    }
}

final class ServiceAddressTests: XCTestCase {
    func testLegacyAddressIsKept() async {
        let account = ServiceAccount(kind: .emby, name: "e", address: "http://nas:8096")
        let chosen = await ServiceAccount.preferredAddress(account) { _, _ in true }
        XCTAssertEqual(chosen, "http://nas:8096")
    }

    func testLANWinsWhenItsPortIsOpen() async {
        let account = ServiceAccount(kind: .emby, name: "e", address: "http://wan:8096",
                                     lanAddress: "http://192.0.2.8:8096", wanAddress: "https://emby.example:443")
        let lanOpen = await ServiceAccount.preferredAddress(account) { host, _ in host == "192.0.2.8" }
        XCTAssertEqual(lanOpen, "http://192.0.2.8:8096")
        let wanOpen = await ServiceAccount.preferredAddress(account) { host, _ in host == "emby.example" }
        XCTAssertEqual(wanOpen, "https://emby.example:443")
    }

    func testOldJSONDecodesWithoutDualAddresses() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","kind":"emby","name":"e","address":"http://nas:8096","username":"a"}"#.utf8)
        let account = try JSONDecoder().decode(ServiceAccount.self, from: data)
        XCTAssertEqual(account.lanAddress, "")
        XCTAssertEqual(account.address, "http://nas:8096")
        XCTAssertNil(account.deviceID)
    }
}
