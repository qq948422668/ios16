import Foundation

/// 统一编解码策略：snake_case <-> camelCase，时间兼容 ISO8601（含毫秒）与
/// 秒/毫秒时间戳三种常见形态，避免服务端字段风格差异导致解码失败。
enum JSONCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let numeric = try? container.decode(Double.self) {
                let seconds = numeric > 1_000_000_000_000 ? numeric / 1000 : numeric
                return Date(timeIntervalSince1970: seconds)
            }
            let raw = try container.decode(String.self)
            let withFractional = JSONCoding.iso8601(fractional: true).date(from: raw)
            let withoutFractional = JSONCoding.iso8601(fractional: false).date(from: raw)
            if let date = withFractional ?? withoutFractional {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间字段：\(raw)"
            )
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    private static func iso8601(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
