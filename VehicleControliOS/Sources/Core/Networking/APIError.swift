import Foundation

/// 统一错误分层：传输层 / 鉴权层 / 服务端业务码 / 解码 / 指令执行。
enum APIError: Error {
    case notAuthenticated
    case unauthorized
    case refreshFailed(String)
    case transport(URLError)
    case server(status: Int, code: String?, message: String?)
    case decoding(String)
    case invalidRequest(String)
    case cancelled
    case commandFailed(String)

    /// 只有幂等的 GET 请求会走到这里，指令请求本身使用 RetryPolicy.none。
    var isRetryable: Bool {
        switch self {
        case .transport(let error):
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        case .server(let status, _, _):
            return status == 408 || status == 429 || (500..<600).contains(status)
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "登录状态已失效，请重新登录。"
        case .unauthorized:
            return "无权限访问该资源，请重新授权。"
        case .refreshFailed(let detail):
            return "刷新登录凭证失败：\(detail)"
        case .transport(let error):
            return "网络异常：\(error.localizedDescription)"
        case .server(let status, let code, let message):
            let suffix = [code, message].compactMap { $0 }.joined(separator: " / ")
            return suffix.isEmpty ? "服务返回异常（HTTP \(status)）。" : "服务返回异常（HTTP \(status)）：\(suffix)"
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .invalidRequest(let detail):
            return "请求无法构建：\(detail)"
        case .cancelled:
            return "请求已取消。"
        case .commandFailed(let reason):
            return "指令执行失败：\(reason)"
        }
    }
}

extension APIError: LocalizedError {
    var errorDescription: String? { userMessage }
}

/// 服务端统一错误信封（字段名按你方规范调整）。
struct APIErrorEnvelope: Decodable {
    let code: String?
    let message: String?
}
