import Foundation

/// OAuth 2.0 授权码 + PKCE 所需的全部配置。
struct OAuthConfiguration: Sendable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientID: String
    let redirectURI: URL
    let scopes: [String]

    /// 与 Info.plist 中 CFBundleURLSchemes 必须一致。
    var redirectScheme: String { redirectURI.scheme ?? "" }
}

/// 运行环境配置。所有域名、ClientID 均为占位值，
/// 接入时请替换为你方开放平台下发的真实参数。
struct AppEnvironment: Sendable {
    let name: String
    let apiBaseURL: URL
    let streamBaseURL: URL
    let oauth: OAuthConfiguration
    /// 长连接不可用时的兜底轮询间隔（秒）。
    let pollingInterval: TimeInterval
    /// 是否启用 APNs 推送回执。为 false 时指令回执全程走轮询，
    /// 无需申请 Push Notifications capability，便于模拟器联调。
    let pushEnabled: Bool

    static let production = AppEnvironment(
        name: "production",
        apiBaseURL: URL(string: "https://api.example-oem.invalid")!,
        streamBaseURL: URL(string: "wss://api.example-oem.invalid")!,
        oauth: OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://auth.example-oem.invalid/oauth2/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example-oem.invalid/oauth2/token")!,
            clientID: "REPLACE_WITH_OFFICIAL_CLIENT_ID",
            redirectURI: URL(string: "com.vehiclecontrol.app://oauth/callback")!,
            scopes: ["vehicle.read", "vehicle.control"]
        ),
        pollingInterval: 3,
        pushEnabled: false
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
            oauth: OAuthConfiguration(
                authorizationEndpoint: baseURL.appendingPathComponent("oauth2/authorize"),
                tokenEndpoint: baseURL.appendingPathComponent("oauth2/token"),
                clientID: "ios-mock-client",
                redirectURI: URL(string: "com.vehiclecontrol.app://oauth/callback")!,
                scopes: ["vehicle.read", "vehicle.control"]
            ),
            pollingInterval: 2,
            pushEnabled: false
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
