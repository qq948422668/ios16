import UIKit
import UserNotifications

/// 只做三件事：设置通知代理、接收 APNs 设备令牌、把回执转交 `PushCoordinator`。
/// 这里刻意不持有业务依赖，避免 App 启动顺序与 SwiftUI 生命周期耦合。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 必须在启动完成前设置，冷启动点击通知时 didReceive 才会回调。
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushCoordinator.shared.registerDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 模拟器或未开通 Push capability 时会走到这里，指令回执自动降级为轮询。
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let payload = PushPayload(userInfo: response.notification.request.content.userInfo) {
            Task { await PushCoordinator.shared.handle(payload: payload) }
        }
        completionHandler()
    }
}
