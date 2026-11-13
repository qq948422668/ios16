import Foundation

/// 新网关请求签名（`x-api-signature-version: 2.0`）。
///
/// 规则（文档 §2.3）：
/// 1. 固定头 + 业务参数按键名 ASCII 升序拼成 `signBase`（key 紧跟 value，无分隔符）；
/// 2. 已登录：`HmacSHA256(signKey, signBase)`；未登录（如换网关凭证）：`SHA256(signBase)`；
/// 3. 结果以小写十六进制放入 `sign` 头。
struct GatewaySigner: Sendable {
    let configuration: LeapConfiguration
    let deviceId: String

    func headers(
        params: [String: String],
        accessToken: String?,
        signKey: Data?
    ) -> [String: String] {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = String(Int.random(in: 10_000..<10_000_000))

        var signable: [String: String] = [
            "acceptLanguage": "zh-CN",
            "channel": configuration.channel,
            "deviceId": deviceId,
            "deviceType": configuration.deviceType,
            "nonce": nonce,
            "source": "leapmotor",
            "timestamp": timestamp,
            "version": configuration.clientVersion
        ]
        signable.merge(params) { _, new in new }

        let base = LeapCrypto.signBase(signable)
        let signature: String
        if let accessToken, !accessToken.isEmpty, let signKey {
            _ = accessToken
            signature = LeapCrypto.hmacSHA256Hex(key: signKey, message: base)
        } else {
            signature = LeapCrypto.sha256Hex(base)
        }

        var headers = signable
        headers["sign"] = signature
        headers["x-api-signature-version"] = "2.0"
        if let accessToken, !accessToken.isEmpty {
            headers["accessToken"] = accessToken
        }
        return headers
    }
}

/// 供网络层获取签名材料；AuthService 是唯一实现。
protocol GatewaySignKeyProviding: Sendable {
    func currentSignKey() async -> Data?
}
