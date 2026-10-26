import XCTest
@testable import DSMKit

final class PhotosLibraryTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.Foto.Browse.Album":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.Foto.Browse.NormalAlbum":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.Foto.Browse.Folder":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.Foto.Browse.Person":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.Foto.Browse.Geocoding":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.FotoTeam.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.FileStation.Upload":{"path":"entry.cgi","minVersion":1,"maxVersion":3}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testCategorySupportFollowsAPIInfo() async throws {
        let client = try await loggedIn(MockTransport())
        let person = await client.supportsPhotoCategory(.person, space: .personal)
        let tag = await client.supportsPhotoCategory(.tag, space: .personal)
        let sharedFolders = await client.supportsPhotoFolders(.shared)
        XCTAssertTrue(person)
        XCTAssertFalse(tag)
        XCTAssertFalse(sharedFolders)
    }

    func testPeopleAndPersonCover() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Foto.Browse.Person.list"] = #"""
        {"success":true,"data":{"list":[{"id":5,"name":"妈妈","item_count":120,"additional":{"thumbnail":{"cache_key":"5_99","unit_id":77}}},
          {"id":6,"name":"","item_count":"3"},{"id":7,"name":"空","item_count":0}]}}
        """#
        let people = try await client.photoGroups(.person, space: .personal)
        XCTAssertEqual(people.map(\.id), [5, 6])
        XCTAssertEqual(people[1].itemCount, 3)
        let sent = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(sent["show_more"], "true")
        let url = try await client.photoGroupCoverURL(people[0], category: .person, space: .personal)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["id"], "5")
        XCTAssertEqual(q["type"], #""person""#)
        let none = try await client.photoGroupCoverURL(people[1], category: .person, space: .personal)
        XCTAssertNil(none)
    }

    func testFilteredItemsAndFolderPath() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Foto.Browse.Item.list"] = #"""
        {"success":true,"data":{"list":[{"id":42,"filename":"IMG_1.JPG","filesize":1,"time":1700000000,"type":"photo","folder_id":9}]}}
        """#
        let items = try await client.photos(space: .personal, filter: .group(.place, 3))
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["geocoding_id"], "3")
        XCTAssertEqual(items[0].folderID, 9)

        t.responses["SYNO.Foto.Browse.Folder.get"] = #"{"success":true,"data":{"folder":{"id":9,"name":"/2024/旅行","parent":2}}}"#
        let path = try await client.photoFileStationPath(of: items[0], space: .personal)
        XCTAssertEqual(path, "/home/Photos/2024/旅行/IMG_1.JPG")
        XCTAssertEqual(PhotoSpace.shared.fileStationPath(of: "/"), "/photo")

        t.responses["SYNO.Foto.Browse.Folder.list"] = #"{"success":true,"data":{"list":[{"id":10,"name":"/2024/旅行/云南","parent":9}]}}"#
        let sub = try await client.photoSubfolders(space: .personal, of: 9)
        XCTAssertEqual(sub[0].name, "云南")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["id"], "9")
    }

    func testFavoritesAlbumCreatedAndUpdated() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Foto.Browse.Album.list"] = #"{"success":true,"data":{"list":[{"id":1,"name":"旅行","item_count":3}]}}"#
        let missing = try await client.favoritePhotoIDs()
        XCTAssertTrue(missing.isEmpty)

        t.responses["SYNO.Foto.Browse.NormalAlbum.create"] = #"{"success":true,"data":{"album":{"id":8,"name":"收藏","item_count":0}}}"#
        let album = try await client.favoritesAlbum(create: true)
        XCTAssertEqual(album?.id, 8)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["name"], #""收藏""#)

        t.responses["SYNO.Foto.Browse.NormalAlbum.add_item"] = #"{"success":true}"#
        try await client.addPhotos([42, 43], toAlbum: 8)
        let sent = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(sent["item"], "[42,43]")
        XCTAssertEqual(sent["id"], "8")
    }
}
