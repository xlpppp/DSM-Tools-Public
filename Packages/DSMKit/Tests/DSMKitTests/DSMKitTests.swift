import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DSMKit

/// Replies with canned JSON chosen by the `api` and `method` form fields, and records requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: String] = [:]
    var failure: Error?
    /// Overrides `responses` when it returns a body, for replies that depend on the parameters.
    var respond: (([String: String]) -> String?)?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let form = Self.fields(request)
        let key = "\(form["api"] ?? "").\(form["method"] ?? "")"
        let body = respond?(form) ?? responses[key] ?? #"{"success":false,"error":{"code":102}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    static func fields(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var out: [String: String] = [:]
        // Multipart uploads carry api/method in the URL query instead of the body.
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        for pair in body.split(separator: "&") where !body.hasPrefix("--") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            out[kv[0]] = kv.count > 1 ? kv[1].removingPercentEncoding : ""
        }
        return out
    }
}

let apiInfoDSM72 = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Core.System":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.Core.System.Utilization":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Storage.CGI.Storage":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Core.Package":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}
"""#

let apiInfoDSM62 = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":6},
 "SYNO.Core.System":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
"""#

final class DSMClientTests: XCTestCase {
    func makeClient(_ transport: MockTransport) -> DSMClient {
        DSMClient(baseURL: URL(string: "https://nas.local:5001")!, transport: transport)
    }

    func testLoginSendsCredentialsAndStoresSession() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1","synotoken":"T1"}}"#
        let client = makeClient(t)

        let result = try await client.login(account: "admin", password: "p&ss w=rd")

        XCTAssertEqual(result, LoginResult(sid: "S1", synoToken: "T1", deviceToken: nil))
        let login = MockTransport.fields(t.requests[1])
        XCTAssertEqual(t.requests[1].url?.absoluteString, "https://nas.local:5001/webapi/entry.cgi")
        XCTAssertEqual(login["passwd"], "p&ss w=rd")
        XCTAssertEqual(login["version"], "6", "capped at v6 even though DSM offers v7")
        XCTAssertNil(login["otp_code"])
    }

    func testOldDSMUsesItsOwnAuthPath() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM62
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S"}}"#
        _ = try await makeClient(t).login(account: "a", password: "b")
        XCTAssertEqual(t.requests[1].url?.path, "/webapi/auth.cgi")
    }

    func testAuthErrorsMapToFriendlyCases() async {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        let client = makeClient(t)

        for (code, expected) in [(400, DSMError.invalidCredentials), (403, .otpRequired), (404, .otpInvalid)] {
            t.responses["SYNO.API.Auth.login"] = #"{"success":false,"error":{"code":\#(code)}}"#
            do {
                _ = try await client.login(account: "a", password: "b")
                XCTFail("expected failure for \(code)")
            } catch {
                XCTAssertEqual(error as? DSMError, expected)
            }
        }
    }

    func testOTPLoginReturnsDeviceToken() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S","did":"DEV"}}"#
        let result = try await makeClient(t).login(account: "a", password: "b", otpCode: "123456")
        let login = MockTransport.fields(t.requests[1])
        XCTAssertEqual(login["otp_code"], "123456")
        XCTAssertEqual(login["enable_device_token"], "yes")
        XCTAssertEqual(result.deviceToken, "DEV")
    }

    func testAuthenticatedCallCarriesSidAndToken() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1","synotoken":"T1"}}"#
        t.responses["SYNO.Core.System.info"] = #"{"success":true,"data":{"model":"DS1621+","ram_size":32768,"cpu_cores":"4","up_time":"170:15:44:09","sys_temp":62}}"#
        let client = makeClient(t)
        _ = try await client.login(account: "a", password: "b")

        let info = try await client.systemInfo()

        let req = t.requests[2]
        XCTAssertEqual(MockTransport.fields(req)["_sid"], "S1")
        XCTAssertEqual(MockTransport.fields(req)["version"], "3")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-SYNO-TOKEN"), "T1")
        XCTAssertEqual(info.model, "DS1621+")
        XCTAssertEqual(info.ramMB, 32768)
        XCTAssertEqual(info.cpuCores, 4)
        XCTAssertEqual(info.upTimeDays, 170)
        XCTAssertEqual(info.temperature, 62)
    }

    func testVersionIsLoweredForOldDSM() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM62
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S"}}"#
        t.responses["SYNO.Core.System.info"] = #"{"success":true,"data":{"model":"DS918+"}}"#
        let client = makeClient(t)
        _ = try await client.login(account: "a", password: "b")
        _ = try await client.systemInfo()
        XCTAssertEqual(MockTransport.fields(t.requests[2])["version"], "1")
    }

    func testMissingAPIIsReportedNotCalled() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM62
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S"}}"#
        let client = makeClient(t)
        _ = try await client.login(account: "a", password: "b")
        do {
            _ = try await client.utilization()
            XCTFail("expected apiUnavailable")
        } catch {
            XCTAssertEqual(error as? DSMError, .apiUnavailable("SYNO.Core.System.Utilization"))
            XCTAssertEqual(t.requests.count, 2)
        }
    }

    func testSessionTimeoutClearsSession() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S"}}"#
        t.responses["SYNO.Core.System.Utilization.get"] = #"{"success":false,"error":{"code":119}}"#
        let client = makeClient(t)
        _ = try await client.login(account: "a", password: "b")
        _ = try? await client.utilization()
        let loggedIn = await client.isLoggedIn
        XCTAssertFalse(loggedIn)
    }
}

