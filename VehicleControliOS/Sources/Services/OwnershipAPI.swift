import Foundation

/// 车主服务（carownerservice）与 IOV 域接口目录（文档 §7/§8，v3.6.8）。
/// 全部走新网关 HMAC 签名头；环视照片在 iov-api 独立域，用 baseOverride。
enum OwnershipAPI {
    /// 环视照片域（接口 12）。
    private static let iovBase = "https://iov-api.leapmotor.com"

    // MARK: - 通用信封

    struct ResultEnvelope: Decodable {
        let code: Int?
        let result: Int?
        let message: String?

        var isSuccess: Bool {
            let codes = [code, result].compactMap { $0 }
            return codes.allSatisfy { $0 == 0 || $0 == 200 }
        }
    }

    // MARK: - 接口 6：操作密码前置校验

    static func verifyOperatePassword(vin: String, encryptedPin: String) -> APIRequest<Bool> {
        APIRequest(
            path: "/carownerservice/v3/api/appoperate/verifyoperatepwdnew",
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
            body: Self.form(["vin": vin, "oprpwd": encryptedPin]),
            timeout: 15,
            retryPolicy: .none,
            decoder: { data in
                let envelope = try JSONCoding.decode(ResultEnvelope.self, from: data)
                guard envelope.isSuccess else {
                    throw APIError.commandFailed(
                        envelope.message ?? "操作密码校验未通过（code \(envelope.code ?? -1)）"
                    )
                }
                return true
            }
        )
    }

    // MARK: - 接口 14：健康充电上限

    static func setChargeLimit(vin: String, targetSoc: Int) -> APIRequest<Bool> {
        APIRequest(
            path: "/carownerservice/v3/api/healthyCharging/control",
            method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
            body: Self.form([
                "vin": vin,
                "carvin": vin,
                "state": "1",
                "targetSoc": String(targetSoc),
            ]),
            timeout: 15,
            retryPolicy: .none,
            decoder: Self.successDecoder
        )
    }

    static func chargePushState(vin: String) -> APIRequest<Bool> {
        APIRequest(
            path: "/carownerservice/v3/api/healthyCharging/queryPushState",
            query: ["vin": vin, "carvin": vin],
            decoder: { data in
                let envelope = try JSONCoding.decode(LooseDataEnvelope.self, from: data)
                guard envelope.isSuccess else { return false }
                return envelope.data?.text == "1"
            }
        )
    }

    // MARK: - 接口 17/18：行驶里程与能耗明细

    static func drivingDetail(vin: String, beginMs: Int64, endMs: Int64) -> APIRequest<DrivingDetail> {
        APIRequest(
            path: "/carownerservice/v3/api/drivingrecord/mileage/energy/detail",
            query: [
                "begintime": String(beginMs),
                "endtime": String(endMs),
                "vin": vin,
            ],
            decoder: { data in
                let envelope = try JSONCoding.decode(DrivingDetailEnvelope.self, from: data)
                guard let detail = envelope.data else {
                    throw APIError.server(
                        status: 200,
                        code: envelope.code.map(String.init),
                        message: envelope.message ?? "行驶数据缺失"
                    )
                }
                return detail
            }
        )
    }

    // MARK: - 接口 19：近 6 周百公里能耗与排行（注意参数名是 carvin）

    static func weeklyEnergy(carvin: String) -> APIRequest<WeeklyEnergy> {
        APIRequest(
            path: "/carownerservice/v3/api/drivingrecord/getLastNweeks100kmECAndRank",
            query: ["carvin": carvin],
            decoder: { data in
                let envelope = try JSONCoding.decode(WeeklyEnergyEnvelope.self, from: data)
                guard let weekly = envelope.data else {
                    throw APIError.server(
                        status: 200,
                        code: envelope.code.map(String.init),
                        message: envelope.message ?? "周能耗数据缺失"
                    )
                }
                return weekly
            }
        )
    }

    // MARK: - 接口 12：驻车环视照片（iov 域）

