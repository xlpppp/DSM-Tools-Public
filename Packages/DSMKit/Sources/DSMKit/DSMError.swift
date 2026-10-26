import Foundation

/// Errors surfaced by DSMKit. `code` values follow Synology's Web API error tables.
public enum DSMError: Error, Equatable, Sendable {
    /// DSM answered `success: false` with this code for `api`.
    case api(code: Int, api: String)
    /// The account has 2-step verification on and no (valid) OTP code was sent.
    case otpRequired
    /// The OTP code was rejected.
    case otpInvalid
    /// Wrong account or password.
    case invalidCredentials
    /// The server certificate is not trusted; `fingerprint` is its SHA-256 (hex, colon separated).
    case untrustedCertificate(host: String, fingerprint: String?)
    /// None of the configured addresses answered.
    case unreachable
    /// Connected, but this request took too long (a slow query, a weak network).
    case timedOut
    /// The API is not offered by this DSM version.
    case apiUnavailable(String)
    /// Not logged in, or the session expired.
    case notAuthenticated
    case invalidResponse
    case transport(String)

    /// A short Chinese message suitable for the UI.
    public var message: String {
        switch self {
        case .api(let code, _): return DSMError.describe(code: code)
        case .otpRequired: return "需要输入二次验证码"
        case .otpInvalid: return "二次验证码错误"
        case .invalidCredentials: return "账号或密码错误"
        case .untrustedCertificate: return "服务器证书不受信任"
        case .unreachable: return "所有地址都无法连接"
        case .timedOut: return "请求超时，NAS 响应较慢，请稍后重试"
        case .apiUnavailable(let api): return "当前 DSM 版本不支持 \(api)"
        case .notAuthenticated: return "登录已失效，请重新登录"
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case .transport(let text): return text
        }
    }

    static func describe(code: Int) -> String {
        switch code {
        case 100: return "未知错误"
        case 101: return "缺少参数"
        case 102: return "接口不存在"
        case 103: return "方法不存在"
        case 104: return "接口版本不支持"
        case 105: return "没有权限，需要管理员账号"
        case 106: return "会话超时"
        case 107: return "会话被重复登录中断"
        case 119: return "会话不存在"
        case 401: return "账号已停用"
        case 402: return "没有权限"
        case 407: return "当前 IP 已被封锁"
        case 408, 409, 410: return "密码已过期，请先在 DSM 网页端修改"
        default: return "操作失败（错误码 \(code)）"
        }
    }

    /// Maps an error code returned by SYNO.API.Auth.
    static func fromAuth(code: Int) -> DSMError {
        switch code {
        case 400: return .invalidCredentials
        case 403, 406: return .otpRequired
        case 404: return .otpInvalid
        default: return .api(code: code, api: "SYNO.API.Auth")
        }
    }

    /// Codes that mean the session is gone and a fresh login is needed.
    var isSessionLost: Bool {
        if case .api(let code, _) = self { return [106, 107, 119].contains(code) }
        return self == .notAuthenticated
    }
}
