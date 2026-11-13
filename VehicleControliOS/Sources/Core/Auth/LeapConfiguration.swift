import Foundation

/// 零跑车联网接入参数（依据官方协议文档 v3.6.8）。
///
/// 双网关结构：
/// - `appUserHost`：验证码下发、旧版短信登录、旧 Token 续期（`appuser.leapmotor.cn`）；
/// - `gatewayHost`：新网关登录交换、Token 续期、业务 API（`app-gw-global-master`）。
struct LeapConfiguration: Sendable {
    let appUserHost: URL
    let gatewayHost: URL
    /// 参与网关签名的客户端版本号（`version` 头）。
    let clientVersion: String
    /// 渠道号（`channel` 头）。
    let channel: String
    /// 设备类型（`deviceType` 头）。Android 客户端为 `android`。
    let deviceType: String

    static let official = LeapConfiguration(
        appUserHost: URL(string: "https://appuser.leapmotor.cn")!,
        gatewayHost: URL(string: "https://app-gw-global-master.leapmotor.com")!,
        clientVersion: "1.5.50",
        channel: "1",
        deviceType: "ios"
    )

    static func mock(baseURL: URL) -> LeapConfiguration {
        LeapConfiguration(
            appUserHost: baseURL,
            gatewayHost: baseURL,
            clientVersion: "1.5.50",
            channel: "1",
            deviceType: "ios"
        )
    }
}

/// 稳定的设备标识：32 位十六进制（与 Android 端 deviceID 等价）。
enum DeviceIdentity {
    private static let key = "com.vehiclecontrol.app.deviceId"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: key), stored.count == 32 {
            return stored
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }
}
