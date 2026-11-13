import Foundation

/// 车辆实时状态快照。轮询与长连接推送共用同一结构。
struct VehicleSnapshot: Codable, Sendable, Equatable {
    let vehicleId: String
    let capturedAt: Date
    let battery: BatteryState
    let climate: ClimateState
    let security: SecurityState
    let location: GeoPoint?
}

struct BatteryState: Codable, Sendable, Equatable {
    let percent: Double
    let rangeKm: Double
    let charging: ChargingStatus
    let chargeLimitPercent: Double?
}

struct ClimateState: Codable, Sendable, Equatable {
    let isOn: Bool
    let targetCelsius: Double?
    let insideCelsius: Double?
}

struct SecurityState: Codable, Sendable, Equatable {
    let isLocked: Bool
    let trunkOpen: Bool?
    let windowsClosed: Bool?
}

struct GeoPoint: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

/// 未知枚举值统一落到 .unknown，避免服务端新增状态导致解码整体失败。
enum ChargingStatus: String, Codable, Sendable {
    case idle
    case charging
    case complete
    case fault
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        self = ChargingStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .idle: return "未充电"
        case .charging: return "充电中"
        case .complete: return "已充满"
        case .fault: return "充电故障"
        case .unknown: return "未知"
        }
    }
}
