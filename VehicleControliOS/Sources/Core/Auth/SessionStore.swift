import AuthenticationServices
import Combine
import Foundation

/// 面向 UI 的登录状态机。
@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case launching
        case signedOut
        case authorizing
        case signedIn
    }

    @Published private(set) var state: State = .launching
    @Published private(set) var errorMessage: String?

    private let env: AppEnvironment
    private let auth: AuthService
    private let authenticator = WebAuthenticator()
    private var didRestore = false

    init(env: AppEnvironment, auth: AuthService) {
        self.env = env
        self.auth = auth
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        let hasSession = await auth.hasSession()
        state = hasSession ? .signedIn : .signedOut
    }

    func signIn() async {
        guard state != .authorizing else { return }
        state = .authorizing
        errorMessage = nil

        do {
            let pkce = PKCE.generate()
            var components = URLComponents(
                url: env.oauth.authorizationEndpoint,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: env.oauth.clientID),
                URLQueryItem(name: "redirect_uri", value: env.oauth.redirectURI.absoluteString),
                URLQueryItem(name: "scope", value: env.oauth.scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: UUID().uuidString)
            ]

            guard let authorizationURL = components?.url else {
                throw APIError.invalidRequest("授权 URL 组装失败")
            }

            let callbackURL = try await authenticator.authenticate(
                authorizationURL: authorizationURL,
                callbackScheme: env.oauth.redirectScheme
            )

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "code" })?
                .value else {
                throw APIError.invalidRequest("授权回调缺少 code 参数")
            }

            try await auth.exchangeAuthorizationCode(code: code, verifier: pkce.verifier)
            state = .signedIn
        } catch {
            if Self.isUserCancellation(error) {
                state = .signedOut
                return
            }
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            state = .signedOut
        }
    }

    /// 用户在系统登录面板点“取消”不算错误，静默回到未登录态。
    private static func isUserCancellation(_ error: Error) -> Bool {
        if let apiError = error as? APIError, case .cancelled = apiError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionErrorDomain
            && nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    }

    func signOut() async {
        await auth.signOut()
        errorMessage = nil
        state = .signedOut
    }
}