final class ModelDecodingTests: XCTestCase {
    func testUtilizationDecodesDSM7Payload() throws {
        let json = #"""
        {"cpu":{"user_load":15,"system_load":6,"other_load":2,"1min_load":76},
         "memory":{"real_usage":31,"total_real":32505856,"avail_real":22000000,"cached":15900000},
         "network":[{"device":"total","rx":9830,"tx":43724},{"device":"eth0","rx":9830,"tx":43724}],
         "disk":{"total":{"read_byte":0,"write_byte":3670016,"utilization":3}}}
        """#
        let u = try JSONDecoder().decode(Utilization.self, from: Data(json.utf8))
        XCTAssertEqual(u.cpuPercent, 23)
        XCTAssertEqual(u.memoryPercent, 31)
        XCTAssertEqual(u.networkRxBytesPerSec, 9830)
        XCTAssertEqual(u.networkTxBytesPerSec, 43724)
        XCTAssertEqual(u.diskWriteBytesPerSec, 3670016)
    }

    func testUtilizationSumsInterfacesWithoutTotal() throws {
        let json = #"{"cpu":{"user_load":"1"},"network":[{"device":"eth0","rx":10,"tx":1},{"device":"eth1","rx":5,"tx":2}]}"#
        let u = try JSONDecoder().decode(Utilization.self, from: Data(json.utf8))
        XCTAssertEqual(u.cpuPercent, 1)
        XCTAssertEqual(u.networkRxBytesPerSec, 15)
        XCTAssertEqual(u.networkTxBytesPerSec, 3)
    }

    func testUtilizationDecodesLoadAndMemoryStructure() throws {
        let json = #"""
        {"cpu":{"user_load":10,"system_load":6,"other_load":2,"1min_load":87,"5min_load":180,"15min_load":"182"},
         "memory":{"real_usage":43,"memory_size":33554432,"total_real":32729088,"avail_real":423424,
                   "buffer":39424,"cached":18140364,"swap_usage":1,"total_swap":6291452},
         "network":[{"device":"total","rx":12005,"tx":6661},{"device":"eth0","rx":12000,"tx":6600},{"device":"eth1","rx":5,"tx":61}],
         "disk":{"total":{"read_byte":6144,"write_byte":2118123,"utilization":4}}}
        """#
        let u = try JSONDecoder().decode(Utilization.self, from: Data(json.utf8))
        XCTAssertEqual(u.cpuPercent, 18)
        XCTAssertEqual(u.cpuOther, 2)
        XCTAssertEqual(u.load1, 0.87)
        XCTAssertEqual(u.load5, 1.8)
        XCTAssertEqual(u.load15, 1.82)
        XCTAssertEqual(u.memoryReservedKB, 33554432 - 32729088)
        XCTAssertEqual(u.memoryUsedKB, 32729088 - 423424 - 39424 - 18140364)
        XCTAssertEqual(u.interfaces.map(\.device), ["eth0", "eth1"])
        XCTAssertEqual(u.diskUtilization, 4)
    }

    func testLoadAverageAcceptsUnscaledFraction() throws {
        let u = try JSONDecoder().decode(Utilization.self, from: Data(#"{"cpu":{"1min_load":0.5}}"#.utf8))
        XCTAssertEqual(u.load1, 0.5)
        XCTAssertNil(u.load5)
    }

    func testProcessListDecodesAndSortsByCPU() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = #"{"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},"SYNO.Core.System.Process":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"s"}}"#
        t.responses["SYNO.Core.System.Process.list"] = #"""
        {"success":true,"data":{"process":[
          {"pid":14070,"command":"gitea","status":"S","cpu":10,"mem":101990,"mem_shared":39219},
          {"pid":527,"command":"qemu-system-x86_64","status":"R","cpu":48,"mem":113868,"mem_shared":4194304},
          {"pid":"9","command":"zombie","status":"Z","cpu":"0"}]}}
        """#
        let client = DSMClient(baseURL: URL(string: "https://nas.local:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        let list = try await client.processes()
        XCTAssertEqual(list.map(\.pid), [527, 14070, 9])
        XCTAssertEqual(list[0].cpuPercent, 4.8, accuracy: 0.001)
        XCTAssertEqual(list[0].statusLabel, "运行中")
        XCTAssertEqual(list[0].sharedMemoryKB, 4194304)
        XCTAssertEqual(list[2].statusLabel, "僵尸")
    }

    func testServiceUsageAcceptsAlternateKeys() throws {
        let json = #"""
        {"slice":[{"name":"SMB","cpu_utilization":0,"cpu_time":"46:03","memory":20890,"pids":[1,2]},
                  {"display_name":"DSM 桌面","cpu_utilization":10,"cpu_time":6014,"memory":33485}]}
        """#
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let rows = data.rows(["process_group"]).compactMap(ServiceUsage.init)
        XCTAssertEqual(rows.map(\.name), ["SMB", "DSM 桌面"])
        XCTAssertEqual(rows[0].cpuTimeSeconds, 46 * 60 + 3)
        XCTAssertEqual(rows[0].processCount, 2)
        XCTAssertEqual(rows[1].cpuPercent, 1.0)
    }

    func testStorageFlagsUnhealthyDisks() throws {
        let json = #"""
        {"volumes":[{"id":"volume_1","vol_path":"/volume1","status":"normal","size":{"total":"67000000000000","used":"64000000000000"}}],
         "disks":[{"id":"sata1","name":"Drive 1","model":"ST16000NM000J-2TW103 ","vendor":"Seagate","status":"normal","smart_status":"normal","temp":46,"size_total":"16000900661248"},
                  {"id":"sata2","name":"Drive 2","model":"X","status":"warning","smart_status":"failing","temp":"49","size_total":"1"}]}
        """#
        let s = try JSONDecoder().decode(StorageOverview.self, from: Data(json.utf8))
        XCTAssertEqual(s.volumes.first?.name, "volume1")
        XCTAssertEqual(s.usedBytes, 64_000_000_000_000)
        XCTAssertEqual(s.disks.first?.model, "ST16000NM000J-2TW103")
        XCTAssertEqual(s.unhealthyDisks.map(\.id), ["sata2"])
        XCTAssertEqual(s.disks.last?.temperature, 49)
    }

    func testStorageDecodesPoolsAndDiskDetail() throws {
        let json = #"""
        {"volumes":[],
         "storagePools":[{"id":"reuse_1","num_id":1,"device_type":"shr_without_disk_protect","status":"normal",
                          "size":{"total":"100","used":"40"},"disks":["sata1","sata2"]},
                         {"id":"reuse_2","num_id":2,"device_type":"raid_5","status":"degrade","size":{"total":"1","used":"1"}}],
         "disks":[{"id":"sata1","serial":" ZL0 ","firm":"SN03","diskType":"SATA","remain_life":{"value":-1},"unc":3,"used_by":"reuse_1"},
                  {"id":"nvme1","remain_life":97}]}
        """#
        let s = try JSONDecoder().decode(StorageOverview.self, from: Data(json.utf8))
        XCTAssertEqual(s.pools.map(\.raidLabel), ["SHR（无容错）", "RAID 5"])
        XCTAssertEqual(s.pools[0].name, "存储池 1")
        XCTAssertEqual(s.pools[0].diskIDs, ["sata1", "sata2"])
        XCTAssertEqual(s.disks[0].serial, "ZL0")
        XCTAssertNil(s.disks[0].remainingLife)
        XCTAssertEqual(s.disks[0].badSectors, 3)
        XCTAssertEqual(s.disks[0].poolID, "reuse_1")
        XCTAssertEqual(s.disks[1].remainingLife, 97)
    }
}

final class EndpointTests: XCTestCase {
    func testDefaultPortsFollowScheme() {
        XCTAssertEqual(Endpoint(kind: .lan, host: " nas.local ").display, "https://nas.local:5001")
        XCTAssertEqual(Endpoint(kind: .lan, host: "192.0.2.2", useHTTPS: false).display, "http://192.0.2.2:5000")
    }

    func testFingerprintNormalization() {
        XCTAssertEqual("ab cd:ef01".normalizedFingerprint, "AB:CD:EF:01")
    }

    func testResolverPrefersFirstReachableInOrder() async throws {
        let lan = Endpoint(kind: .lan, host: "lan.example")
        let wan = Endpoint(kind: .wan, host: "wan.example")
        let resolver = EndpointResolver(makeTransport: { endpoint in
            let t = MockTransport()
            if endpoint.host == "lan.example" {
                t.failure = DSMError.unreachable
            } else {
                t.responses["SYNO.API.Info.query"] = apiInfoDSM72
            }
            return t
        }, probe: { _, _ in true })
        let picked = try await resolver.resolve([lan, wan])
        XCTAssertEqual(picked.endpoint, wan)

        let both = EndpointResolver(makeTransport: { _ in
            let t = MockTransport()
            t.responses["SYNO.API.Info.query"] = apiInfoDSM72
            return t
        }, probe: { _, _ in true })
        let first = try await both.resolve([lan, wan])
        XCTAssertEqual(first.endpoint, lan)
    }

    func testResolverReportsCertificateProblem() async {
        let ep = Endpoint(kind: .lan, host: "nas")
        let resolver = EndpointResolver(makeTransport: { _ in
            let t = MockTransport()
            t.failure = DSMError.untrustedCertificate(host: "nas", fingerprint: "AA:BB")
            return t
        }, probe: { _, _ in true })
        do {
            _ = try await resolver.resolve([ep, Endpoint(kind: .wan, host: "x")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DSMError, .untrustedCertificate(host: "nas", fingerprint: "AA:BB"))
        }
    }
}

let apiInfoFS = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
 "SYNO.FileStation.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
 "SYNO.FileStation.Delete":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
 "SYNO.FileStation.Upload":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.FileStation.Sharing":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.FileStation.Search":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}
"""#

final class FileStationTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoFS
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1","synotoken":"T1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testListFolderEncodesParamsAsJSONAndDecodesFiles() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.List.list"] = #"""
        {"success":true,"data":{"total":2,"offset":0,"files":[
          {"isdir":true,"name":"docker","path":"/home/docker","additional":{"size":0,"time":{"mtime":1727515051}}},
          {"isdir":false,"name":"a, b.log","path":"/home/a, b.log","additional":{"size":"3220","time":{"mtime":"1739602200"},"real_path":"/volume1/home/a, b.log"}}]}}
        """#
        let listing = try await client.listFolder("/home/a, b", sort: .mtime, ascending: false)

        let f = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(f["folder_path"], #""/home/a, b""#)
        XCTAssertEqual(f["sort_by"], #""mtime""#)
        XCTAssertEqual(f["sort_direction"], #""desc""#)
        XCTAssertEqual(f["additional"], #"["real_path","size","time","type"]"#)
        XCTAssertEqual(listing.total, 2)
        XCTAssertEqual(listing.files[0].kind, .folder)
        XCTAssertEqual(listing.files[1].kind, .text)
        XCTAssertEqual(listing.files[1].size, 3220)
        XCTAssertEqual(listing.files[1].modified, Date(timeIntervalSince1970: 1739602200))
    }

    func testDownloadURLCarriesSessionAndJSONPath() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        let url = try await client.downloadURL(for: "/music/凤凰传奇.wav")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(comps.path, "/webapi/entry.cgi")
        XCTAssertEqual(q["path"], #"["/music/凤凰传奇.wav"]"#)
        XCTAssertEqual(q["mode"], #""open""#)
        XCTAssertEqual(q["_sid"], "S1")
        XCTAssertEqual(q["version"], "2")
    }

    func testDownloadFileKeepsRemoteName() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.Download.download"] = "hello log"
        let file = try await client.downloadFile(at: "/docker/app/run.log")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "run.log")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello log")
    }

    func testDeletePollsUntilFinished() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.Delete.start"] = #"{"success":true,"data":{"taskid":"FileStation_1"}}"#
        t.responses["SYNO.FileStation.Delete.status"] = #"{"success":true,"data":{"finished":true}}"#
        try await client.delete(["/home/x", "/home/y"])
        let start = MockTransport.fields(t.requests[2])
        XCTAssertEqual(start["path"], #"["/home/x","/home/y"]"#)
        XCTAssertEqual(MockTransport.fields(t.requests[3])["taskid"], #""FileStation_1""#)
    }

    func testSearchPollsListThenCleansUp() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.Search.start"] = #"{"success":true,"data":{"taskid":"S_1"}}"#
        t.responses["SYNO.FileStation.Search.list"] = #"""
        {"success":true,"data":{"finished":true,"total":1,"files":[
          {"isdir":false,"name":"凤凰传奇.wav","path":"/music/凤凰传奇.wav","additional":{"size":"1024"}}]}}
        """#
        t.responses["SYNO.FileStation.Search.stop"] = #"{"success":true}"#
        t.responses["SYNO.FileStation.Search.clean"] = #"{"success":true}"#
        let files = try await client.searchFiles("凤凰", in: ["/music", "/video"])

        XCTAssertEqual(files.map(\.name), ["凤凰传奇.wav"])
        let start = MockTransport.fields(t.requests[2])
        XCTAssertEqual(start["method"], "start")
        XCTAssertEqual(start["folder_path"], #"["/music","/video"]"#)
        XCTAssertEqual(start["pattern"], #""凤凰""#)
        let methods = t.requests.dropFirst(3).map { MockTransport.fields($0)["method"] ?? "" }
        XCTAssertEqual(methods, ["list", "stop", "clean"])
        XCTAssertEqual(MockTransport.fields(t.requests[3])["taskid"], #""S_1""#)
    }

    func testShareLink() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.Sharing.create"] = #"{"success":true,"data":{"links":[{"id":"abc","url":"https://gofile.me/x/abc","qrcode":"..."}]}}"#
        let link = try await client.createShareLink(for: "/video/a.mp4")
        XCTAssertEqual(link.url, "https://gofile.me/x/abc")
    }

    func testUploadBuildsMultipartBody() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.FileStation.Upload.upload"] = #"{"success":true}"#
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: local)

        try await client.upload(fileAt: local, to: "/home/up")

        let req = t.requests.last!
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(q.contains(URLQueryItem(name: "_sid", value: "S1")))
        XCTAssertTrue(q.contains(URLQueryItem(name: "version", value: "2")))
        let body = String(data: req.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("name=\"path\"\r\n\r\n/home/up\r\n"))
        XCTAssertTrue(body.contains("filename=\"hello.txt\""))
        XCTAssertTrue(body.contains("\r\n\r\nhello\r\n--"))
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind.of(name: "A.FLAC", isDirectory: false), .audio)
        XCTAssertEqual(FileKind.of(name: "x.mkv", isDirectory: false), .video)
        XCTAssertEqual(FileKind.of(name: "x.cue", isDirectory: false), .text)
        XCTAssertEqual(FileKind.of(name: "x", isDirectory: true), .folder)
    }
}

let apiInfoLogs = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Core.SyslogClient.Log":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Storage.CGI.Storage":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
"""#

final class LogCenterTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoLogs
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    let logJSON = #"""
    {"success":true,"data":{"total":2,"warnCount":1,"errorCount":1,"items":[
      {"level":"err","time":"2026/10/19 08:30:12","who":"SYSTEM","orginalLogType":"system","descr":"Volume 1 degraded"},
      {"level":"warn","time":"2026/10/01 08:00:00","who":"admin","logtype":"connection","descr":"Failed login"}]}}
    """#

    func testLogsDecodeAndSendFilters() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Core.SyslogClient.Log.list"] = logJSON
        let page = try await client.logs(category: .connection, level: .warning, keyword: "login", offset: 50)
        let sent = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(sent["logtype"], "connection")
        XCTAssertEqual(sent["level"], "warn")
        XCTAssertEqual(sent["start"], "50")
        XCTAssertEqual(sent["keyword"], "login")
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.errorCount, 1)
        XCTAssertEqual(page.entries.map(\.level), [.error, .warning])
        XCTAssertEqual(page.entries[0].category, "system")
        XCTAssertEqual(page.entries[1].category, "connection")
        XCTAssertNotNil(page.entries[0].time)
    }

    func testScanHealthReportsDisksFullVolumesAndNewErrors() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Storage.CGI.Storage.load_info"] = #"""
        {"success":true,"data":{"volumes":[{"id":"volume_1","vol_path":"/volume1","status":"normal","size":{"total":"100","used":"95"}}],
         "disks":[{"id":"sata2","name":"Drive 2","status":"warning","smart_status":"failing"}]}}
        """#
        t.responses["SYNO.Core.SyslogClient.Log.list"] = logJSON
        let since = LogEntry.parseTime("2026/10/10 00:00:00")
        let alerts = await client.scanHealth(since: since)
        XCTAssertEqual(alerts.first?.severity, .critical)
        XCTAssertTrue(alerts.contains { $0.id == "disk-sata2" })
        XCTAssertTrue(alerts.contains { $0.id == "full-volume_1" })
        // Only the error newer than `since` counts.
        XCTAssertEqual(alerts.filter { $0.id.hasPrefix("log-") }.count, 1)
    }
}

let apiInfoDS = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.DownloadStation.Task":{"path":"DownloadStation/task.cgi","minVersion":1,"maxVersion":3},
 "SYNO.DownloadStation.Statistic":{"path":"DownloadStation/statistic.cgi","minVersion":1,"maxVersion":1}}}
"""#

final class DownloadStationTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoDS
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testListDecodesTransferAndProgress() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.DownloadStation.Task.list"] = #"""
        {"success":true,"data":{"total":2,"offset":0,"tasks":[
          {"id":"dbid_1","type":"bt","title":"ubuntu.iso","size":1000,"status":"downloading","username":"a",
           "additional":{"detail":{"destination":"downloads","uri":"magnet:?x","create_time":1700000000},
                         "transfer":{"size_downloaded":250,"size_uploaded":"10","speed_download":75,"speed_upload":0}}},
          {"id":"dbid_2","type":"http","title":"bad","size":"0","status":"error","status_extra":{"error_detail":"broken_link"}}]}}
        """#
        let tasks = try await client.downloadTasks()
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["additional"], "detail,transfer")
        XCTAssertEqual(t.requests.last!.url?.path, "/webapi/DownloadStation/task.cgi")
        XCTAssertEqual(tasks[0].status, .downloading)
        XCTAssertEqual(tasks[0].progress, 0.25)
        XCTAssertEqual(tasks[0].remaining, 10)
        XCTAssertEqual(tasks[0].destination, "downloads")
        XCTAssertEqual(tasks[1].status, .error)
        XCTAssertEqual(tasks[1].errorDetail, "broken_link")
    }

    func testCreateAndActions() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.DownloadStation.Task.create"] = #"{"success":true}"#
        try await client.addDownloads(["magnet:?a", "https://x/y.iso"], destination: "/downloads/iso")
        let sent = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(sent["uri"], "magnet:?a,https://x/y.iso")
        XCTAssertEqual(sent["destination"], "downloads/iso")

        t.responses["SYNO.DownloadStation.Task.pause"] = #"{"success":true,"data":[{"id":"dbid_1","error":0}]}"#
        try await client.pauseDownloads(["dbid_1"])
        t.responses["SYNO.DownloadStation.Task.delete"] = #"{"success":true,"data":[{"id":"dbid_1","error":405}]}"#
        do {
            try await client.deleteDownloads(["dbid_1"])
            XCTFail("expected per-task error")
        } catch DSMError.api(let code, _) {
            XCTAssertEqual(code, 405)
        }
    }
}

final class PackageCenterTests: XCTestCase {
    func testInstalledPackagesDecodeAndSort() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = apiInfoDSM72
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        t.responses["SYNO.Core.Package.list"] = #"""
        {"success":true,"data":{"total":2,"packages":[
          {"id":"WebStation","name":"Web Station","version":"4.0.0-0100","additional":{"status":"stop","startable":true}},
          {"id":"ContainerManager","name":"Container Manager","version":"24.0.2-1543","additional":{"description":"Docker","status":"running","startable":true}}]}}
        """#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        let packages = try await client.installedPackages()
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["additional"], #"["description","status","startable"]"#)
        XCTAssertEqual(packages.map(\.id), ["ContainerManager", "WebStation"])
        XCTAssertTrue(packages[0].isRunning)
        XCTAssertEqual(packages[1].statusLabel, "已停止")
    }

    func testCatalogAndVersionCompare() throws {
        let json = #"{"id":"ContainerManager","dname":"Container Manager","version":"24.0.2-1606","thumbnail":["https://cdn/a_72.png","https://cdn/a_256.png"],"category":["utilities"]}"#
        let p = try JSONDecoder().decode(CatalogPackage.self, from: Data(json.utf8))
        XCTAssertEqual(p.iconURL?.absoluteString, "https://cdn/a_256.png")
        XCTAssertTrue(isNewerVersion("24.0.2-1606", than: "24.0.2-1543"))
        XCTAssertFalse(isNewerVersion("24.0.2", than: "24.0.2-0000"))
        XCTAssertTrue(isNewerVersion("3.10.0", than: "3.9.9"))
    }
}

let apiInfoDocker = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Docker.Container":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Docker.Container.Resource":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Docker.Container.Log":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Docker.Project":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
"""#

final class DockerTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoDocker
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testContainersAndActions() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Container.list"] = #"""
        {"success":true,"data":{"containers":[
          {"name":"nginx","id":"abc","image":"nginx:latest","status":"running","up_status":"Up 2 days","created":1700000000,
           "ports":[{"host_port":8080,"container_port":80,"type":"tcp"}]},
          {"name":"emby","image":"emby/embyserver","status":"stopped"}],"total":2}}
        """#
        let list = try await client.containers()
        XCTAssertEqual(list.map(\.name), ["emby", "nginx"])
        XCTAssertEqual(list[1].ports.first?.display, "8080 → 80/tcp")
        XCTAssertTrue(list[1].isRunning)

        t.responses["SYNO.Docker.Container.restart"] = #"{"success":true}"#
        try await client.restartContainer("nginx")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["name"], #""nginx""#)
    }

    func testProfileEditKeepsUnknownFields() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Container.get"] = #"""
        {"success":true,"data":{"details":{},"profile":{"name":"app","image":"app:1","cmd":"","shortcut":{"enable_web_page":true},
          "env_variables":[{"key":"DB_PASSWORD","value":"s3cret"},{"key":"TZ","value":"Asia/Shanghai"}],
          "port_bindings":[{"host_port":"8080","container_port":"80","type":"tcp"}],
          "volume_bindings":[{"host_volume_file":"/docker/app","mount_point":"/data","type":"rw"}],
          "network":[{"name":"bridge","driver":"bridge"}],"enable_restart_policy":false,"memory_limit":0,"cpu_priority":50}}}
        """#
        var profile = try await client.containerProfile("app")
        XCTAssertEqual(profile.env.first?.isSensitive, true)
        XCTAssertEqual(profile.env.last?.isSensitive, false)
        XCTAssertEqual(profile.ports, [PortBinding(hostPort: 8080, containerPort: 80)])
        XCTAssertEqual(profile.volumes.first?.mountPoint, "/data")
        XCTAssertEqual(profile.networks, ["bridge"])
        XCTAssertEqual(profile.cpuPriority, 50)

        profile.autoRestart = true
        profile.env.append(EnvVariable(key: "NEW", value: "1"))
        profile.ports[0].hostPort = 9090
        t.responses["SYNO.Docker.Container.set"] = #"{"success":true}"#
        try await client.updateContainer("app", profile: profile)

        let sent = MockTransport.fields(t.requests.last!)
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(sent["profile"]!.utf8))
        XCTAssertEqual(saved["enable_restart_policy"], .bool(true))
        XCTAssertEqual(saved["shortcut"]?["enable_web_page"], .bool(true))
        XCTAssertEqual(saved["env_variables"]?.array?.count, 3)
        XCTAssertEqual(saved["port_bindings"]?.array?.first?["host_port"], .number(9090))
        XCTAssertTrue(sent["profile"]!.contains(#""cpu_priority":50"#))
    }

    func testResourcesLogsAndProjects() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Container.Resource.get"] = #"{"success":true,"data":{"resources":[{"name":"nginx","cpu":1.5,"memory":"10485760","memoryPercent":"0.5"}]}}"#
        let r = try await client.containerResources()
        XCTAssertEqual(r.first?.cpuPercent, 1.5)
        XCTAssertEqual(r.first?.memoryBytes, 10_485_760)
        XCTAssertEqual(r.first?.memoryPercent, 0.5)

        t.responses["SYNO.Docker.Container.Log.get"] = #"{"success":true,"data":{"logs":[{"created":"2026-10-19T08:00:00Z","stream":"stderr","text":"boom"}],"total":1}}"#
        let logs = try await client.containerLogs("nginx")
        XCTAssertTrue(logs.lines[0].isError)

        t.responses["SYNO.Docker.Project.list"] = #"{"success":true,"data":{"p1":{"id":"p1","name":"immich","path":"/docker/immich","status":"RUNNING","containerIds":["a","b"]}}}"#
        let projects = try await client.dockerProjects()
        XCTAssertEqual(projects.first?.containerCount, 2)
        XCTAssertTrue(projects.first!.isRunning)

        t.responses["SYNO.Docker.Project.stop_stream"] = "stopping...\ndone"
        try await client.stopProject("p1")
    }

    func testLogsFallBackToQuotedParametersOn114() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.respond = { form in
            guard form["api"] == "SYNO.Docker.Container.Log" else { return nil }
            return form["name"] == #""nginx""#
                ? #"{"success":true,"data":{"logs":[{"created":1760860800,"stream":"stdout","text":"ok"}],"total":"1"}}"#
                : #"{"success":false,"error":{"code":114}}"#
        }
        let logs = try await client.containerLogs("nginx")
        XCTAssertEqual(logs.lines.first?.text, "ok")
        XCTAssertEqual(logs.lines.first?.created, "1760860800")
        XCTAssertEqual(logs.total, 1)
        let sent = t.requests.map(MockTransport.fields).filter { $0["api"] == "SYNO.Docker.Container.Log" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["name"], "nginx")
        XCTAssertNil(sent[0]["from"])
    }

    func testLogsDoNotRetryOnPermissionError() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Container.Log.get"] = #"{"success":false,"error":{"code":105}}"#
        do {
            _ = try await client.containerLogs("nginx")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DSMError, .api(code: 105, api: "SYNO.Docker.Container.Log"))
        }
        XCTAssertEqual(t.requests.filter { MockTransport.fields($0)["api"] == "SYNO.Docker.Container.Log" }.count, 1)
    }

    func testComposeProjectDetailUpdateAndFallbacks() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Project.get"] = #"""
        {"success":true,"data":{"id":"p1","name":"immich","share_path":"/docker/immich","status":"STOPPED",
         "content":"services:\n  app:\n    image: nginx\n","containers":[{"name":"immich_server"},"immich_redis"]}}
        """#
        let detail = try await client.projectDetail("p1")
        XCTAssertEqual(detail.path, "/docker/immich")
        XCTAssertEqual(detail.containers, ["immich_server", "immich_redis"])
        XCTAssertTrue(detail.content.contains("image: nginx"))
        XCTAssertFalse(detail.isRunning)

        t.responses["SYNO.Docker.Project.update"] = #"{"success":true}"#
        try await client.updateProject("p1", content: "services: {}")
        let update = t.requests.map(MockTransport.fields).last { $0["method"] == "update" }
        XCTAssertEqual(update?["content"], "services: {}")

        // No build_stream on this build: falls back to the plain method.
        t.responses["SYNO.Docker.Project.build_stream"] = #"{"success":false,"error":{"code":103}}"#
        t.responses["SYNO.Docker.Project.build"] = #"{"success":true}"#
        try await client.buildProject("p1")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["method"], "build")

        t.responses["SYNO.Docker.Project.delete"] = #"{"success":true}"#
        try await client.deleteProject("p1")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["preserve_content"], "true")
    }
}

final class VirtualMachineTests: XCTestCase {
    func testListAndPowerActions() async throws {
        let t = MockTransport()
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.Virtualization.API.Guest":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.Virtualization.API.Guest.Action":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        t.responses["SYNO.Virtualization.API.Guest.list"] = #"""
        {"success":true,"data":{"guests":[
          {"guest_id":"g2","guest_name":"Windows 11","status":"shutdown","vcpu_num":4,"vram_size":8192,"autorun":0,
           "vdisks":[{"vdisk_size":65536}],"vnics":[{"mac":"02:11:32:aa:bb:cc","model":1}]},
          {"guest_id":"g1","guest_name":"OpenWrt","status":"running","vcpu_num":"1","vram_size":"512","autorun":1}]}}
        """#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        let vms = try await client.virtualMachines()
        XCTAssertEqual(vms.map(\.name), ["OpenWrt", "Windows 11"])
        XCTAssertTrue(vms[0].isRunning)
        XCTAssertEqual(vms[0].autorun, true)
        XCTAssertEqual(vms[1].memoryMB, 8192)
        XCTAssertEqual(vms[1].disks.first?.sizeMB, 65536)
        XCTAssertEqual(vms[1].nics.first?.model, "1")

        t.responses["SYNO.Virtualization.API.Guest.Action.shutdown"] = #"{"success":true}"#
        try await client.shutdownVM("g1")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["guest_id"], "g1")
        XCTAssertEqual(client.vmManagerURL()?.absoluteString, "https://nas:5001/?launchApp=SYNO.SDS.Virtualization.Application")
    }
}

final class MediaTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":4},
         "SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
         "SYNO.AudioStation.Song":{"path":"AudioStation/song.cgi","minVersion":1,"maxVersion":3},
         "SYNO.AudioStation.Stream":{"path":"AudioStation/stream.cgi","minVersion":1,"maxVersion":2},
         "SYNO.VideoStation.Movie":{"path":"entry.cgi","minVersion":1,"maxVersion":4}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testPhotosAndThumbnailURL() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Foto.Browse.Item.list"] = #"""
        {"success":true,"data":{"list":[{"id":42,"filename":"IMG_1.HEIC","filesize":2048,"time":1700000000,"type":"photo",
          "additional":{"thumbnail":{"m":"ready","xl":"ready","cache_key":"42_1700000001","unit_id":42},"resolution":{"width":4032,"height":3024}}},
          {"id":43,"filename":"v.mov","filesize":"9","time":1700000100,"type":"video","additional":{"thumbnail":{"cache_key":"43_1"}}}]}}
        """#
        let items = try await client.photos()
        XCTAssertEqual(items.map(\.id), [42, 43])
        XCTAssertEqual(items[0].width, 4032)
        XCTAssertTrue(items[1].isVideo)
        let url = try await client.photoThumbnailURL(id: 42, cacheKey: items[0].cacheKey!, size: .small)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["cache_key"], #""42_1700000001""#)
        XCTAssertEqual(q["size"], #""sm""#)
        XCTAssertEqual(q["_sid"], "S1")
    }

    func testSongsAndStreamURL() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.AudioStation.Song.list"] = #"""
        {"success":true,"data":{"total":2,"songs":[
          {"id":"music_1","title":"","path":"/music/a/01 晴天.flac","additional":{"song_tag":{"artist":"周杰伦","album":"叶惠美","track":1},"song_audio":{"duration":269,"codec":"flac","bitrate":900000}}},
          {"id":"music_2","title":"Old","path":"/music/b.ape","additional":{"song_audio":{"codec":"ape"}}}]}}
        """#
        let songs = try await client.songs()
        XCTAssertEqual(songs[0].title, "01 晴天")
        XCTAssertEqual(songs[0].artist, "周杰伦")
        XCTAssertFalse(songs[0].needsTranscode)
        XCTAssertTrue(songs[1].needsTranscode)
        let direct = try await client.streamURL(for: songs[0])
        XCTAssertEqual(direct.path, "/webapi/AudioStation/stream.cgi/0.flac")
        let transcoded = try await client.streamURL(for: songs[1])
        XCTAssertTrue(transcoded.absoluteString.contains("method=transcode"))
        XCTAssertTrue(transcoded.absoluteString.contains("format=mp3"))
    }

    func testMoviesDecodeFiles() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.VideoStation.Movie.list"] = #"""
        {"success":true,"data":{"total":1,"movies":[{"id":7,"title":"流浪地球","original_available":"2019-02-05",
          "additional":{"summary":"太阳要完了","poster_mtime":"2023-01-01 00:00:00","file":[{"id":9,"sharepath":"/video/流浪地球.mkv","path":"/volume1/video/流浪地球.mkv"}]}}]}}
        """#
        let movies = try await client.videos(.movie)
        XCTAssertEqual(movies.first?.year, 2019)
        XCTAssertEqual(movies.first?.files, ["/video/流浪地球.mkv"])
        XCTAssertTrue(movies.first!.hasPoster)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["version"], "4")
    }
}

let apiInfoManagement = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.Core.System":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.Core.User":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Core.CurrentConnection":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Core.FileServ.SMB":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.Core.FileServ.FTP":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.Core.FileServ.FTP.SFTP":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.Core.TaskScheduler":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
 "SYNO.Docker.Container":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
 "SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
 "SYNO.FileStation.CreateFolder":{"path":"entry.cgi","minVersion":1,"maxVersion":2},
 "SYNO.FileStation.Upload":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}
"""#

final class ManagementTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoManagement
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testUsersConnectionsNetwork() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Core.User.list"] = #"{"success":true,"data":{"users":[{"name":"admin","expired":"now"},{"name":"bob","email":"b@x","expired":"normal"}],"total":2}}"#
        let users = try await client.users()
        XCTAssertTrue(users[0].isDisabled && users[0].isSystem)
        XCTAssertEqual(users[1].email, "b@x")

        t.responses["SYNO.Core.CurrentConnection.list"] = #"{"success":true,"data":{"items":[{"who":"bob","from":"192.0.2.9","type":"SMB","time":"2026/10/19 10:00:00","pid":1234,"can_be_kicked":true}],"total":1}}"#
        let conns = try await client.connections()
        XCTAssertEqual(conns.first?.pid, 1234)
        t.responses["SYNO.Core.CurrentConnection.kick"] = #"{"success":true}"#
        try await client.kick(conns[0])
        XCTAssertTrue(MockTransport.fields(t.requests.last!)["connection"]!.contains(#""pid":1234"#))

        t.responses["SYNO.Core.System.info"] = #"{"success":true,"data":{"hostname":"DS920","gateway":"192.0.2.1","dns":"192.0.2.1","nif":[{"id":"eth0","addr":"192.0.2.5","mask":"255.255.255.0","mac":"00:11:32:aa","type":"lan","ipv6":[{"addr":"fe80::1","prefix_length":64}]}]}}"#
        let net = try await client.network()
        XCTAssertEqual(net.interfaces.first?.ipv6, ["fe80::1/64"])
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["type"], "network")
    }

    func testFileServicesAndTasks() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Core.FileServ.SMB.get"] = #"{"success":true,"data":{"enable_samba":true,"workgroup":"WORKGROUP"}}"#
        t.responses["SYNO.Core.FileServ.FTP.get"] = #"{"success":true,"data":{"enable_ftp":false,"enable_ftps":true,"portnum":21}}"#
        t.responses["SYNO.Core.FileServ.FTP.SFTP.get"] = #"{"success":true,"data":{"enable":true,"portnum":22}}"#
        let services = try await client.fileServices()
        XCTAssertEqual(services.map(\.service), [.smb, .ftp, .ftps, .sftp])
        XCTAssertEqual(services.map(\.enabled), [true, false, true, true])
        XCTAssertEqual(services.last?.port, 22)

        t.responses["SYNO.Core.FileServ.FTP.set"] = #"{"success":true}"#
        try await client.setFileService(.ftps, enabled: false)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["enable_ftps"], "false")

