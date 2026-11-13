import Foundation
import UIKit
import UserNotifications

/// 推送接入点：负责权限申请、设备令牌上报、把通知里的指令回执送进 `CommandInbox`。
///
/// 用一个进程内单例是为了让 `AppDelegate`（启动早期、由 UIKit 创建、拿不到依赖容器）
/// 能访问到同一个信箱。真正的网络上传器由 `AppContainer` 在启动时注入。
final class PushCoordinator: @unchecked Sendable {
    static let shared = PushCoordinator()

    let commandInbox = CommandInbox()

    private var uploadDeviceToken: (@Sendable (String) async throws -> Void)?

    private init() {}

    func configure(deviceTokenUploader: (@Sendable (String) async throws -> Void)?) {
        uploadDeviceToken = deviceTokenUploader
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func registerDeviceToken(_ data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard let uploadDeviceToken else { return }
        do {
            try await uploadDeviceToken(token)
        } catch {
            // 上报失败不阻断使用：回执会自动退回轮询。
        }
    }

    func handle(payload: PushPayload) async {
        guard payload.status.isTerminal else { return }
        await commandInbox.deliver(payload.receipt)
    }
}
