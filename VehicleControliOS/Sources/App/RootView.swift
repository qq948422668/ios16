import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        Group {
            switch session.state {
            case .launching:
                LaunchView()
            case .signedOut, .authorizing:
                LoginView()
            case .signedIn:
                VehicleListView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .task { await session.restore() }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
            ProgressView()
            Text("正在恢复登录状态…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
