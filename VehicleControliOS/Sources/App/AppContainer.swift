import Foundation
import SwiftUI

/// 组合根：集中装配配置、鉴权、网络与业务服务，视图层只依赖协议。
@MainActor
final class AppContainer: ObservableObject {
    let environment: AppEnvironment
    let tokenStore: KeychainTokenStore
    let auth: AuthService
    let session: SessionStore
    let vehicleService: any VehicleServicing
    let vehicleStream: any VehicleStreaming
    let receiptResolver: any CommandReceiptResolving
    let snapshotCache: SnapshotCache
    let backgroundRefresher: BackgroundRefresher

    private let client: APIClient
    private var didBootstrap = false

    init(environment: AppEnvironment = .current) {
        self.environment = environment

        let store = KeychainTokenStore(service: "com.vehiclecontrol.app.oauth")
        let auth = AuthService(env: environment, store: store)
        let client = APIClient(baseURL: environment.apiBaseURL, tokenProvider: auth)
        let service = RemoteVehicleService(client: client)
        let cache = SnapshotCache()

        self.client = client
        self.tokenStore = store
        self.auth = auth
        self.session = SessionStore(env: environment, auth: auth)
        self.vehicleService = service
        self.vehicleStream = HybridVehicleStream(
            client: client,
            environment: environment,
            tokenProvider: auth
        )
        self.snapshotCache = cache
        self.backgroundRefresher = BackgroundRefresher(service: service, cache: cache)

        // 推送可用时回执走“推送优先 + 轮询兜底”，否则纯轮询。
        if environment.pushEnabled {
            self.receiptResolver = PushFirstReceiptResolver(
                inbox: PushCoordinator.shared.commandInbox,
                service: service
            )
        } else {
            self.receiptResolver = PollingReceiptResolver(service: service)
        }
    }

    /// 启动期一次性装配：注册后台任务、按需开启推送链路。
    /// 必须在 didFinishLaunching 结束前调用（由 RootView 的 .task 触发）。
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        backgroundRefresher.register()

        guard environment.pushEnabled else { return }

        let client = self.client
        let bundleId = Bundle.main.bundleIdentifier
        PushCoordinator.shared.configure { deviceToken in
            _ = try await client.send(
                VehicleAPI.registerPushToken(deviceToken: deviceToken, bundleId: bundleId)
            )
        }
        PushCoordinator.shared.requestAuthorization()
    }
}
