import Combine
import Foundation

/// 面向 UI 的登录状态机（官方接口直连，无网页加载）。
///
/// 状态迁移：`launching → signedOut → authorizing → signedIn`
/// - `sendSmsCode()`：RSA 加密手机号后请求验证码，成功后启动 60 秒冷却；
/// - `signIn()`：短信登录 + 网关凭证交换，成功后持久化并切到车控页；
/// - 任何失败都把业务码翻译成可读文案写入 `errorMessage`，状态回 `signedOut`。
@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case launching
        case signedOut
        case authorizing
        case signedIn
    }

    @Published var phoneNumber = ""
    @Published var smsCode = ""

    @Published private(set) var state: State = .launching
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var resendCountdown = 0
    @Published private(set) var accountID: String?

    private let auth: AuthService
    private var didRestore = false
    private var countdownTask: Task<Void, Never>?

    init(auth: AuthService) {
        self.auth = auth
    }

    var canSendCode: Bool {
        Self.isValidPhone(phoneNumber) && resendCountdown == 0 && state != .authorizing
    }

    var canSubmit: Bool {
        Self.isValidPhone(phoneNumber)
            && smsCode.count == 6
            && smsCode.allSatisfy(\.isNumber)
            && state != .authorizing
    }

    // MARK: - 启动恢复

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        let hasSession = await auth.hasSession()
        state = hasSession ? .signedIn : .signedOut
    }

    // MARK: - 发送验证码

    func sendSmsCode() async {
        guard state != .authorizing else { return }
        guard Self.isValidPhone(phoneNumber) else {
            errorMessage = LeapAuthError.invalidPhone.userMessage
            return
        }

        errorMessage = nil
        noticeMessage = nil
        state = .authorizing
        defer { if state == .authorizing { state = .signedOut } }

        do {
            try await auth.sendSmsCode(phone: phoneNumber)
            noticeMessage = "验证码已发送至 \(maskedPhone)，5 分钟内有效。"
            startCountdown()
        } catch {
            errorMessage = Self.message(for: error)
            // 频控错误直接进入冷却，避免用户连续点击加剧风控。
            if let authError = error as? LeapAuthError,
               case .business(_, code: 100117, _) = authError {
                startCountdown()
            }
        }
    }

    // MARK: - 登录

    func signIn() async {
        guard state != .authorizing else { return }
        guard Self.isValidPhone(phoneNumber) else {
            errorMessage = LeapAuthError.invalidPhone.userMessage
            return
        }
        guard smsCode.count == 6, smsCode.allSatisfy(\.isNumber) else {
            errorMessage = LeapAuthError.invalidSmsCode.userMessage
            return
        }

        errorMessage = nil
        noticeMessage = nil
        state = .authorizing

        do {
            let summary = try await auth.signIn(phone: phoneNumber, smsCode: smsCode)
            accountID = summary.accountID
            smsCode = ""
            state = .signedIn
        } catch {
            errorMessage = Self.message(for: error)
            state = .signedOut
        }
    }

    func signOut() async {
        countdownTask?.cancel()
        resendCountdown = 0
        await auth.signOut()
        accountID = nil
        smsCode = ""
        errorMessage = nil
        noticeMessage = nil
        state = .signedOut
    }

    // MARK: - Private

    private func startCountdown() {
        countdownTask?.cancel()
        resendCountdown = 60
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.resendCountdown <= 1 {
                    self.resendCountdown = 0
                    return
                }
                self.resendCountdown -= 1
            }
        }
    }

    private var maskedPhone: String {
        guard phoneNumber.count == 11 else { return phoneNumber }
        let head = phoneNumber.prefix(3)
        let tail = phoneNumber.suffix(4)
        return "\(head)****\(tail)"
    }

    private static func isValidPhone(_ phone: String) -> Bool {
        phone.count == 11 && phone.allSatisfy(\.isNumber) && phone.hasPrefix("1")
    }

    private static func message(for error: Error) -> String {
        if let authError = error as? LeapAuthError {
            return authError.userMessage
        }
        if let apiError = error as? APIError {
            return apiError.userMessage
        }
        return error.localizedDescription
    }
}
