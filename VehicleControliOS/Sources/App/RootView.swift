import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var updateChecker: UpdateChecker

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
        .task { await updateChecker.check() }
        .alert(item: $updateChecker.announcement) { announcement in
            Alert(
                title: Text(announcement.kind == .required
                            ? "需要更新"
                            : "发现新版本"),
                message: Text(updateMessage(announcement)),
                dismissButton: .default(Text(announcement.kind == .required
                                             ? "去更新"
                                             : "知道了")))
        }
    }

    private func updateMessage(_ announcement: UpdateAnnouncement) -> String {
        var lines: [String] = []
        lines.append("最新版本 v\(announcement.info.latestVersion)，当前 v\(currentVersion)")
        if let notes = announcement.info.notes, !notes.isEmpty {
            lines.append(notes)
        }
        if announcement.kind == .required {
            lines.append("当前版本过低，必须更新后才能继续使用。")
        }
        return lines.joined(separator: "\n")
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
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