    static func parkingPhoto(vin: String) -> APIRequest<ParkingPhotoInfo> {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var query: [String: String] = [
            "vin": vin,
            "timespan": String(now),
            "nonce": String(Int.random(in: 10_000..<10_000_000)),
            "deviceID": DeviceIdentity.current(),
        ]
        query["signStr"] = LeapCrypto.md5Short(LeapCrypto.signBase(query))
        return APIRequest(
            path: "/carownerservice/v3/api/chassis/query",
            query: query,
            timeout: 15,
            baseOverride: iovBase,
            decoder: { data in
                let envelope = try JSONCoding.decode(ParkingPhotoEnvelope.self, from: data)
                guard envelope.isSuccess, let info = envelope.data,
                      let fileUrl = info.fileUrl, !fileUrl.isEmpty else {
                    throw APIError.commandFailed(envelope.message ?? "暂无驻车环视照片")
                }
                return ParkingPhotoInfo(
                    fileUrl: fileUrl,
                    uploadedAt: info.uploadTime.map {
                        Date(timeIntervalSince1970: $0 / 1000)
                    }
                )
            }
        )
    }

    // MARK: - Helpers

    private static let successDecoder: @Sendable (Data) throws -> Bool = { data in
        let envelope = try JSONCoding.decode(ResultEnvelope.self, from: data)
        guard envelope.isSuccess else {
            throw APIError.commandFailed(
                envelope.message ?? "操作未受理（code \(envelope.code ?? -1)）"
            )
        }
        return true
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .sorted { $0.key < $1.key }
            .map { (key, value) -> String in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - 数据模型

/// `{ code, result, message, data: "..."|{...} }` 宽松信封。
struct LooseDataEnvelope: Decodable {
    let code: Int?
    let result: Int?
    let message: String?
    let data: LooseValue?

    var isSuccess: Bool {
        let codes = [code, result].compactMap { $0 }
        return codes.allSatisfy { $0 == 0 || $0 == 200 }
    }
}

/// 接口 17/18 响应：总量 + 逐日明细。
struct DrivingDetail: Decodable, Sendable {
    let totalMileage: Double?
    let totalEnergy: Double?
    let totalFuel: Double?
    let averageEnergy: Double?
    let detail: [DailyMileage]?
}

struct DailyMileage: Decodable, Sendable {
    let day: String
    let accumulatedMileage: Double?
}

private struct DrivingDetailEnvelope: Decodable {
    let code: Int?
    let message: String?
    let data: DrivingDetail?
}

/// 接口 19 响应：周能耗序列 + 同车型排行百分比。
struct WeeklyEnergy: Decodable, Sendable {
    struct WeekPoint: Decodable, Sendable {
        let week: String?
        let ec: Double?
    }

    /// 官方字段在不同版本为 weekEc / weeks / data 序列，宽松兼容。
    let points: [WeekPoint]
    let rankPercent: Double?

    init(points: [WeekPoint], rankPercent: Double?) {
        self.points = points
        self.rankPercent = rankPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([WeekPoint].self, forKey: .weekEc) {
            points = list
        } else if let list = try? container.decode([WeekPoint].self, forKey: .weeks) {
            points = list
        } else {
            points = []
        }
        rankPercent = try container.decodeIfPresent(Double.self, forKey: .rankPercent)
            ?? container.decodeIfPresent(Double.self, forKey: .percent)
    }

    enum CodingKeys: String, CodingKey {
        case weekEc, weeks, rankPercent, percent
    }
}

private struct WeeklyEnergyEnvelope: Decodable {
    let code: Int?
    let message: String?
    let data: WeeklyEnergy?
}

/// 接口 12 响应。
struct ParkingPhotoInfo: Decodable, Sendable, Equatable {
    let fileUrl: String
    let uploadedAt: Date?
}

private struct ParkingPhotoEnvelope: Decodable {
    let code: Int?
    let result: Int?
    let message: String?
    let data: Payload?

    var isSuccess: Bool {
        let codes = [code, result].compactMap { $0 }
        return codes.allSatisfy { $0 == 0 || $0 == 200 }
    }

    struct Payload: Decodable {
        let fileUrl: String?
        let uploadTime: Double?
    }
}
