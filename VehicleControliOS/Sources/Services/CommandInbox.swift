import Foundation

/// APNs 推送回执的“信箱”。
///
/// 指令下发后先挂起等待（`wait`），服务端通过 APNs 把终态推回来时
/// 由 `AppDelegate` 投递到 `deliver`，从而把「轮询」换成「事件驱动」。
/// 推送先于等待到达时先缓存，避免时序竞争导致丢结果。
actor CommandInbox {
    private var waiters: [String: CheckedContinuation<CommandReceipt, Error>] = [:]
    private var delivered: [CommandReceipt] = []
    private let capacity = 20

    func deliver(_ receipt: CommandReceipt) {
        if let waiter = waiters.removeValue(forKey: receipt.ticketId) {
            waiter.resume(returning: receipt)
            return
        }
        delivered.removeAll { $0.ticketId == receipt.ticketId }
        delivered.append(receipt)
        if delivered.count > capacity {
            delivered.removeFirst(delivered.count - capacity)
        }
    }

    func wait(for ticketId: String, timeout: TimeInterval) async throws -> CommandReceipt {
        if let index = delivered.firstIndex(where: { $0.ticketId == ticketId }) {
            return delivered.remove(at: index)
        }

        return try await withCheckedThrowingContinuation { continuation in
            if let duplicated = waiters[ticketId] {
                duplicated.resume(throwing: APIError.commandFailed("同一指令被重复等待"))
                waiters[ticketId] = nil
            }
            waiters[ticketId] = continuation

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                await self?.expire(ticketId)
            }
        }
    }

    /// 取消等待（页面退出时调用），让 continuation 不再悬挂到超时。
    func cancel(ticketId: String) {
        guard let waiter = waiters.removeValue(forKey: ticketId) else { return }
        waiter.resume(throwing: APIError.cancelled)
    }

    private func expire(_ ticketId: String) {
        guard let waiter = waiters.removeValue(forKey: ticketId) else { return }
        waiter.resume(throwing: APIError.commandFailed("未在限定时间内收到推送回执"))
    }
}

/// APNs 自定义字段（服务端下发的 aps 之外的自定义 payload）。
///
/// ```json
/// { "aps": { "alert": { "body": "后备箱已解锁" }, "sound": "default" },
///   "cmd_result": { "ticket_id": "T-123", "status": "succeeded" } }
/// ```
struct PushPayload: Sendable {
    let ticketId: String
    let status: CommandStatus
    let failureReason: String?

    init?(userInfo: [AnyHashable: Any]) {
        // aps 的 userInfo 是 [AnyHashable: Any]，需条件转换后才能用 String 下标。
        let dictionary = (userInfo["cmd_result"] as? [String: Any])
            ?? (userInfo as? [String: Any])
            ?? [:]
        guard let ticketId = dictionary["ticket_id"] as? String,
              let rawStatus = dictionary["status"] as? String else {
            return nil
        }
        self.ticketId = ticketId
        self.status = CommandStatus(rawValue: rawStatus.lowercased()) ?? .unknown
        self.failureReason = dictionary["failure_reason"] as? String
    }

    var receipt: CommandReceipt {
        CommandReceipt(
            ticketId: ticketId,
            status: status,
            failureReason: failureReason,
            completedAt: nil
        )
    }
}
