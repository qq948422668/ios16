import Foundation

/// 车控指令集合，取值与官方 35+ 指令矩阵（文档 §6.3）一一对应。
enum VehicleCommand: String, CaseIterable, Identifiable, Sendable {
    case lock
    case unlock
    case trunkOpen
    case trunkClose
    case climateOn
    case climateOff
    case quickCool
    case quickHeat
    case defrost
    case flash
    case horn
    case windowClose
    case chargeStart
    case chargeStop

    /// 默认空调目标温度，可改为从用户偏好读取。
    static let defaultClimateCelsius: Double = 22

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lock: return "锁车"
        case .unlock: return "解锁"
        case .trunkOpen: return "开后备箱"
        case .trunkClose: return "关后备箱"
        case .climateOn: return "开空调"
        case .climateOff: return "关空调"
        case .quickCool: return "极速降温"
        case .quickHeat: return "极速升温"
        case .defrost: return "前挡除霜"
        case .flash: return "闪灯"
        case .horn: return "鸣笛"
        case .windowClose: return "关车窗"
        case .chargeStart: return "开始充电"
        case .chargeStop: return "停止充电"
        }
    }

    var systemImage: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .trunkOpen: return "shippingbox.fill"
        case .trunkClose: return "shippingbox"
        case .climateOn: return "fanblades.fill"
        case .climateOff: return "fanblades"
        case .quickCool: return "snowflake"
        case .quickHeat: return "flame.fill"
        case .defrost: return "wind"
        case .flash: return "headlight.high.beam.fill"
        case .horn: return "speaker.wave.3.fill"
        case .windowClose: return "rectangle.bottomthird.inset.filled"
        case .chargeStart: return "bolt.fill"
        case .chargeStop: return "bolt.slash.fill"
        }
    }

    /// 内部动作名（本地语义，网关负责映射到官方 cmdid）。
    var action: String {
        switch self {
        case .lock: return "lock"
        case .unlock: return "unlock"
        case .trunkOpen: return "trunk_open"
        case .trunkClose: return "trunk_close"
        case .climateOn: return "climate_on"
        case .climateOff: return "climate_off"
        case .quickCool: return "quick_cool"
        case .quickHeat: return "quick_heat"
        case .defrost: return "defrost"
        case .flash: return "flash_lights"
        case .horn: return "horn"
        case .windowClose: return "window_close"
        case .chargeStart: return "charge_start"
        case .chargeStop: return "charge_stop"
        }
    }

    var parameters: [String: String] {
        switch self {
        case .climateOn:
            return ["target_celsius": String(Self.defaultClimateCelsius)]
        case .quickCool:
            return ["target_celsius": "18", "wind_level": "7"]
        case .quickHeat:
            return ["target_celsius": "32", "wind_level": "7"]
        default:
            return [:]
        }
    }

    /// 有安全风险或不可逆的动作需要二次确认。
    var requiresConfirmation: Bool {
        switch self {
        case .unlock, .trunkOpen, .trunkClose:
            return true
        default:
            return false
        }
    }

    var requiredCapability: VehicleCapability? {
        switch self {
        case .lock, .unlock: return .lock
        case .trunkOpen, .trunkClose: return .trunk
        case .climateOn, .climateOff, .quickCool, .quickHeat, .defrost: return .climate
        case .flash: return .flash
        case .horn: return .horn
        case .windowClose: return .window
        case .chargeStart, .chargeStop: return .charging
        }
    }

    // MARK: - 官方协议映射（文档 §6.3）

    /// 官方 `cmdid` + `state` JSON 参数体。
    var officialSpec: OfficialCommandSpec {
        switch self {
        case .lock:
            return OfficialCommandSpec(cmdid: "110", state: #"{"value":"lock"}"#)
        case .unlock:
            return OfficialCommandSpec(cmdid: "110", state: #"{"value":"unlock"}"#)
        case .trunkOpen:
            return OfficialCommandSpec(cmdid: "130", state: #"{"value":"true"}"#)
        case .trunkClose:
            return OfficialCommandSpec(cmdid: "130", state: #"{"value":"false"}"#)
        case .climateOn:
            return OfficialCommandSpec(
                cmdid: "170",
                state: #"{"operate":"auto","temperature":"24","windlevel":"3","mode":"cold","circle":"in","wshld":"1","position":"all"}"#
            )
        case .climateOff:
            return OfficialCommandSpec(
                cmdid: "170",
                state: #"{"operate":"off","temperature":"24","windlevel":"3","mode":"nohotcold","circle":"in","wshld":"1","position":"all"}"#
            )
        case .quickCool:
            return OfficialCommandSpec(
                cmdid: "170",
                state: #"{"operate":"manual","temperature":"18","windlevel":"7","mode":"cold","circle":"in","wshld":"0","position":"all"}"#
            )
        case .quickHeat:
            return OfficialCommandSpec(
                cmdid: "170",
                state: #"{"operate":"manual","temperature":"32","windlevel":"7","mode":"hot","circle":"in","wshld":"0","position":"all"}"#
            )
        case .defrost:
            return OfficialCommandSpec(
                cmdid: "170",
                state: #"{"operate":"manual","temperature":"24","windlevel":"5","mode":"cold","circle":"out","wshld":"1","position":"wshld"}"#
            )
        case .flash, .horn:
            return OfficialCommandSpec(cmdid: "120", state: #"{"value":"true"}"#)
        case .windowClose:
            return OfficialCommandSpec(cmdid: "230", state: #"{"value":"0"}"#)
        case .chargeStart:
            return OfficialCommandSpec(cmdid: "193", state: #"{"value":"start"}"#)
        case .chargeStop:
            // 官方抓包确认停止充电只认 finish，stop 车端不响应。
            return OfficialCommandSpec(cmdid: "193", state: #"{"value":"finish"}"#)
        }
    }
}

/// 官方指令规格：`cmdid` 决定动作域，`state` 为 JSON 参数体原样字符串。
struct OfficialCommandSpec: Sendable, Equatable {
    let cmdid: String
    let state: String
}

/// 指令下发请求体（旧链路 JSON 结构，保留用于兼容与测试）。
struct CommandPayload: Encodable {
    let action: String
    let parameters: [String: String]
}
