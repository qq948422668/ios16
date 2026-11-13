import Foundation
import os

/// 官方账号认证中心（短信验证码直连，不经网页）。
///
/// 完整链路（文档 §3）：
/// 1. `GET {appUserHost}/app-user/applogin/compliance/sendmessagecode?phoneNo=RSA(phone)`
/// 2. `POST {appUserHost}/app-user/applogin/check_login_with_phone?...&signStr=MD5截断`
///    → `appLoginVO{accountId, token, refreshToken}`
/// 3. `POST {gatewayHost}/base/base-user/account/v1/login`
///    body `{identifier, identifierType:"1", security:旧token}` → `accessToken + signParam{r2,r3}`
/// 4. `signKey = JWT尾段 ⊕ r2 ⊕ r3`，之后所有网关请求走 HMAC-SHA256 签名。
///
/// actor 保证 401 触发的续期只会有一个在飞行中，避免 refresh token 轮换竞争。
actor AuthService: TokenProviding, GatewaySignKeyProviding {
    private let env: AppEnvironment
    private let store: any TokenStoring
    private let session: URLSession
    private var inFlightRefresh: Task<TokenPair, Error>?

    init(env: AppEnvironment, store: any TokenStoring, session: URLSession = .shared) {
        self.env = env
        self.store = store
        self.session = session
    }

    // MARK: - 登录第一步：发送验证码

    func sendSmsCode(phone: String) async throws {
        guard Self.isValidPhone(phone) else { throw LeapAuthError.invalidPhone }
        let cipher = try LeapCrypto.encryptPhone(phone)

        var components = URLComponents(
            url: env.leap.appUserHost.appendingPathComponent(
                "app-user/applogin/compliance/sendmessagecode"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "phoneNo", value: cipher)]
        guard let url = components?.url else {
            throw LeapAuthError.transport("验证码地址组装失败")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        applyLegacyHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        try Self.validateHTTP(response, data: data)
        let envelope = try Self.decode(LeapEnvelope<LeapEmptyPayload>.self, from: data)
        guard envelope.isSuccess else {
            Self.logBusinessFailure(.sendCode, envelope: envelope, body: data)
            throw LeapAuthError.business(
                stage: .sendCode,
                code: envelope.code ?? envelope.result ?? -1,
                message: envelope.message
            )
        }
    }

    // MARK: - 登录第二步 + 第三步：短信登录并换取网关凭证

    func signIn(phone: String, smsCode: String) async throws -> LeapSessionSummary {
        guard Self.isValidPhone(phone) else { throw LeapAuthError.invalidPhone }
        guard smsCode.count == 6, smsCode.allSatisfy(\.isNumber) else {
            throw LeapAuthError.invalidSmsCode
        }

        let cipher = try LeapCrypto.encryptPhone(phone)
        let legacy = try await appLogin(phoneCiphertext: cipher, smsCode: smsCode)
        let pair = try await exchangeGateway(legacy: legacy, phone: phone)
        try store.save(pair)

        return LeapSessionSummary(
            accountID: pair.accountId ?? legacy.accountId ?? phone,
            accessTokenExpiresAt: pair.expiresAt
        )
    }

    /// 旧版短信登录（Query 传参 + MD5 截断签名）。
    private func appLogin(
        phoneCiphertext: String,
        smsCode: String
    ) async throws -> AppLoginVO {
        var params: [String: String] = [
            "phoneNoCiphertext": phoneCiphertext,
            "smsCode": smsCode,
            "deviceID": DeviceIdentity.current(),
            "smDeviceId": DeviceIdentity.current(),
            // 文档 §3 接口 2：os 固定值 "android"，服务端校验非 android 直接拒绝。
            "os": "android",
            "pageUrl": "",
            "timespan": String(Int64(Date().timeIntervalSince1970 * 1000)),
            "nonce": String(Int.random(in: 10_000..<10_000_000))
        ]
        params["signStr"] = LeapCrypto.md5Short(LeapCrypto.signBase(params))

        var components = URLComponents(
            url: env.leap.appUserHost.appendingPathComponent(
                "app-user/applogin/check_login_with_phone"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = params.keys.sorted().map {
            URLQueryItem(name: $0, value: params[$0])
        }
        guard let url = components?.url else {
            throw LeapAuthError.transport("登录地址组装失败")
        }

        // 业务参数全部在 Query 上，Body 保持为空（文档 §3 接口 2）。
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data()
        applyLegacyHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport(request)
        try Self.validateHTTP(response, data: data)
        let envelope = try Self.decode(LeapEnvelope<AppLoginPayload>.self, from: data)
        guard envelope.isSuccess else {
            Self.logBusinessFailure(.signIn, envelope: envelope, body: data)
            throw LeapAuthError.business(
                stage: .signIn,
                code: envelope.code ?? envelope.result ?? -1,
                message: envelope.message
            )
        }
        guard let payload = envelope.data?.appLoginVO else {
            throw LeapAuthError.missingTokens("data.appLoginVO")
        }
        guard let token = payload.token, !token.isEmpty else {
            throw LeapAuthError.missingTokens("appLoginVO.token")
        }
        return payload
    }

    /// 换取新网关凭证（未登录态：`sign = SHA256(signBase)`）。
    private func exchangeGateway(legacy: AppLoginVO, phone: String) async throws -> TokenPair {
        guard let legacyToken = legacy.token, !legacyToken.isEmpty else {
            throw LeapAuthError.missingTokens("appLoginVO.token")
        }
        let identifier = legacy.accountId ?? phone
        let body: [String: String] = [
            "identifier": identifier,
            "identifierType": "1",
            "security": legacyToken
        ]

        let signer = GatewaySigner(configuration: env.leap, deviceId: DeviceIdentity.current())
        let headers = signer.headers(params: body, accessToken: nil, signKey: nil)

        var request = URLRequest(
            url: env.leap.gatewayHost.appendingPathComponent(
                "base/base-user/account/v1/login"),
            timeoutInterval: 25
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONCoding.encode(body)

        let (data, response) = try await transport(request)
        try Self.validateHTTP(response, data: data)

        let envelope = try Self.decode(LeapEnvelope<GatewayLoginPayload>.self, from: data)
        guard envelope.isSuccess else {
            Self.logBusinessFailure(.signIn, envelope: envelope, body: data)
            throw LeapAuthError.business(
                stage: .signIn,
                code: envelope.code ?? envelope.result ?? -1,
                message: envelope.message
            )
        }
        guard let payload = envelope.data,
              let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw LeapAuthError.missingTokens("data.accessToken")
        }
        guard let refreshToken = payload.refreshToken, !refreshToken.isEmpty else {
            throw LeapAuthError.missingTokens("data.refreshToken")
        }

        let signKey = LeapCrypto.deriveSignKey(
            accessToken: accessToken,
            r2: payload.signParam?.r2 ?? "",
            r3: payload.signParam?.r3 ?? ""
        )
        guard let signKey else {
            throw LeapAuthError.missingTokens("data.signParam{r2,r3}")
        }

        let expiresAt = payload.tokenExpireTime
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Date().addingTimeInterval(21_600)

        return TokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: "Bearer",
            scope: nil,
            accountId: payload.accountId ?? identifier,
            legacyToken: legacyToken,
            legacyRefreshToken: legacy.refreshToken,
            signKey: signKey.base64EncodedString()
        )
    }

    // MARK: - TokenProviding

    func accessToken() async throws -> String {
        guard let pair = store.load() else { throw APIError.notAuthenticated }
        if pair.isExpiringSoon {
            try await forceRefresh()
            guard let refreshed = store.load() else { throw APIError.notAuthenticated }
            return refreshed.accessToken
        }
        return pair.accessToken
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
            let pair = try await self.refreshGatewayToken(current)
            try self.store.save(pair)
            return pair
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }

        do {
            _ = try await task.value
        } catch {
            if let authError = error as? LeapAuthError {
                throw APIError.refreshFailed(authError.userMessage)
            }
            throw APIError.refreshFailed(error.localizedDescription)
        }
    }

    /// 新网关 Token 续期（已登录态：HMAC-SHA256 签名）。
    private func refreshGatewayToken(_ current: TokenPair) async throws -> TokenPair {
        let body = ["refreshToken": current.refreshToken]
        let signKey = current.signKey.flatMap { Data(base64Encoded: $0) }
        let signer = GatewaySigner(configuration: env.leap, deviceId: DeviceIdentity.current())
        let headers = signer.headers(
            params: body,
            accessToken: current.accessToken,
            signKey: signKey
        )

        var request = URLRequest(
            url: env.leap.gatewayHost.appendingPathComponent(
                "base/base-user/token/v1/refresh"),
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONCoding.encode(body)

        let (data, response) = try await transport(request)
        try Self.validateHTTP(response, data: data)

        let envelope = try Self.decode(LeapEnvelope<GatewayLoginPayload>.self, from: data)
        guard envelope.isSuccess else {
            if envelope.code == 401 || envelope.code == 403 {
                store.clear()
            }
            Self.logBusinessFailure(.refresh, envelope: envelope, body: data)
            throw LeapAuthError.business(
                stage: .refresh,
                code: envelope.code ?? envelope.result ?? -1,
                message: envelope.message
            )
        }
        guard let payload = envelope.data,
              let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw LeapAuthError.missingTokens("data.accessToken")
        }

        let refreshToken = payload.refreshToken ?? current.refreshToken
        let newSignKey = LeapCrypto.deriveSignKey(
            accessToken: accessToken,
            r2: payload.signParam?.r2 ?? "",
            r3: payload.signParam?.r3 ?? ""
        )?.base64EncodedString() ?? current.signKey

        let expiresAt = payload.tokenExpireTime
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Date().addingTimeInterval(21_600)

        return TokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: current.tokenType,
            scope: current.scope,
            accountId: payload.accountId ?? current.accountId,
            legacyToken: current.legacyToken,
            legacyRefreshToken: current.legacyRefreshToken,
            signKey: newSignKey
        )
    }

    func hasSession() -> Bool {
        guard let pair = store.load() else { return false }
        return !pair.accessToken.isEmpty && !pair.refreshToken.isEmpty
    }

    func signOut() {
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        store.clear()
    }

    func currentSignKey() async -> Data? {
        store.load()?.signKey.flatMap { Data(base64Encoded: $0) }
    }

    // MARK: - Helpers

    private static func isValidPhone(_ phone: String) -> Bool {
        phone.count == 11 && phone.allSatisfy(\.isNumber) && phone.hasPrefix("1")
    }

    private func applyLegacyHeaders(_ request: inout URLRequest) {
        let version = env.leap.clientVersion
        // 文档 §3 接口 1：APPPlatform 固定 Android（服务端按平台校验）。
        request.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        request.setValue("Android", forHTTPHeaderField: "APPPlatform")
        request.setValue(version, forHTTPHeaderField: "APPVersion")
        request.setValue(DeviceIdentity.current(), forHTTPHeaderField: "APPImei")
        request.setValue("APP", forHTTPHeaderField: "C-VERSIONS")
        request.setValue("v4", forHTTPHeaderField: "XFX-CDN-VRS")
    }

    private func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as URLError {
            if error.code == .cancelled { throw APIError.cancelled }
            throw LeapAuthError.transport(error.localizedDescription)
        } catch {
            throw LeapAuthError.transport(error.localizedDescription)
        }
    }

    /// 业务码失败时的现场证据：只记录码与 message 原文，不含手机号密文与令牌。
    private static func logBusinessFailure<P: Decodable>(
        _ stage: AuthStage,
        envelope: LeapEnvelope<P>,
        body: Data
    ) {
        Logger(subsystem: "com.vehiclecontrol.app", category: "auth")
            .error("业务失败 [\(stage.rawValue, privacy: .public)] code=\(envelope.code.map(String.init) ?? "nil", privacy: .public) result=\(envelope.result.map(String.init) ?? "nil", privacy: .public) message=\(envelope.message ?? "nil", privacy: .public) body=\(String(data: body.prefix(200), encoding: .utf8) ?? "non-utf8", privacy: .public)")
    }

    private static func validateHTTP(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LeapAuthError.http(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decode(type, from: data)
        } catch {
            throw LeapAuthError.decoding(error.localizedDescription)
        }
    }
}

/// 空 payload 占位（`data: null` 的接口）。
struct LeapEmptyPayload: Decodable {}
