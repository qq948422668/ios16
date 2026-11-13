import SwiftUI

@main
@MainActor
struct VehicleControlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.session)
                .task { container.bootstrap() }
        }
    }
}
