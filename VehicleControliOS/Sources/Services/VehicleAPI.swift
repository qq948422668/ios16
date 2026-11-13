import Foundation

/// 官方车联网接口目录（依据接口文档 v3.6.8）。
///
/// 全部走新网关 `https://app-gw-global-master.leapmotor.com`，由 `APIClient`
/// 自动附加 HMAC-SHA256 签名头；`appRegion` 动态路由在文档中通常与 global-master 相同，
/// 如某车型下发不同大区，替换 `apiBaseURL` 即可。
enum VehicleAPI {
    struct VehicleListResponse: Decodable {
        let vehicles: [Vehicle]
    }

    // MARK: - 接口 7：用户绑定车辆列表

    static func listVehicles() -> APIRequest<VehicleListResponse> {
        APIRequest(
            path: "/app/app-global-service/v1/vehicle/list",
            method: .get,
            decoder: { data in
                let envelope = try JSONCoding.decode(OfficialVehicleListEnvelope.self, from: data)
                let vehicles = (envelope.data ?? []).compactMap(makeVehicle)
                return VehicleListResponse(vehicles: vehicles)
            }
        )
    }

    // MARK: - 接口 11：实时车况 signalMap

    static func snapshot(vehicleId: String) -> APIRequest<VehicleSnapshot> {
        APIRequest(
            path: "/app/app-signal-service/signal/info/query",
            method: .post,
            body: try? JSONCoding.encode(SignalQueryPayload(vin: vehicleId)),
            decoder: { data in
                let envelope = try JSONCoding.decode(SignalEnvelope.self, from: data)
                guard let signalMap = envelope.data?.signalMap else {
                    throw APIError.server(
                        status: 200,
                        code: envelope.code.map(String.init),
                        message: envelope.message ?? "signalMap 缺失"
                    )
                }
                return VehicleSnapshot(vehicleId: vehicleId, signalMap: signalMap)
            }
        )
    }

    // MARK: - 6.1 控车指令下发（form-urlencoded）

    static func sendControl(body: Data) -> APIRequest<CommandTicket> {
        APIRequest(
            path: "/app/app-control-service/v3/api/appremotectl",
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
            body: body,
            timeout: 15,
            retryPolicy: .none,
            decoder: { data in
                let envelope = try JSONCoding.decode(ControlSendEnvelope.self, from: data)
                guard (envelope.result ?? -1) == 0,
                      let msgID = envelope.data?.text, !msgID.isEmpty else {
                    throw APIError.commandFailed(
                        envelope.message ?? "云端未受理该指令（result != 0）"
                    )
                }
                return CommandTicket(ticketId: msgID, status: .dispatched, requestedAt: Date())
            }
        )
    }

    // MARK: - 6.2 指令结果轮询

    static func controlQuery(msgID: String) -> APIRequest<CommandReceipt> {
        APIRequest(
            path: "/app/app-control-service/v3/api/appremotectl/query",
            query: ["msgID": msgID],
            timeout: 10,
            decoder: { data in
                let envelope = try JSONCoding.decode(ControlQueryEnvelope.self, from: data)
                if let result = envelope.result, result != 0 {
                    return CommandReceipt(
                        ticketId: msgID,
                        status: .failed,
                        failureReason: envelope.message ?? "业务码 \(result)",
                        completedAt: nil
                    )
                }
                // 车端执行中返回 data=0，成功后返回 data=1。
                let succeeded = envelope.data?.text == "1"
                return CommandReceipt(
                    ticketId: msgID,
                    status: succeeded ? .succeeded : .running,
                    failureReason: nil,
                    completedAt: succeeded ? Date() : nil
                )
            }
        )
    }

    // MARK: - 推送与长连接（Mock 契约，官方 WebSocket 未公开）

    static func streamPath(vehicleId: String) -> String {
        "/v1/vehicles/\(escape(vehicleId))/stream"
    }

    static func registerPushToken(deviceToken: String, bundleId: String?) -> APIRequest<EmptyResponse> {
        let payload = PushSubscriptionPayload(
            deviceToken: deviceToken,
            platform: "ios",
            bundleId: bundleId
        )
        return APIRequest(
            path: "/v1/push/subscriptions",
            method: .post,
            body: try? JSONCoding.encode(payload),
            retryPolicy: .standard,
            decoder: { _ in EmptyResponse() }
        )
    }

    // MARK: - 内部模型与映射

    private static func makeVehicle(_ item: OfficialVehicle) -> Vehicle? {
        guard let vin = item.vin, !vin.isEmpty else { return nil }

        var capabilities: Set<VehicleCapability> = []
        let config = item.funcConfig ?? [:]
        if config.keys.contains("HVAC") { capabilities.insert(.climate) }
        if config.keys.contains("FRIDGE") { capabilities.insert(.fridge) }
        if config.keys.contains("WINDOW") { capabilities.insert(.window) }
        if config.keys.contains("LOCK") || config.keys.contains("DOOR") { capabilities.insert(.lock) }
        if config.keys.contains("TRUNK") { capabilities.insert(.trunk) }
        if config.keys.contains("CHARGE") { capabilities.insert(.charging) }
        // 官方 App 对所有绑定车辆默认开放锁车/寻车/后备箱/充电入口。
        capabilities.formUnion([.lock, .trunk, .horn, .flash, .charging])

        let name = item.vehicleName ?? item.nickName ?? item.carType ?? "我的车辆"
        let model = [item.carType, item.licensePlate]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return Vehicle(
            id: vin,
            vin: vin,
            displayName: name,
            model: model.isEmpty ? "零跑汽车" : model,
            capabilities: capabilities
        )
    }

    private static func escape(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct PushSubscriptionPayload: Encodable {
    let deviceToken: String
    let platform: String
    let bundleId: String?
}

private struct SignalQueryPayload: Encodable {
    let vin: String
}

/// 接口 7 响应：`{ code, data: [ {vin, carType, licensePlate, ...} ] }`。
struct OfficialVehicleListEnvelope: Decodable {
    let code: Int?
    let message: String?
    let data: [OfficialVehicle]?
}

struct OfficialVehicle: Decodable {
    let vin: String?
    let carType: String?
    let licensePlate: String?
    let vehicleName: String?
    let nickName: String?
    let isOwner: Bool?
    let funcConfig: [String: LooseValue]?
}

/// 6.1 响应：`{"result": 0, "data": "<msgID>"}`。
struct ControlSendEnvelope: Decodable {
    let result: Int?
    let message: String?
    let data: LooseValue?
}

/// 6.2 响应：`{"result": 0, "data": "0|1"}`。
struct ControlQueryEnvelope: Decodable {
    let result: Int?
    let message: String?
    let data: LooseValue?
}
