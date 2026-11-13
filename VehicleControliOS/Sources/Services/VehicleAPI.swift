import Foundation

/// 接口目录（Endpoint Catalog）。
///
/// ⚠️ 下面的 path 与字段名均为**占位结构**，用于固化调用约定。
/// 接入官方开放平台时，只需把这里的 path / action 改成文档给定值，
/// 业务层与 UI 层不需要任何改动。
enum VehicleAPI {
    struct VehicleListResponse: Decodable {
        let vehicles: [Vehicle]
    }

    // MARK: - 查询

    static func listVehicles() -> APIRequest<VehicleListResponse> {
        APIRequest(path: "/v1/vehicles", method: .get)
    }

    static func snapshot(vehicleId: String) -> APIRequest<VehicleSnapshot> {
        APIRequest(path: "/v1/vehicles/\(escape(vehicleId))/status", method: .get)
    }

    // MARK: - 控制

    /// 指令下发：不自动重试，由业务层携带同一个 Idempotency-Key 显式重试。
    static func sendCommand(
        vehicleId: String,
        body: Data,
        idempotencyKey: String
    ) -> APIRequest<CommandTicket> {
        APIRequest(
            path: "/v1/vehicles/\(escape(vehicleId))/commands",
            method: .post,
            headers: ["Idempotency-Key": idempotencyKey],
            body: body,
            timeout: 15,
            retryPolicy: .none
        )
    }

    static func commandReceipt(vehicleId: String, ticketId: String) -> APIRequest<CommandReceipt> {
        APIRequest(
            path: "/v1/vehicles/\(escape(vehicleId))/commands/\(escape(ticketId))",
            method: .get,
            timeout: 10
        )
    }

    // MARK: - 推送

    static func streamPath(vehicleId: String) -> String {
        "/v1/vehicles/\(escape(vehicleId))/stream"
    }

    /// 上报 APNs 设备令牌，由服务端在指令状态变更时推送回执。
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
