import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 零跑车联网协议所需的密码学原语。
///
/// 依据官方协议文档（API v3.6.8）：
/// - 手机号 `RSA/ECB/PKCS1Padding` 加密，输出 Base64URL 且去掉 `=` 填充；
/// - 旧链路签名 `MD5(signBase)[8..<24]` 大写十六进制；
/// - 新网关签名 `HmacSHA256(signKey, signBase)` 或未登录态 `SHA256(signBase)`；
/// - 操作密码 `AES-128-CBC`，Key/IV 由 Token 前后两段各取 MD5 截断派生。
enum LeapCrypto {
    /// 手机号加密公钥（X.509 SubjectPublicKeyInfo，Base64）。
    static let phonePublicKeyBase64 = """
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8\
    ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBl\
    zK7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB
    """

    // MARK: - 手机号 RSA

    /// 手机号密文：RSA/PKCS1 + Base64URL（去 `=`）。
    static func encryptPhone(_ phone: String) throws -> String {
        guard let key = phonePublicKey() else {
            throw LeapCryptoError.publicKeyUnavailable
        }
        let algorithm = SecKeyAlgorithm.rsaEncryptionPKCS1
        guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
            throw LeapCryptoError.rsaUnsupported
        }

        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            key,
            algorithm,
            Data(phone.utf8) as CFData,
            &error
        ) else {
            throw LeapCryptoError.rsaFailed(
                (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown")
        }
        return base64URL(cipher as Data)
    }

    private static func phonePublicKey() -> SecKey? {
        guard let der = Data(base64Encoded: phonePublicKeyBase64, options: [.ignoreUnknownCharacters])
        else { return nil }

        // SPKI → PKCS#1：定位 BIT STRING（03 81 8D 00 / 03 82 xx xx 00），
        // 其后 141 字节即 RSAPublicKey SEQUENCE（1024 位模数 + 指数）。
        let markers = [Data([0x03, 0x81, 0x8D, 0x00]), Data([0x03, 0x82, 0x01, 0x0F, 0x00])]
        guard let marker = markers.first(where: { der.range(of: $0) != nil }),
              let range = der.range(of: marker) else { return nil }

        let keyLength = 141
        let start = range.upperBound
        guard start + keyLength <= der.count else { return nil }
        // 跳过 BIT STRING 的「未使用位数」字节。
        let pkcs1 = der.subdata(in: (start + 1)..<(start + keyLength))

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]
        return SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil)
    }

    // MARK: - 摘要与签名

    /// 旧链路签名：MD5 十六进制小写取第 8..<24 位，转大写。
    static func md5Short(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex.count >= 24 else {
            return hex.uppercased()
        }
        let start = hex.index(hex.startIndex, offsetBy: 8)
        let end = hex.index(hex.startIndex, offsetBy: 24)
        return String(hex[start..<end]).uppercased()
    }

    static func sha256Hex(_ input: String) -> String {
        hex(SHA256.hash(data: Data(input.utf8)).map { UInt8($0) })
    }

    static func hmacSHA256Hex(key: Data, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return hex(Array(mac))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ data: Data) -> String {
        hex([UInt8](data))
    }

    // MARK: - Base64URL

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }

    // MARK: - 新网关 signKey 派生

    /// signKey[i] = JWT 尾段[i] ^ r2[i] ^ r3[i]（取三者最短长度）。
    static func deriveSignKey(accessToken: String, r2: String, r3: String) -> Data? {
        let segments = accessToken.split(separator: ".")
        guard segments.count == 3,
              let tail = base64URLDecode(String(segments[2])),
              let first = base64URLDecode(r2),
              let second = base64URLDecode(r3) else { return nil }

        let count = min(tail.count, min(first.count, second.count))
        guard count > 0 else { return nil }

        var key = [UInt8](repeating: 0, count: count)
        let tailBytes = [UInt8](tail)
        let firstBytes = [UInt8](first)
        let secondBytes = [UInt8](second)
        for index in 0..<count {
            key[index] = tailBytes[index] ^ firstBytes[index] ^ secondBytes[index]
        }
        return Data(key)
    }

    // MARK: - 操作密码 AES-128-CBC

    /// 4 位操作密码加密：Key = md5Short(token[0..<32])，IV = md5Short(token[32..<64])。
    static func encryptOperationPassword(_ password: String, token: String) throws -> String {
        let padded = token.count >= 64 ? token : token + token
        guard padded.count >= 64 else {
            throw LeapCryptoError.tokenTooShort
        }
        let keyString = md5Short(String(padded.prefix(32)))
        let ivString = md5Short(String(padded.dropFirst(32).prefix(32)))
        let key = Data(keyString.utf8)
        let iv = Data(ivString.utf8)

        var outLength = 0
        var out = [UInt8](repeating: 0, count: password.utf8.count + kCCBlockSizeAES128)
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            [UInt8](key), key.count,
            [UInt8](iv),
            [UInt8](password.utf8), password.utf8.count,
            &out, out.count,
            &outLength
        )
        guard status == kCCSuccess else {
            throw LeapCryptoError.aesFailed(Int32(status))
        }
        return Data(out.prefix(outLength)).base64EncodedString()
    }

    // MARK: - 签名基串

    /// 按键名 ASCII 升序拼接 `key + value`（空值保留）。
    static func signBase(_ params: [String: String]) -> String {
        params.keys.sorted().reduce(into: "") { result, key in
            result += key
            result += params[key] ?? ""
        }
    }
}

enum LeapCryptoError: LocalizedError {
    case publicKeyUnavailable
    case rsaUnsupported
    case rsaFailed(String)
    case tokenTooShort
    case aesFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .publicKeyUnavailable: return "内置公钥无法解析"
        case .rsaUnsupported: return "当前设备不支持 RSA/PKCS1 加密"
        case .rsaFailed(let detail): return "手机号加密失败：\(detail)"
        case .tokenTooShort: return "令牌长度不足，无法派生 AES 密钥"
        case .aesFailed(let status): return "操作密码加密失败（CCCrypt \(status)）"
        }
    }
}
