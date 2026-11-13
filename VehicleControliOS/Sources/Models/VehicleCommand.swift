import Foundation

/// 车控指令集合。`action` / `parameters` 是协议上的落点，
/// 接入时按你方文档调整取值即可，UI 层无需改动。
enum VehicleCommand: String, CaseIterable, Identifiable, Sendable {
    case lock
    case unlock
    case trunk
    case climateOn
    case climateOff
    case flash
    case horn
    case chargeStart
    case chargeStop

    /// 默认空调目标温度，可改为从用户偏好读取。
    static let defaultClimateCelsius: Double = 22

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lock: return "锁车"
        case .unlock: return "解锁"
        case .trunk: return "后备箱"
        case .climateOn: return "开空调"
        case .climateOff: return "关空调"
        case .flash: return "闪灯"
        case .horn: return "鸣笛"
        case .chargeStart: return "开始充电"
        case .chargeStop: return "停止充电"
        }
    }

    var systemImage: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .trunk: return "shippingbox.fill"
        case .climateOn: return "fanblades.fill"
        case .climateOff: return "fanblades"
        case .flash: return "headlight.high.beam.fill"
        case .horn: return "speaker.wave.3.fill"
        case .chargeStart: return "bolt.fill"
        case .chargeStop: return "bolt.slash.fill"
        }
    }

    var action: String {
        switch self {
        case .lock: return "lock"
        case .unlock: return "unlock"
        case .trunk: return "trunk_toggle"
        case .climateOn: return "climate_on"
        case .climateOff: return "climate_off"
        case .flash: return "flash_lights"
        case .horn: return "horn"
        case .chargeStart: return "charge_start"
        case .chargeStop: return "charge_stop"
        }
    }

    var parameters: [String: String] {
        switch self {
        case .climateOn:
            return ["target_celsius": String(Self.defaultClimateCelsius)]
        default:
            return [:]
        }
    }

    /// 有安全风险或不可逆的动作需要二次确认。
    var requiresConfirmation: Bool {
        switch self {
        case .unlock, .trunk:
            return true
        default:
            return false
        }
    }

    var requiredCapability: VehicleCapability? {
        switch self {
        case .lock, .unlock: return .lock
        case .trunk: return .trunk
        case .climateOn, .climateOff: return .climate
        case .flash: return .flash
        case .horn: return .horn
        case .chargeStart, .chargeStop: return .charging
        }
    }
}

/// 指令下发请求体。
struct CommandPayload: Encodable {
    let action: String
    let parameters: [String: String]
}
