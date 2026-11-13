import Foundation

/// 本地持久化的登录凭证。
///
/// 零跑网关会话包含两类凭据：
/// - 新网关 `accessToken`（JWT）+ `refreshToken`：业务 API 与 HMAC 签名使用；
/// - 旧链路 `legacyToken`：控车/车主服务等旧接口的身份头。
/// `signKey` 是 JWT 尾段与 `signParam{r2,r3}` 异或派生的签名密钥（Base64）。
struct TokenPair: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
    let scope: String?

    // 零跑官方会话扩展（旧版本缓存里没有这些键，保持可选以便平滑升级）。
    var accountId: String?
    var legacyToken: String?
    var legacyRefreshToken: String?
    var signKey: String?

    /// 网关续期提前 5 分钟判定（文档 §3 客户端续期边界）。
    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 300 }
}

/// 网络层只依赖这个协议获取有效令牌，便于替换实现或在测试中打桩。
protocol TokenProviding: Sendable {
    func accessToken() async throws -> String
    func forceRefresh() async throws
}

protocol TokenStoring: Sendable {
    func load() -> TokenPair?
    func save(_ pair: TokenPair) throws
    func clear()
}
