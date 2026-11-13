import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()

            Image(systemName: "car.side.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.tint)

            Text("车辆远程控制")
                .font(.largeTitle.bold())

            Text("使用厂商官方账号完成授权后，即可查看车辆实时状态并下发控制指令。登录在系统安全浏览器中完成，本应用不会接触你的密码。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await session.signIn() }
            } label: {
                HStack(spacing: 8) {
                    if session.state == .authorizing {
                        ProgressView().tint(.white)
                    }
                    Text(session.state == .authorizing ? "正在授权…" : "使用官方账号登录")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.state == .authorizing)

            Spacer()

            Text("仅支持已开通官方车联网服务的车辆。若车辆未绑定或授权被撤销，接口将返回 401。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}
