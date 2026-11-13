import Foundation

/// 指令回执的获取策略。业务层只依赖该协议，
/// 因此“轮询 / 推送 / 后续换成 WebSocket 事件”可以整体替换。
protocol CommandReceiptResolving: Sendable {
    func receipt(
        for ticket: CommandTicket,
        vehicleId: String,
        timeout: TimeInterval
    ) async throws -> CommandReceipt
}

/// 纯轮询：无需 APNs，模拟器也能跑（`pushEnabled = false` 时使用）。
struct PollingReceiptResolver: CommandReceiptResolving {
    let service: any VehicleServicing

    func receipt(
        for ticket: CommandTicket,
        vehicleId: String,
        timeout: TimeInterval
    ) async throws -> CommandReceipt {
        try await service.awaitReceipt(for: ticket, vehicleId: vehicleId, timeout: timeout)
    }
}

/// 推送优先、轮询兜底：
/// 1. 先在 `CommandInbox` 上等待推送，最长 `pushGrace` 秒；
/// 2. 推送没来（用户关闭通知、APNs 抖动、后台被限制）则退回轮询；
/// 3. 两条路径都收敛到同一个终态判定，UI 无感知。
struct PushFirstReceiptResolver: CommandReceiptResolving {
    let inbox: CommandInbox
    let service: any VehicleServicing
    var pushGrace: TimeInterval = 10

    func receipt(
        for ticket: CommandTicket,
        vehicleId: String,
        timeout: TimeInterval
    ) async throws -> CommandReceipt {
        let grace = min(pushGrace, max(timeout * 0.5, 3))

        do {
            return try await inbox.wait(for: ticket.ticketId, timeout: grace)
        } catch {
            try Task.checkCancellation()
            await inbox.cancel(ticketId: ticket.ticketId)
            return try await service.awaitReceipt(
                for: ticket,
                vehicleId: vehicleId,
                timeout: max(timeout - grace, 10)
            )
        }
    }
}