        t.responses["SYNO.Core.TaskScheduler.list"] = #"{"success":true,"data":{"tasks":[{"id":3,"name":"backup","enable":true,"owner":"root","real_owner":"root","type":"script","next_trigger_time":"2026-10-20 03:00"}],"total":1}}"#
        let tasks = try await client.scheduledTasks()
        XCTAssertEqual(tasks.first?.typeLabel, "用户脚本")
        t.responses["SYNO.Core.TaskScheduler.run"] = #"{"success":true}"#
        try await client.runTask(tasks[0])
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["tasks"], #"[{"id":3,"real_owner":"root"}]"#)
    }

    func testAuditRecordsWritesWithSecretsHidden() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        final class Box: @unchecked Sendable { var events: [AuditEvent] = [] }
        let box = Box()
        await client.setAuditHandler { box.events.append($0) }
        t.responses["SYNO.Core.User.list"] = #"{"success":true,"data":{"users":[]}}"#
        _ = try await client.users()
        t.responses["SYNO.Core.User.create"] = #"{"success":true}"#
        try await client.createUser(name: "eve", password: "hunter2")
        XCTAssertEqual(box.events.count, 1)
        XCTAssertEqual(box.events[0].parameters["password"], "***")
        XCTAssertEqual(box.events[0].parameters["name"], "eve")
        XCTAssertNil(box.events[0].parameters["_sid"])

        _ = try? await client.deleteUser("x")
        XCTAssertEqual(box.events.last?.succeeded, false)
        XCTAssertEqual(box.events.last?.errorCode, 102)

        let inline = AuditPolicy.redactInline(#"{"env_variables":[{"key":"DB_PASSWORD","value":"s3cret"},{"key":"TZ","value":"UTC"}]}"#)
        XCTAssertFalse(inline.contains("s3cret"))
        XCTAssertTrue(inline.contains("UTC"))
    }

    func testImageReferenceAndBackupRoundTrip() async throws {
        XCTAssertTrue(DSMClient.splitImageReference("nginx") == ("nginx", "latest"))
        XCTAssertTrue(DSMClient.splitImageReference("reg:5000/app:1.2") == ("reg:5000/app", "1.2"))
        XCTAssertTrue(DSMClient.splitImageReference("reg:5000/app") == ("reg:5000/app", "latest"))

        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Docker.Container.get"] = #"{"success":true,"data":{"details":{},"profile":{"name":"app","image":"app:1","env_variables":[]}}}"#
        t.responses["SYNO.FileStation.CreateFolder.create"] = #"{"success":true,"data":{}}"#
        t.responses["SYNO.FileStation.Upload.upload"] = #"{"success":true}"#
        let path = try await client.backupContainer("app", note: "test")
        XCTAssertTrue(path.hasPrefix("/docker/nashelper-backups/app@"))
        let upload = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(upload["method"], "upload")

        let backup = ContainerBackup(container: "app", image: "app:1", created: Date(timeIntervalSince1970: 0), note: "",
                                     profile: ["name": .string("app"), "image": .string("app:1")])
        let decoded = try DSMClient.backupDecoder.decode(ContainerBackup.self, from: DSMClient.backupEncoder.encode(backup))
        XCTAssertEqual(decoded, backup)
        XCTAssertEqual(decoded.settings.image, "app:1")
    }
}

