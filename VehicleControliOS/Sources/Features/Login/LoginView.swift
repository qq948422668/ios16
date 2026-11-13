import SwiftUI

/// 官方账号登录：手机号 + 短信验证码，全部走接口直连，不再打开任何网页。
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @FocusState private var focusedField: Field?

    private enum Field {
        case phone
        case code
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.tint)

                Text("车辆远程控制")
                    .font(.largeTitle.bold())

                Text("使用零跑官方账号登录：手机号获取短信验证码后直接完成鉴权，全程在本应用内提交，不依赖网页。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                phoneField
                codeField

                if let notice = session.noticeMessage {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = session.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                loginButton

                Text("验证码由零跑官方服务下发；若提示发送频繁，请等待 60 秒后重试。账号需已开通车联网服务并绑定车辆。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 子视图

    private var phoneField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("手机号").font(.footnote).foregroundStyle(.secondary)
            TextField("11 位手机号", text: $session.phoneNumber)
                .keyboardType(.numberPad)
                .textContentType(.telephoneNumber)
                .focused($focusedField, equals: .phone)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: session.phoneNumber) { newValue in
                    // 只保留数字，长度截到 11 位。
                    let filtered = String(newValue.filter(\.isNumber).prefix(11))
                    if filtered != newValue {
                        session.phoneNumber = filtered
                    }
                }
        }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("短信验证码").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("6 位数字验证码", text: $session.smsCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .code)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: session.smsCode) { newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue {
                            session.smsCode = filtered
                        }
                    }

                Button {
                    Task { await session.sendSmsCode() }
                } label: {
                    Text(sendCodeTitle)
                        .font(.footnote.weight(.semibold))
                        .frame(width: 96)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)
                .disabled(!session.canSendCode)
            }
        }
    }

    private var sendCodeTitle: String {
        if session.resendCountdown > 0 {
            return "\(session.resendCountdown)s 后重发"
        }
        return "获取验证码"
    }

    private var loginButton: some View {
        Button {
            focusedField = nil
            Task { await session.signIn() }
        } label: {
            HStack(spacing: 8) {
                if session.state == .authorizing {
                    ProgressView().tint(.white)
                }
                Text(session.state == .authorizing ? "正在登录…" : "登录并进入车控")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!session.canSubmit)
    }
}
