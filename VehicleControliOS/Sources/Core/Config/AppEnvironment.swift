import Foundation

/// 运行环境配置。
///
/// 认证已从「网页 OAuth 跳转」改为「官方接口直连」：
/// 具体域名、签名算法与公共头集中在 `LeapConfiguration` / `AuthService`。
struct AppEnvironment: Sendable {
    let name: String
    /// 业务网关（新网关，需 HMAC 签名）。
    let apiBaseURL: URL
    let streamBaseURL: URL
    /// 零跑接入参数（appuser 旧链路 + global-master 新网关）。
    let leap: LeapConfiguration
    /// 长连接不可用时的兜底轮询间隔（秒）。
    let pollingInterval: TimeInterval
    /// 是否启用 APNs 推送回执。为 false 时指令回执全程走轮询，
    /// 无需申请 Push Notifications capability，便于模拟器联调。
    let pushEnabled: Bool
    /// OTA 更新清单地址；nil 表示禁用更新检查。
    /// CI 每次成功构建后把 manifest 写入仓库 `.github/ota/manifest.json`。
    let otaManifestURL: URL?

    static let production = AppEnvironment(
        name: "production",
        apiBaseURL: URL(string: "https://app-gw-global-master.leapmotor.com")!,
        streamBaseURL: URL(string: "wss://app-gw-global-master.leapmotor.com")!,
        leap: .official,
        pollingInterval: 3,
        pushEnabled: false,
        otaManifestURL: URL(
            string: "https://raw.githubusercontent.com/qq948422668/ios16/main/.github/ota/manifest.json")!
    )

    /// 指向本地 Mock 服务（Tools/mock-server）。stream 端点按 http→ws 自动推导。
    static func mock(baseURL: URL) -> AppEnvironment {
        var streamURL = baseURL
        if var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            components.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
            streamURL = components.url ?? baseURL
        }
        return AppEnvironment(
            name: "local-mock",
            apiBaseURL: baseURL,
            streamBaseURL: streamURL,
            leap: .mock(baseURL: baseURL),
            pollingInterval: 2,
            pushEnabled: false,
            otaManifestURL: baseURL.host.flatMap { host in
                URL(string: "http://\(host):8000/ota/manifest.json")
            }
        )
    }

    /// 模拟器默认走 127.0.0.1:8000；真机用 `-mockBaseURL http://<Mac 局域网 IP>:8000` 覆盖。
    static let localMock = mock(baseURL: URL(string: "http://127.0.0.1:8000")!)

    /// Xcode Scheme → Run → Arguments 加 `-useMockBackend` 即切到本地 Mock。
    static var current: AppEnvironment {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-useMockBackend") {
            if let index = arguments.firstIndex(of: "-mockBaseURL"),
               index + 1 < arguments.count,
               let baseURL = URL(string: arguments[index + 1]) {
                return .mock(baseURL: baseURL)
            }
            return .localMock
        }
        #endif
        return .production
    }
}
