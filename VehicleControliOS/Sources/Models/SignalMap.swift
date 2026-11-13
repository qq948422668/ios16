import Foundation

/// 官方接口 11 的响应信封：`{ code, data: { signalMap } }`。
struct SignalEnvelope: Decodable {
    let code: Int?
    let message: String?
    let data: SignalData?

    struct SignalData: Decodable {
        let signalMap: [String: String]?
    }
}

/// 宽松值：官方接口部分字段在数字/字符串/布尔之间漂移，
/// 统一收敛成字符串，避免新增车型信号类型变化导致解码失败。
struct LooseValue: Decodable, Sendable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            text = nil
            return
        }
        if let bool = try? container.decode(Bool.self) {
            text = bool ? "1" : "0"
            return
        }
        if let number = try? container.decode(Double.self) {
            text = number == number.rounded() ? String(Int(number)) : String(number)
            return
        }
        if let string = try? container.decode(String.self) {
            text = string
            return
        }
        // 对象/数组只做吞掉处理，不递归展开。
        text = nil
    }
}

/// 从 signalMap 解码出的扩展车况（仪表盘展示用）。
struct SignalDetails: Codable, Sendable, Equatable {
    var totalMileageKm: Double?
    var speedKmh: Double?
    var gear: String?
    var isReady: Bool?
    var parkingBrakeOn: Bool?
    var chargeRemainMinutes: Int?
    var interiorTempC: Double?
    var acTargetC: Double?
    var acFanLevel: Int?
    var driverSeatHeatLevel: Int?
    var driverSeatVentLevel: Int?
    var steeringWheelHeatLevel: Int?
    var fridgeOn: Bool?
    var fridgeTargetC: Int?
    var fridgeCoolingMode: Bool?
    var tirePressure: TirePressures?

    struct TirePressures: Codable, Sendable, Equatable {
        var leftFront: Double?
        var rightFront: Double?
        var leftRear: Double?
        var rightRear: Double?
    }
}

extension VehicleSnapshot {
    /// 依据官方 signalMap 权威字典（文档 §5.1）构建快照。
    init(vehicleId: String, signalMap: [String: String]) {
        func value(_ id: String) -> Double? {
            signalMap[id].flatMap(Double.init)
        }
        func int(_ id: String) -> Int? {
            value(id).map { Int($0.rounded()) }
        }
        func bool(_ id: String) -> Bool? {
            int(id).map { $0 != 0 }
        }

        let preciseSoc = value("100003")
        let soc = value("1204")
        let percent = preciseSoc ?? soc ?? 0

        let charging: ChargingStatus
        switch int("1149") ?? 0 {
        case 1: charging = .charging
        case 2: charging = .complete
        case 3: charging = .fault
        case 0: charging = .idle
        default: charging = .unknown
        }

        let climateOn = bool("1938") ?? false
        let windowsOpen = [value("1693"), value("1694"), value("1695"), value("1696")]
            .contains { ($0 ?? 0) != 0 }

        self.init(
            vehicleId: vehicleId,
            capturedAt: Date(),
            battery: BatteryState(
                percent: percent,
                rangeKm: value("3260") ?? value("3257") ?? 0,
                charging: charging,
                chargeLimitPercent: bool("48").map { $0 ? 80 : 100 }
            ),
            climate: ClimateState(
                isOn: climateOn,
                targetCelsius: value("2183"),
                insideCelsius: value("1349")
            ),
            security: SecurityState(
                isLocked: (int("1298") ?? 0) != 0,
                trunkOpen: bool("1281"),
                windowsClosed: windowsOpen ? false : true
            ),
            location: value("3724").flatMap { lon in
                value("3725").map { GeoPoint(latitude: $0, longitude: lon) }
            },
            details: SignalDetails(
                totalMileageKm: value("1318"),
                speedKmh: value("1319"),
                gear: signalMap["1010"],
                isReady: bool("1944"),
                parkingBrakeOn: bool("1480"),
                chargeRemainMinutes: int("1200"),
                interiorTempC: value("1349"),
                acTargetC: value("2183"),
                acFanLevel: int("1941"),
                driverSeatHeatLevel: int("2100"),
                driverSeatVentLevel: int("2101"),
                steeringWheelHeatLevel: int("1816"),
                fridgeOn: bool("10709"),
                fridgeTargetC: int("10707"),
                fridgeCoolingMode: int("10708").map { $0 == 0 },
                tirePressure: SignalDetails.TirePressures(
                    leftFront: value("2646"),
                    rightFront: value("2653"),
                    leftRear: value("2660"),
                    rightRear: value("2667")
                )
            )
        )
    }
}
