import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// 指数退避 + 抖动。车控指令类请求应使用 `.none`，由业务层显式重试
/// （配合 Idempotency-Key），避免网络层静默重复下发。
struct RetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)
    static let standard = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 5)

    /// 返回第 `attempt` 次失败后应等待的时长，`nil` 表示不再重试。
    func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts, baseDelay > 0 else { return nil }
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0...(exponential * 0.25))
        return min(exponential + jitter, maxDelay)
    }
}
