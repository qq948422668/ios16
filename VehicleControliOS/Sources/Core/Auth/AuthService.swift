import Foundation

/// 鉴权中心。actor 保证并发下只有一个刷新在飞行中，
/// 避免多个 401 同时触发多次 refresh 导致 refresh_token 被轮换失效。
actor AuthService: TokenProviding {
    private let env: AppEnvironment
    private let store: any TokenStoring
    private let session: URLSession
    private var inFlightRefresh: Task<TokenPair, Error>?

    init(env: AppEnvironment, store: any TokenStoring, session: URLSession = .shared) {
        self.env = env
        self.store = store
        self.session = session
    }

    // MARK: - TokenProviding

    func accessToken() async throws -> String {
        guard let pair = store.load() else { throw APIError.notAuthenticated }
        if pair.isExpiringSoon {
            try await forceRefresh()
        }
        return store.load()?.accessToken ?? pair.accessToken
    }

    func forceRefresh() async throws {
        if let existing = inFlightRefresh {
            _ = try await existing.value
            return
        }
        guard let current = store.load(), !current.refreshToken.isEmpty else {
            throw APIError.notAuthenticated
        }

        let task = Task<TokenPair, Error> {
            let pair = try await Self.requestToken(
                parameters: [
                    "grant_type": "refresh_token",
                    "refresh_token": current.refreshToken,
                    "client_id": self.env.oauth.clientID
                ],
                env: self.env,
                session: self.session,
                previousRefreshToken: current.refreshToken
            )
            try self.store.save(pair)
            return pair
        }

        inFlightRefresh = task
        defer { inFlightRefresh = nil }

        do {
            _ = try await task.value
        } catch {
            throw APIError.refreshFailed(error.localizedDescription)
        }
    }

    // MARK: - 登录 / 登出

    func exchangeAuthorizationCode(code: String, verifier: String) async throws {
        let pair = try await Self.requestToken(
            parameters: [
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": env.oauth.redirectURI.absoluteString,
                "client_id": env.oauth.clientID
            ],
            env: env,
            session: session,
            previousRefreshToken: nil
        )
        try store.save(pair)
    }

    func hasSession() -> Bool {
        guard let pair = store.load() else { return false }
        return !pair.refreshToken.isEmpty
    }

    func signOut() {
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        store.clear()
    }

    // MARK: - Private

    private static func requestToken(
        parameters: [String: String],
        env: AppEnvironment,
        session: URLSession,
        previousRefreshToken: String?
    ) async throws -> TokenPair {
        var request = URLRequest(url: env.oauth.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(parameters).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw APIError.refreshFailed("token 端点返回 HTTP \(status)：\(body)")
        }

        let tokenResponse = try JSONCoding.decode(TokenResponse.self, from: data)
        return try tokenResponse.makeTokenPair(previousRefreshToken: previousRefreshToken)
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}
