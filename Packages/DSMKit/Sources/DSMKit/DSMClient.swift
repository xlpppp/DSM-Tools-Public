import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where an API lives and which versions this NAS offers, from SYNO.API.Info.
public struct APIDescriptor: Decodable, Hashable, Sendable {
    public let path: String
    public let minVersion: Int
    public let maxVersion: Int

    public init(path: String, minVersion: Int, maxVersion: Int) {
        self.path = path
        self.minVersion = minVersion
        self.maxVersion = maxVersion
    }
}

public struct LoginResult: Sendable, Equatable {
    public let sid: String
    public let synoToken: String?
    /// Device token returned after a successful OTP login; sending it later skips the OTP prompt.
    public let deviceToken: String?
}

struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: ErrorBody?

    struct ErrorBody: Decodable { let code: Int }
}

/// Talks to one DSM over its Web API (`/webapi/*.cgi`).
public actor DSMClient {
    public let baseURL: URL
    let transport: HTTPTransport
    public private(set) var apis: [String: APIDescriptor] = [:]
    public private(set) var session: LoginResult?
    var auditHandler: (@Sendable (AuditEvent) -> Void)?

    public init(baseURL: URL, transport: HTTPTransport, apis: [String: APIDescriptor] = [:]) {
        self.baseURL = baseURL
        self.transport = transport
        self.apis = apis
    }

    public var isLoggedIn: Bool { session != nil }

    // MARK: API discovery

    /// Loads the API table. Every later call picks its path and version from it,
    /// which is how one code base works on DSM 6.2 through 7.2.
    @discardableResult
    public func loadAPIInfo() async throws -> [String: APIDescriptor] {
        let map: [String: APIDescriptor] = try await perform(
            path: "query.cgi", api: "SYNO.API.Info", method: "query", version: 1,
            params: ["query": "all"], authenticated: false)
        apis = map
        return map
    }

    public func supports(_ api: String) -> Bool { apis[api] != nil }

    /// The highest version both sides support, or nil if the API is missing or too old.
    public func version(of api: String, preferred: Int) -> Int? {
        guard let d = apis[api] else { return nil }
        let v = min(preferred, d.maxVersion)
        return v >= d.minVersion ? v : nil
    }

    // MARK: Auth

    public func login(account: String, password: String, otpCode: String? = nil,
                      deviceToken: String? = nil, deviceName: String = "NASHelper") async throws -> LoginResult {
        if apis.isEmpty { try await loadAPIInfo() }
        // v6 exists on DSM 6.2 and 7.x and accepts a plain password over the (TLS) connection.
        guard let v = version(of: "SYNO.API.Auth", preferred: 6) else { throw DSMError.apiUnavailable("SYNO.API.Auth") }
        var params = [
            "account": account,
            "passwd": password,
            "session": "webui",
            "format": "sid",
            "enable_syno_token": "yes",
        ]
        if let otpCode, !otpCode.isEmpty {
            params["otp_code"] = otpCode
            params["enable_device_token"] = "yes"
            params["device_name"] = deviceName
        } else if let deviceToken, !deviceToken.isEmpty {
            params["device_id"] = deviceToken
            params["device_name"] = deviceName
        }

        struct Raw: Decodable {
            let sid: String
            let synotoken: String?
            let did: String?
            let device_id: String?
        }
        do {
            let raw: Raw = try await perform(path: apis["SYNO.API.Auth"]?.path ?? "entry.cgi", api: "SYNO.API.Auth",
                                             method: "login", version: v, params: params, authenticated: false)
            let result = LoginResult(sid: raw.sid, synoToken: raw.synotoken, deviceToken: raw.did ?? raw.device_id)
            session = result
            return result
        } catch DSMError.api(let code, _) {
            throw DSMError.fromAuth(code: code)
        }
    }

    public func logout() async {
        guard session != nil, let v = version(of: "SYNO.API.Auth", preferred: 6) else { return }
        _ = try? await call("SYNO.API.Auth", method: "logout", version: v, params: ["session": "webui"]) as EmptyData
        session = nil
    }

    // MARK: Calls

    /// Calls an authenticated API. `version` is the version the caller was written against;
    /// the client lowers it if the NAS only offers older ones.
    public func call<T: Decodable>(_ api: String, method: String, version preferred: Int,
                                   params: [String: String] = [:]) async throws -> T {
        guard let d = apis[api] else { throw DSMError.apiUnavailable(api) }
        guard let v = version(of: api, preferred: preferred) else { throw DSMError.apiUnavailable(api) }
        do {
            let value: T = try await perform(path: d.path, api: api, method: method, version: v, params: params, authenticated: true)
            audit(api, method, params, error: nil)
            return value
        } catch {
            audit(api, method, params, error: error)
            throw error
        }
    }

    func makeRequest(path: String, api: String, method: String, version: Int,
                     params: [String: String], authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: "webapi/\(path)", relativeTo: baseURL)?.absoluteURL else { throw DSMError.invalidResponse }
        var fields = params
        fields["api"] = api
        fields["method"] = method
        fields["version"] = String(version)
        if authenticated {
            guard let session else { throw DSMError.notAuthenticated }
            fields["_sid"] = session.sid
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = session?.synoToken {
            request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        request.httpBody = Self.formEncode(fields).data(using: .utf8)
        return request
    }

    func perform<T: Decodable>(path: String, api: String, method: String, version: Int,
                                       params: [String: String], authenticated: Bool) async throws -> T {
        let request = try makeRequest(path: path, api: api, method: method, version: version,
                                      params: params, authenticated: authenticated)
        let (data, response) = try await transport.send(request)
        return try decode(data, response, api: api)
    }

    func decode<T: Decodable>(_ data: Data, _ response: HTTPURLResponse, api: String) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw DSMError.invalidResponse
        }
        guard envelope.success else {
            let err = DSMError.api(code: envelope.error?.code ?? 100, api: api)
            if err.isSessionLost { session = nil }
            throw err
        }
        if let value = envelope.data { return value }
        if let empty = EmptyData() as? T { return empty }
        throw DSMError.invalidResponse
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
