import Foundation

protocol VehicleServicing: Sendable {
    func fetchVehicles() async throws -> [Vehicle]
    func fetchSnapshot(vehicleId: String) async throws -> VehicleSnapshot
    func send(_ command: VehicleCommand, to vehicleId: String) async throws -> CommandTicket
    func commandReceipt(vehicleId: String, ticketId: String) async throws -> CommandReceipt
}

extension VehicleServicing {
    /// 指令回执轮询：1.2s 起步、1.5 倍退避、上限 5s，总超时默认 45s。
    /// 车控结果只能以此为准，HTTP 2xx 仅表示“已受理”。
    func awaitReceipt(
        for ticket: CommandTicket,
        vehicleId: String,
        timeout: TimeInterval = 45,
        initialInterval: TimeInterval = 1.2
    ) async throws -> CommandReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        var interval = initialInterval

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let receipt = try await commandReceipt(vehicleId: vehicleId, ticketId: ticket.ticketId)
            if receipt.status.isTerminal {
                return receipt
            }
            interval = min(interval * 1.5, 5)
        }

        throw APIError.commandFailed("回执超时（\(Int(timeout)) 秒内未确认）")
    }
}

final class RemoteVehicleService: VehicleServicing, @unchecked Sendable {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func fetchVehicles() async throws -> [Vehicle] {
        try await client.send(VehicleAPI.listVehicles()).vehicles
    }

    func fetchSnapshot(vehicleId: String) async throws -> VehicleSnapshot {
        try await client.send(VehicleAPI.snapshot(vehicleId: vehicleId))
    }

    func send(_ command: VehicleCommand, to vehicleId: String) async throws -> CommandTicket {
        let payload = CommandPayload(action: command.action, parameters: command.parameters)
        let body = try JSONCoding.encode(payload)
        let request = VehicleAPI.sendCommand(
            vehicleId: vehicleId,
            body: body,
            idempotencyKey: UUID().uuidString
        )
        return try await client.send(request)
    }

    func commandReceipt(vehicleId: String, ticketId: String) async throws -> CommandReceipt {
        try await client.send(VehicleAPI.commandReceipt(vehicleId: vehicleId, ticketId: ticketId))
    }
}
