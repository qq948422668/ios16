import CryptoKit
import Foundation
import Security

struct PKCEPair: Sendable {
    let verifier: String
    let challenge: String
}

/// RFC 7636 S256：公开客户端不得内置 client_secret，必须走 PKCE。
enum PKCE {
    private static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func generate(verifierLength: Int = 64) -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: verifierLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = String(bytes.map { unreserved[Int($0) % unreserved.count] })
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
