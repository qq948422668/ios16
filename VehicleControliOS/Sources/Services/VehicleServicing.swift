import Foundation

protocol VehicleServicing: Sendable {
    func fetchVehicles() async throws -> [Vehicle]
    func fetchSnapshot(vehicleId: String) async throws -> VehicleSnapshot
    func send(_ command: VehicleCommand, to vehicleId: String) async throws -> CommandTicket
    func commandReceipt(vehicleId: String, ticketId: String) async throws -> CommandReceipt
}

extension VehicleServicing {
    /// 指令回执轮询：官方策略为首次 1 秒、随后 500ms、最长 24 秒。
    /// 车控结果只能以此为准，HTTP 2xx 仅表示“已受理”。
    func awaitReceipt(
        for ticket: CommandTicket,
        vehicleId: String,
        timeout: TimeInterval = 24,
        initialInterval: TimeInterval = 1.0
    ) async throws -> CommandReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        var interval = initialInterval
        var attempt = 0

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            attempt += 1

            let receipt = try await commandReceipt(vehicleId: vehicleId, ticketId: ticket.ticketId)
            if receipt.status.isTerminal {
                return receipt
            }
            // 首次 1 秒等待后固定 500ms 轮询，避免高频打爆车控服务。
            interval = attempt == 1 ? initialInterval : 0.5
        }

        throw APIError.commandFailed("回执超时（\(Int(timeout)) 秒内未确认）")
    }
}

final class RemoteVehicleService: VehicleServicing, @unchecked Sendable {
    private let client: APIClient
    private let operatePin: @Sendable () async -> String?

    init(client: APIClient, operatePin: @escaping @Sendable () async -> String? = { nil }) {
        self.client = client
        self.operatePin = operatePin
    }

    func fetchVehicles() async throws -> [Vehicle] {
        try await client.send(VehicleAPI.listVehicles()).vehicles
    }

    func fetchSnapshot(vehicleId: String) async throws -> VehicleSnapshot {
        try await client.send(VehicleAPI.snapshot(vehicleId: vehicleId))
    }

    /// 官方 6.1：表单提交 `cmdid/carvin/state/oppwd/timespan/nonce/deviceID/signStr`。
    func send(_ command: VehicleCommand, to vehicleId: String) async throws -> CommandTicket {
        let spec = command.officialSpec
        var form: [String: String] = [
            "cmdid": spec.cmdid,
            "carvin": vehicleId,
            "state": spec.state,
            "timespan": String(Int64(Date().timeIntervalSince1970 * 1000)),
            "nonce": String(Int.random(in: 10_000..<10_000_000)),
            "deviceID": DeviceIdentity.current()
        ]

        if let pin = await operatePin(),
           OperatePasswordStore.isValid(pin),
           let token = await client.currentAccessToken() {
            form["oppwd"] = try LeapCrypto.encryptOperationPassword(pin, token: token)
        }

        // 旧链路签名：MD5 截断，参与字段与表单一致。
        form["signStr"] = LeapCrypto.md5Short(LeapCrypto.signBase(form))

        let body = form
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")

        return try await client.send(VehicleAPI.sendControl(body: Data(body.utf8)))
    }

    func commandReceipt(vehicleId: String, ticketId: String) async throws -> CommandReceipt {
        try await client.send(VehicleAPI.controlQuery(msgID: ticketId))
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
