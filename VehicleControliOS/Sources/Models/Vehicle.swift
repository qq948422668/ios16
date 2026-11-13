import Foundation

struct Vehicle: Identifiable, Decodable, Sendable, Hashable {
    let id: String
    let vin: String
    let displayName: String
    let model: String
    let capabilities: Set<VehicleCapability>
}

/// 车辆能力声明。用 RawRepresentable 而非枚举：服务端新增能力值时
/// 不会导致整条响应解码失败，UI 只需 `contains(_:)` 判断可用性。
struct VehicleCapability: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let lock = VehicleCapability(rawValue: "lock")
    static let trunk = VehicleCapability(rawValue: "trunk")
    static let climate = VehicleCapability(rawValue: "climate")
    static let flash = VehicleCapability(rawValue: "flash")
    static let horn = VehicleCapability(rawValue: "horn")
    static let charging = VehicleCapability(rawValue: "charging")
}

extension VehicleCapability: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self).lowercased())
    }
}