/// Answers QuickConnect lookups per server host.
final class QCTransport: HTTPTransport, @unchecked Sendable {
    var byHost: [String: String] = [:]
    private(set) var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url!.host!
        hosts.append(host)
        let body = byHost[host] ?? #"[{"errno":4}]"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class QuickConnectTests: XCTestCase {
    let reply = #"""
    [{"command":"get_server_info","errno":0,
      "server":{"interface":[{"ip":"192.0.2.5","name":"eth0"},{"ip":"0.0.0.0","name":"eth1"}],
                "external":{"ip":"203.0.113.7"},"ddns":"mynas.synology.me","fqdn":"NULL","serverID":"123"},
      "service":{"port":5001,"ext_port":15001},"env":{"relay_region":"cn3","control_host":"cnc.quickconnect.cn"}}]
    """#

    func testExpandsIntoLANWANAndRelay() async throws {
        let t = QCTransport()
        t.byHost["global.quickconnect.to"] = #"[{"errno":4,"sites":["cnc.quickconnect.cn"]}]"#
        t.byHost["cnc.quickconnect.cn"] = reply
        let eps = try await QuickConnectResolver(transport: t).endpoints(for: "mynas", pinnedSHA256: "AB")
        XCTAssertEqual(eps.map(\.display), [
            "https://192.0.2.5:5001", "https://mynas.synology.me:15001", "https://203.0.113.7:15001",
            "https://mynas.cn3.quickconnect.cn:443",
        ])
        XCTAssertEqual(eps.first?.pinnedCertificateSHA256, "AB")
        XCTAssertNil(eps[1].pinnedCertificateSHA256)
        XCTAssertNil(eps[2].pinnedCertificateSHA256)
        XCTAssertNil(eps.last?.pinnedCertificateSHA256)
        XCTAssertEqual(t.hosts, ["global.quickconnect.to", "cnc.quickconnect.cn"])
    }

    func testUnknownIDFails() async {
        let t = QCTransport()
        do {
            _ = try await QuickConnectResolver(transport: t).endpoints(for: "nobody")
            XCTFail("expected failure")
        } catch {}
        XCTAssertTrue(Endpoint(kind: .quickConnect, host: "mynas").isQuickConnectID)
        XCTAssertFalse(Endpoint(kind: .quickConnect, host: "mynas.cn3.quickconnect.cn").isQuickConnectID)
    }
}

final class DeviceBugfixTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{
         "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.Core.Terminal":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
         "SYNO.Storage.CGI.Storage":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.Core.SyslogClient.Log":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testResolverHandsSessionItsOwnTransport() async throws {
        let probe = MockTransport()
        probe.responses["SYNO.API.Info.query"] = apiInfoDSM72
        let session = MockTransport()
        let resolver = EndpointResolver(makeTransport: { _ in probe }, makeSessionTransport: { _ in session },
                                       probe: { _, _ in true })
        let picked = try await resolver.resolve([Endpoint(kind: .lan, host: "nas")])
        // The API table from the probe carries over, so login goes straight out on the session transport.
        session.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        _ = try await picked.client.login(account: "a", password: "b")
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(session.requests.count, 1)
    }

    func testProbeTimeoutReadsAsUnreachable() async {
        let resolver = EndpointResolver(makeTransport: { _ in
            let t = MockTransport()
            t.failure = DSMError.timedOut
            return t
        }, probe: { _, _ in true })
        do {
            _ = try await resolver.resolve([Endpoint(kind: .wan, host: "nas")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DSMError, .unreachable)
        }
    }

    func testStorageStatusLabels() {
        XCTAssertEqual(StorageStatus.label("attention"), "需要注意")
        XCTAssertEqual(StorageStatus.label("normal"), "良好")
        XCTAssertEqual(StorageStatus.label(nil), "良好")
        XCTAssertEqual(StorageStatus.label("degrade"), "降级")
        XCTAssertEqual(StorageStatus.label("something_new"), "something_new")
        XCTAssertEqual(StorageStatus.volumeName("volume1"), "存储空间 1")
        XCTAssertEqual(StorageStatus.volumeName("usbshare1"), "usbshare1")
    }

    func testScanHealthAttentionIsChinese() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Storage.CGI.Storage.load_info"] = #"""
        {"success":true,"data":{"volumes":[{"id":"volume_1","vol_path":"/volume1","status":"attention","size":{"total":"100","used":"10"}}],
         "storagePools":[{"id":"reuse_1","num_id":1,"device_type":"shr_without_disk_protect","status":"attention"}],"disks":[]}}
        """#
        let alerts = await client.scanHealth(since: nil)
        let volume = alerts.first { $0.id == "volume-volume_1" }
        XCTAssertEqual(volume?.title, "存储空间 1：需要注意")
        XCTAssertEqual(volume?.severity, .warning)
        XCTAssertEqual(alerts.first { $0.id == "pool-reuse_1" }?.title, "存储池 1：需要注意")
        XCTAssertFalse(alerts.contains { $0.title.contains("attention") || $0.detail.contains("attention") })
    }

    func testTerminalSettingsDecode() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.Core.Terminal.get"] = #"{"success":true,"data":{"enable_ssh":true,"enable_telnet":false,"ssh_port":2222}}"#
        let settings = try await client.terminalSettings()
        XCTAssertEqual(settings, TerminalSettings(sshEnabled: true, sshPort: 2222))
    }

    func testSSHTargetParse() {
        XCTAssertEqual(SSHTarget.parse("nas.example.com").host, "nas.example.com")
        XCTAssertNil(SSHTarget.parse("nas.example.com").port)
        XCTAssertEqual(SSHTarget.parse("ssh://admin@nas.example.com:2222").host, "nas.example.com")
        XCTAssertEqual(SSHTarget.parse("ssh://admin@nas.example.com:2222").port, 2222)
        XCTAssertEqual(SSHTarget.parse("192.0.2.10:2200").port, 2200)
        XCTAssertEqual(SSHTarget.parse("[fe80::1]:2222").host, "fe80::1")
        XCTAssertEqual(SSHTarget.parse("[fe80::1]:2222").port, 2222)
        XCTAssertNil(SSHTarget.parse("fe80::1").port)
    }

    func testSSHTargetCandidates() {
        let lan = Endpoint(kind: .lan, host: "192.0.2.10")
        let wan = Endpoint(kind: .wan, host: "nas.example.com")
        let qc = Endpoint(kind: .quickConnect, host: "mynas")
        let relay = Endpoint(kind: .quickConnect, host: "mynas.cn3.quickconnect.cn", port: 443)

        // Default port 22 defers to what DSM reports; the current address goes first; QuickConnect is skipped.
        XCTAssertEqual(SSHTarget.candidates(settings: SSHSettings(), current: wan, endpoints: [lan, wan, qc], reportedPort: 2222),
                       [SSHTarget(host: "nas.example.com", port: 2222), SSHTarget(host: "192.0.2.10", port: 2222)])
        // A port the user set wins over the reported one.
        XCTAssertEqual(SSHTarget.candidates(settings: SSHSettings(port: 6022), current: lan, endpoints: [lan], reportedPort: 2222),
                       [SSHTarget(host: "192.0.2.10", port: 6022)])
        // A typed host is the only candidate, and a port inside it wins.
        XCTAssertEqual(SSHTarget.candidates(settings: SSHSettings(host: "ssh.example.com:7000"), current: lan, endpoints: [lan],
                                            reportedPort: 2222),
                       [SSHTarget(host: "ssh.example.com", port: 7000)])
        // Only reachable through the relay: nothing SSH can use.
        XCTAssertEqual(SSHTarget.candidates(settings: SSHSettings(), current: relay, endpoints: [qc], reportedPort: nil), [])
        XCTAssertEqual(SSHTarget.candidates(settings: SSHSettings(), current: nil, endpoints: [lan], reportedPort: nil),
                       [SSHTarget(host: "192.0.2.10", port: 22)])
        // Explicit LAN and WAN beat the DSM address, and each side keeps its own port.
        let dual = SSHSettings(lanHost: "192.0.2.10", lanPort: 22, wanHost: "ssh.example.com", wanPort: 2200)
        XCTAssertEqual(SSHTarget.candidates(settings: dual, current: wan, endpoints: [lan, wan], reportedPort: 2222),
                       [SSHTarget(host: "192.0.2.10", port: 22), SSHTarget(host: "ssh.example.com", port: 2200)])
    }

    func testSSHSettingsDecodeLegacyJSON() throws {
        let data = Data(#"{"host":"nas","port":22,"username":"admin"}"#.utf8)
        let settings = try JSONDecoder().decode(SSHSettings.self, from: data)
        XCTAssertEqual(settings.host, "nas")
        XCTAssertEqual(settings.lanHost, "")
        XCTAssertEqual(settings.wanPort, 22)
    }

    func testClosedPortIsSkippedBeforeHTTPS() async throws {
        let lan = Endpoint(kind: .lan, host: "192.0.2.200", port: 65443)
        let wan = Endpoint(kind: .wan, host: "nas.example", port: 443)
        let resolver = EndpointResolver(makeTransport: { endpoint in
            let t = MockTransport()
            t.responses["SYNO.API.Info.query"] = apiInfoDSM72
            return t
        }, probe: { host, _ in host == "nas.example" })
        let picked = try await resolver.resolve([lan, wan])
        XCTAssertEqual(picked.endpoint.host, "nas.example")
    }

    func testOpenLANPortDoesNotFallThroughOnCertificate() async {
        let lan = Endpoint(kind: .lan, host: "192.0.2.200", port: 65443)
        let wan = Endpoint(kind: .wan, host: "nas.example", port: 443)
        let resolver = EndpointResolver(makeTransport: { endpoint in
            let t = MockTransport()
            if endpoint.kind == .lan {
                t.failure = DSMError.untrustedCertificate(host: endpoint.host, fingerprint: "AA")
            } else {
                t.responses["SYNO.API.Info.query"] = apiInfoDSM72
            }
            return t
        }, probe: { _, _ in true })
        do {
            _ = try await resolver.resolve([lan, wan])
            XCTFail("expected the LAN certificate prompt")
        } catch {
            XCTAssertEqual(error as? DSMError, .untrustedCertificate(host: "192.0.2.200", fingerprint: "AA"))
        }
    }

    func testLANWebURLUsesDSMPort() {
        let lan = Endpoint(kind: .lan, host: "192.0.2.200", port: 443)
        let ports = DSMWebPorts(httpEnabled: true, httpPort: 5000, httpsEnabled: true, httpsPort: 65443)
        XCTAssertEqual(DSMWebAddress.url(endpoint: lan, ports: ports)?.absoluteString, "https://192.0.2.200:65443")
        let wan = Endpoint(kind: .wan, host: "cp.example.org", port: 443)
        XCTAssertEqual(DSMWebAddress.url(endpoint: wan, ports: ports), wan.baseURL)
    }
}

final class NASHardwareTests: XCTestCase {
    func testKnownAndGuessedModels() {
        let ds1621 = NASModelSpec.lookup("DS1621+")
        XCTAssertEqual(ds1621.bays, 6)
        XCTAssertEqual(ds1621.form, .desktop)
        XCTAssertTrue(ds1621.isKnown)
        XCTAssertEqual(NASModelSpec.lookup("DS223j").form, .compact)
        XCTAssertEqual(NASModelSpec.lookup("DS223j").bays, 2)
        XCTAssertEqual(NASModelSpec.lookup("RS1221+").form, .rack)
        XCTAssertEqual(NASModelSpec.lookup("RS1221+").bays, 8)
        XCTAssertEqual(NASModelSpec.lookup("DS2422+").columns, 6)
        // Not in the table: naming rule.
        XCTAssertEqual(NASModelSpec.lookup("DS1826+").bays, 8)
        XCTAssertFalse(NASModelSpec.lookup("DS1826+").isKnown)
        XCTAssertEqual(NASModelSpec.lookup(nil).bays, 4)
    }

    func testDiskLayoutPlacesBySlotAndSkipsM2() throws {
        let json = #"""
        {"disks":[
          {"id":"sata1","num_id":1,"status":"normal","smart_status":"normal","container":{"type":"internal"}},
          {"id":"sata3","num_id":3,"status":"crashed","container":{"type":"internal"}},
          {"id":"nvme0n1","num_id":1,"status":"normal","diskType":"NVMe"},
          {"id":"sata7","num_id":1,"status":"normal","container":{"type":"ebox"}}
        ]}
        """#
        let overview = try JSONDecoder().decode(StorageOverview.self, from: Data(json.utf8))
        let bays = DriveBay.layout(spec: NASModelSpec.lookup("DS1621+"), disks: overview.disks)
        XCTAssertEqual(bays.count, 6)
        XCTAssertEqual(bays.map(\.state), [.normal, .empty, .critical, .empty, .empty, .empty])
        XCTAssertEqual(bays[2].disk?.id, "sata3")
    }

    func testUptimeAndClock() throws {
        let json = #"{"up_time":"172:20:42:44","time":"2026-10-21 19:41:42"}"#
        let info = try JSONDecoder().decode(SystemInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.upTimeSeconds, ((172 * 24 + 20) * 60 + 42) * 60 + 44)
        XCTAssertEqual(SystemInfo.formatUptime(info.upTimeSeconds!), "172 天 20 小时 42 分钟 44 秒")
        let clock = try XCTUnwrap(info.systemWallClock)
        XCTAssertEqual(SystemInfo.formatWallClock(clock.addingTimeInterval(20)), "2026-10-21 19:42:02")
    }

    func testDiskActivity() throws {
        let json = #"{"disk":{"disk":[{"device":"sata1","read_byte":1000,"write_byte":0,"utilization":40}],"total":{}}}"#
        let activity = try JSONDecoder().decode(DiskActivity.self, from: Data(json.utf8))
        XCTAssertEqual(activity.level(for: "sata1"), 0.4)
        XCTAssertNil(activity.level(for: "sata2"))
    }
}

final class SettingsAPITests: XCTestCase {
    let apiInfo = #"""
    {"success":true,"data":{
     "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
     "SYNO.FileStation.Sharing":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
     "SYNO.Core.Hardware.PowerSchedule":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
    """#

    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfo
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas.local:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testShareLinkCarriesAccessLimitAndListDecodes() async throws {
        let t = MockTransport()
        t.responses["SYNO.FileStation.Sharing.create"] = #"{"success":true,"data":{"links":[{"id":"abc","url":"https://gofile.me/x/abc"}]}}"#
        t.responses["SYNO.FileStation.Sharing.list"] = #"""
        {"success":true,"data":{"total":2,"links":[
         {"id":"abc","url":"https://gofile.me/x/abc","name":"a.mp4","path":"/video/a.mp4","isFolder":false,
          "has_password":true,"status":"valid","date_expired":"2026-10-31","date_available":"","expire_times":5},
         {"id":7,"url":"https://gofile.me/x/def","status":"expired"}]}}
        """#
        t.responses["SYNO.FileStation.Sharing.delete"] = #"{"success":true}"#
        let client = try await loggedIn(t)

        let link = try await client.createShareLink(for: "/video/a.mp4", accessLimit: 5)
        XCTAssertEqual(link.id, "abc")
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["expire_times"], "5")

        let links = try await client.shareLinks()
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].accessLimit, 5)
        XCTAssertTrue(links[0].hasPassword)
        XCTAssertNil(links[0].dateAvailable)
        XCTAssertEqual(links[1].id, "7")
        XCTAssertFalse(links[1].isValid)

        try await client.deleteShareLinks(["abc"])
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["id"], #"["abc"]"#)
    }

    func testPowerScheduleRoundTrip() async throws {
        let t = MockTransport()
        t.responses["SYNO.Core.Hardware.PowerSchedule.load"] = #"""
        {"success":true,"data":{"poweron_tasks":[{"enabled":true,"hour":8,"min":0,"weekdays":"1,2,3,4,5"}],
         "poweroff_tasks":[{"enabled":false,"hour":"23","min":"30","weekdays":"0,1,2,3,4,5,6"}]}}
        """#
        t.responses["SYNO.Core.Hardware.PowerSchedule.save"] = #"{"success":true}"#
        let client = try await loggedIn(t)

        let schedule = try await client.powerSchedule()
        XCTAssertEqual(schedule.powerOn.first?.summary, "工作日 08:00")
        XCTAssertEqual(schedule.powerOff.first?.summary, "每天 23:30")
        XCTAssertEqual(schedule.powerOff.first?.enabled, false)

        try await client.savePowerSchedule(schedule)
        let saved = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(saved["poweron_tasks"], #"[{"enabled":true,"hour":8,"min":0,"weekdays":"1,2,3,4,5"}]"#)
        XCTAssertEqual(saved["poweroff_tasks"], #"[{"enabled":false,"hour":23,"min":30,"weekdays":"0,1,2,3,4,5,6"}]"#)
    }
}

let apiInfoCS = #"""
{"success":true,"data":{
 "SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
 "SYNO.CloudSync":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}
"""#

final class CloudSyncTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = apiInfoCS
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testConnectionsTasksAndLogsDecode() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.CloudSync.list_conn"] = #"""
        {"success":true,"data":{"conn":[
          {"id":3,"link_status":1,"status":"uptodate","task_display_name":"Dropbox","type":"db","unfinished_files":0,"user_name":"u"},
          {"id":"2","link_status":1,"status":"syncing","task_display_name":"Microsoft OneDrive","type":"od_v1","unfinished_files":2},
          {"id":5,"link_status":0,"status":"uptodate","task_name":"Old","type":"gd"}],
         "is_admin_mode":true,"is_pause":false,"total":3}}
        """#
        let overview = try await client.cloudSyncOverview()
        XCTAssertEqual(overview.connections.map(\.status), [.uptodate, .syncing, .unlinked])
        XCTAssertEqual(overview.connections[1].provider, "OneDrive")
        XCTAssertEqual(overview.connections[1].unfinishedFiles, 2)
        XCTAssertEqual(overview.connections[2].name, "Old")
        XCTAssertFalse(overview.isPaused)

        t.responses["SYNO.CloudSync.list_sess"] = #"""
        {"success":true,"data":{"sess":[
          {"sess_id":4,"conn_id":3,"error":0,"error_desc":"","local_sync_path":"/share/a","remote_sync_path":"/docs",
           "sync_direction":"ONLY_DOWNLOAD","sync_status":"uptodate"},
          {"sess_id":6,"error":-36,"error_desc":"","sync_direction":"BIDIRECTION","sync_status":"syncing"}],"total":2}}
        """#
        let tasks = try await client.cloudSyncTasks(connection: 3)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["connection_id"], "3")
        XCTAssertEqual(tasks[0].direction, .downloadOnly)
        XCTAssertNil(tasks[0].errorDescription)
        XCTAssertEqual(tasks[1].status, .error)
        XCTAssertEqual(tasks[1].errorDescription, "错误码 -36")

        t.responses["SYNO.CloudSync.get_log"] = #"""
        {"success":true,"data":{"items":[
          {"action":1,"error_code":-36,"file_name":"a.paper","log_level":2,"path":"/s/a.paper","session_id":4,"time":1724418119},
          {"action":2,"error_code":0,"log_level":0,"path":"/s/b.txt","session_id":4,"time":1724418508}],"total":2}}
        """#
        let logs = try await client.cloudSyncLogs(connection: 3, limit: 50)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["limit"], "50")
        XCTAssertEqual(logs.map(\.fileName), ["b.txt", "a.paper"])
        XCTAssertEqual(logs[1].level, .error)
        XCTAssertEqual(logs[0].actionLabel, "上传")
    }

    func testPauseAndResumeScope() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.CloudSync.pause"] = #"{"success":true}"#
        t.responses["SYNO.CloudSync.resume"] = #"{"success":true}"#
        try await client.pauseCloudSync(connection: 3)
        XCTAssertEqual(MockTransport.fields(t.requests.last!)["connection_id"], "3")
        try await client.resumeCloudSync()
        XCTAssertNil(MockTransport.fields(t.requests.last!)["connection_id"])
    }
}

final class SynologyDriveTests: XCTestCase {
    func loggedIn(_ t: MockTransport) async throws -> DSMClient {
        t.responses["SYNO.API.Info.query"] = #"""
        {"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7},
         "SYNO.SynologyDrive.Files":{"path":"entry.cgi","minVersion":1,"maxVersion":3},
         "SYNO.SynologyDrive.TeamFolders":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.SynologyDrive.Connection":{"path":"entry.cgi","minVersion":1,"maxVersion":1},
         "SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}
        """#
        t.responses["SYNO.API.Auth.login"] = #"{"success":true,"data":{"sid":"S1","synotoken":"T1"}}"#
        let client = DSMClient(baseURL: URL(string: "https://nas:5001")!, transport: t)
        _ = try await client.login(account: "a", password: "b")
        return client
    }

    func testListDecodesItemsAndSendsJSONPath() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.SynologyDrive.Files.list"] = #"""
        {"success":true,"data":{"total":2,"items":[
          {"file_id":"552146100935505098","name":"文档","display_path":"/mydrive/文档","type":"dir","size":0,"modified_time":1739602200,"starred":true,"owner":{"name":"feng","display_name":""}},
          {"file_id":5521,"name":"a.log","path":"/mydrive/a.log","type":"file","size":"3220","modified_time":"1739602201","shared":true}]}}
        """#
        let listing = try await client.driveList("/mydrive/", sortBy: "modified_time", ascending: false)

        let f = MockTransport.fields(t.requests.last!)
        XCTAssertEqual(f["path"], #""/mydrive/""#)
        XCTAssertEqual(f["sort_direction"], #""desc""#)
        XCTAssertEqual(f["version"], "2")
        XCTAssertEqual(listing.total, 2)
        let folder = listing.items[0], file = listing.items[1]
        XCTAssertTrue(folder.isDirectory)
        XCTAssertTrue(folder.starred)
        XCTAssertEqual(folder.owner, "feng")
        XCTAssertEqual(folder.reference, "id:552146100935505098")
        XCTAssertEqual(file.kind, .text)
        XCTAssertEqual(file.size, 3220)
        XCTAssertTrue(file.shared)
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1739602201))
        XCTAssertEqual(file.fileStationPath, "/home/Drive/a.log")
    }

    func testFileStationPathMapping() {
        XCTAssertEqual(DriveItem.fileStationPath(for: "/mydrive"), "/home/Drive")
        XCTAssertEqual(DriveItem.fileStationPath(for: "/mydrive/a/b.txt"), "/home/Drive/a/b.txt")
        XCTAssertEqual(DriveItem.fileStationPath(for: "/team-folders/Projects/x.pdf"), "/Projects/x.pdf")
        XCTAssertNil(DriveItem.fileStationPath(for: "/team-folders/"))
        XCTAssertNil(DriveItem.fileStationPath(for: "/shared-with-me/x"))
    }

    func testCategoriesUseTheirMethods() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.SynologyDrive.Files.list_starred"] = #"{"success":true,"data":{"items":[{"file_id":"1","name":"s.mp4","display_path":"/mydrive/s.mp4","type":"file"}]}}"#
        let starred = try await client.driveList(.starred)
        XCTAssertEqual(starred.items.map(\.name), ["s.mp4"])
        XCTAssertEqual(starred.total, 1)
        XCTAssertNil(MockTransport.fields(t.requests.last!)["path"])
    }

    func testTeamFoldersGetAPathWhenMissing() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.SynologyDrive.TeamFolders.list"] = #"{"success":true,"data":{"total":1,"items":[{"file_id":"9","name":"Projects","type":"dir"}]}}"#
        let folders = try await client.driveTeamFolders()
        XCTAssertEqual(folders.first?.path, "/team-folders/Projects")
        XCTAssertTrue(folders.first!.isDirectory)
    }

    func testDownloadURLUsesFileIDAndName() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        let item = DriveItem(fileID: "77", name: "报告 1.pdf", path: "/mydrive/报告 1.pdf", isDirectory: false)
        let url = try await client.driveDownloadURL(for: item)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(comps.path, "/webapi/entry.cgi/报告 1.pdf")
        XCTAssertEqual(q["files"], #"["id:77"]"#)
        XCTAssertEqual(q["api"], "SYNO.SynologyDrive.Files")
        XCTAssertEqual(q["_sid"], "S1")
    }

    func testUploadSendsFullPathInQueryAndForm() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.SynologyDrive.Files.upload"] = #"{"success":true,"data":{"file_id":"5"}}"#
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("drive.txt")
        try Data("hi".utf8).write(to: local)

        try await client.driveUpload(fileAt: local, toFolder: "/mydrive/docs")

        let req = t.requests.last!
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(q.contains(URLQueryItem(name: "path", value: "/mydrive/docs/drive.txt")))
        XCTAssertTrue(q.contains(URLQueryItem(name: "conflict_action", value: "version")))
        let body = String(data: req.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("name=\"type\"\r\n\r\nfile\r\n"))
        XCTAssertTrue(body.contains("filename=\"drive.txt\""))
    }

    func testServerStatusReadsConnectionsLoosely() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        t.responses["SYNO.SynologyDrive.TeamFolders.list"] = #"{"success":true,"data":{"items":[]}}"#
        t.responses["SYNO.SynologyDrive.Connection.list"] = #"""
        {"success":true,"data":{"total":1,"items":[{"session_id":"c1","user_name":"feng","hostname":"MacBook","client_type":"Drive Client","ip":"192.0.2.8","client_version":"3.5.0","login_time":1739602200}]}}
        """#
        let status = await client.driveServerStatus()
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(status.apis.map(\.name), ["SYNO.SynologyDrive.Connection", "SYNO.SynologyDrive.Files", "SYNO.SynologyDrive.TeamFolders"])
        XCTAssertNil(status.package, "package list refused by the mock")
        let c = try XCTUnwrap(status.connections?.first)
        XCTAssertEqual(c.user, "feng")
        XCTAssertEqual(c.device, "MacBook")
        XCTAssertEqual(c.address, "192.0.2.8")
        XCTAssertEqual(c.lastSeen, Date(timeIntervalSince1970: 1739602200))
    }

    func testConnectionErrorIsReportedNotThrown() async throws {
        let t = MockTransport()
        let client = try await loggedIn(t)
        let status = await client.driveServerStatus()
        XCTAssertNil(status.connections)
        XCTAssertNotNil(status.connectionError)
    }
}
