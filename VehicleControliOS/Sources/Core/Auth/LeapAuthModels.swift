import Foundation

/// 零跑统一响应信封：`{ code, result, message, data }`。
struct LeapEnvelope<Payload: Decodable>: Decodable {
    let code: Int?
    let result: Int?
    let message: String?
    let data: Payload?

    /// 业务成功码集合：`0` 为业务风格成功，`200` 为 HTTP 风格成功
    /// （部分 appuser 端点返回 `{"code":200,"message":"操作成功"}`）。
    private static let successCodes: Set<Int> = [0, 200]

    var isSuccess: Bool {
        // 双码都缺失视为异常响应，不默认放行。
        let codes = [code, result].compactMap { $0 }
        guard !codes.isEmpty else { return false }
        // allSatisfy：混合风格（code=0, result=200）同样放行，
        // 但任一码是真实失败码（如 100115）仍判失败。
        return codes.allSatisfy { Self.successCodes.contains($0) }
    }
}

/// 短信登录返回：`data.appLoginVO`。
struct AppLoginPayload: Decodable {
    let appLoginVO: AppLoginVO?
}

struct AppLoginVO: Decodable {
    let accountId: String?
    let token: String?
    let refreshToken: String?
    let tokenExpired: Double?
}

/// 新网关登录 / 续期返回。
struct GatewayLoginPayload: Decodable {
    let accountId: String?
    let accessToken: String?
    let refreshToken: String?
    /// 毫秒时间戳。
    let tokenExpireTime: Double?
    let signParam: GatewaySignParam?
}

struct GatewaySignParam: Decodable {
    let r2: String?
    let r3: String?
}

/// 会话建立完成后的快照，供 UI 展示账号信息。
struct LeapSessionSummary: Sendable, Equatable {
    let accountID: String
    let accessTokenExpiresAt: Date
}

/// 登录链路阶段：决定错误文案的前缀，避免“发码失败”被说成“登录失败”。
enum AuthStage: String, Sendable {
    case sendCode
    case signIn
    case refresh

    var failurePrefix: String {
        switch self {
        case .sendCode: return "验证码发送失败"
        case .signIn: return "登录失败"
        case .refresh: return "登录状态刷新失败"
        }
    }
}

/// 登录/续期错误：把业务码翻译成用户可读文案。
enum LeapAuthError: LocalizedError {
    case invalidPhone
    case invalidSmsCode
    case business(stage: AuthStage, code: Int, message: String?)
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)
    case missingSession
    case missingTokens(String)

    var userMessage: String {
        switch self {
        case .invalidPhone:
            return "请输入 11 位中国大陆手机号。"
        case .invalidSmsCode:
            return "请输入 6 位数字验证码。"
        case .business(let stage, let code, let message):
            return Self.businessMessage(stage: stage, code: code, fallback: message)
        case .http(let status, let body):
            if status == 401 || status == 403 {
                return "登录凭证已失效，请重新登录。"
            }
            let snippet = body.isEmpty ? "" : "：\(body.prefix(120))"
            return "服务返回异常（HTTP \(status)）\(snippet)"
        case .transport(let detail):
            return "网络异常，请检查网络后重试（\(detail)）"
        case .decoding(let detail):
            return "登录响应解析失败：\(detail)"
        case .missingSession:
            return "登录状态已失效，请重新登录。"
        case .missingTokens(let field):
            return "登录响应缺少关键字段：\(field)"
        }
    }

    private static func businessMessage(
        stage: AuthStage,
        code: Int,
        fallback: String?
    ) -> String {
        switch code {
        case 100115:
            return "短信验证码错误或已失效，请重新获取。"
        case 100116:
            return "手机号格式不正确。"
        case 100117:
            return "验证码发送过于频繁，请 60 秒后再试。"
        case 39:
            return "登录凭证已过期，请重新登录。"
        default:
            // 服务端 message 原文不进用户提示（可能是“操作成功”这类
            // 与失败语境矛盾的文案），只保留业务码；原文由调用方写日志。
            return "\(stage.failurePrefix)（业务码 \(code)）。"
        }
    }

    var errorDescription: String? { userMessage }
}
