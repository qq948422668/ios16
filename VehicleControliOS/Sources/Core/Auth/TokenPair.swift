import Foundation

/// 本地持久化的登录凭证。
struct TokenPair: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
    let scope: String?

    /// 提前 60 秒判定过期，避免边界时刻请求被拒。
    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

/// Token 端点原始响应体。
struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let tokenType: String?
    let scope: String?
}

extension TokenResponse {
    func makeTokenPair(previousRefreshToken: String?) throws -> TokenPair {
        guard let refresh = refreshToken ?? previousRefreshToken, !refresh.isEmpty else {
            throw APIError.refreshFailed("Token 响应缺少 refresh_token")
        }
        return TokenPair(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            tokenType: tokenType ?? "Bearer",
            scope: scope
        )
    }
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
