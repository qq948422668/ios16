import AuthenticationServices
import UIKit

/// 使用系统 Web 登录（ASWebAuthenticationSession）承载 OAuth 授权码流程：
/// 不内嵌 WebView、不接触用户密码，复用 Safari 的 SSO 与 Cookie 会话。
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: APIError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session

            guard session.start() else {
                continuation.resume(throwing: APIError.invalidRequest("无法启动系统授权会话"))
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return keyWindow ?? scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}
