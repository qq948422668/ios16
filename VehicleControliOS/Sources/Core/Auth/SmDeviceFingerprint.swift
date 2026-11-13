import CryptoKit
import Foundation
import UIKit

// MARK: - 数美设备风控指纹（smDeviceId）

/// `smDeviceId` 采集抽象。
///
/// 背景与定位：
/// - 官方 Android 端该字段由数美 `SmAntiFraud` SDK（`libsmsdk.so`）综合设备
///   传感器数据、系统构建信息与运行环境实时采样生成，用于服务端设备风控识别
///   （登录接口 2 必传，缺失或非法会被 100132 拒绝）；
/// - iOS 端无该 SDK，本类型用等效信号自采样生成同形指纹；协议保持可替换，
///   将来接入真实数美 iOS SDK 时只需提供新的 `SmDeviceIdProviding` 实现，
///   登录链路无需改动。
protocol SmDeviceIdProviding: Sendable {
    /// 在登录请求组装前调用。内部已含超时与降级，永不抛错、永不阻塞主链路。
    func collect() async -> SmDeviceId
}

/// 指纹值与来源。`source` 供诊断日志使用：
/// - `sampled`：本轮实时采样生成（首次，随后写入缓存）；
/// - `cached`：命中本安装周期内的稳定缓存（绝大多数调用走这里）；
/// - `degraded`：采样失败/为空/超时，降级为稳定设备标识（与 `deviceID` 同源）。
struct SmDeviceId: Sendable, Equatable {
    enum Source: String, Sendable {
        case sampled, cached, degraded
    }

    let value: String
    let source: Source
}

/// 默认采集器：系统构建信息 + 运行环境 + 硬件特征 + 厂商标识 + 安装盐值，
/// 经 SHA-256 输出 **64 位十六进制**指纹（数美指纹同为定长 hex 串形态）。
///
/// 稳定性约定：风控要求同一设备指纹稳定，故首次采样成功后缓存复用；
/// `identifierForVendor` 变化（卸载重装/系统重置）时自动重新采样。
struct DeviceFingerprintSampler: SmDeviceIdProviding {
    /// 采样超时。数美官方 SDK 采样同样要求不阻塞登录（失败即降级）。
    static let collectionTimeoutNanos: UInt64 = 2_000_000_000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static let cacheKey = "com.vehiclecontrol.app.smDeviceId"
    private static let vendorKey = "com.vehiclecontrol.app.smDeviceId.vendor"

    func collect() async -> SmDeviceId {
        // 1) 缓存命中且厂商标识未变 → 直接复用（风控指纹稳定性要求）。
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? ""
        if let cached = defaults.string(forKey: Self.cacheKey),
           cached.count == 64,
           defaults.string(forKey: Self.vendorKey) == vendor {
            return SmDeviceId(value: cached, source: .cached)
        }

        // 2) 带超时实时采样；超时同样走降级。
        let sampled = await withTaskGroup(of: String?.self) { group in
            group.addTask { await Self.sampleSignals(vendor: vendor) }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.collectionTimeoutNanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let value = sampled, value.count == 64 {
            defaults.set(value, forKey: Self.cacheKey)
            defaults.set(vendor, forKey: Self.vendorKey)
            return SmDeviceId(value: value, source: .sampled)
        }

        // 3) 降级：采样失败/为空/超时 → 与 deviceID 同源的稳定标识。
        //    服务端若拒绝降级指纹，会返回 100132，由业务码映射给出准确反馈。
        return SmDeviceId(value: DeviceIdentity.current(), source: .degraded)
    }

    /// 信号采集：等价于数美 SDK 的三类输入——
    /// 系统构建信息（os/version/model）、运行环境（locale/时区/日历/热状态）、
    /// 硬件特征（内存/核数）与厂商标识、安装盐值。
    private static func sampleSignals(vendor: String) async -> String? {
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let signals: [String: String] = [
            "vendor": vendor,
            "installSalt": installSalt(),
            "os": device.systemName,
            "osVersion": device.systemVersion,
            "model": device.model,
            "idiom": String(device.userInterfaceIdiom.rawValue),
            "osMajor": String(process.operatingSystemMajorVersion),
            "osMinor": String(process.operatingSystemMinorVersion),
            "osPatch": String(process.operatingSystemPatchVersion),
            "mem": String(process.physicalMemory),
            "cores": String(process.activeProcessorCount),
            "thermal": String(process.thermalState.rawValue),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "calendar": String(Calendar.current.identifier.rawValue),
        ]

        let base = signals
            .sorted { $0.key < $1.key }
            .reduce(into: "") { result, pair in
                result += "\(pair.key)=\(pair.value);"
            }
        guard !base.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 安装盐值：首次运行生成并持久化，保证同安装内指纹确定、跨安装不可复现。
    private static func installSalt() -> String {
        let key = "com.vehiclecontrol.app.fingerprint.salt"
        if let stored = UserDefaults.standard.string(forKey: key), stored.count == 32 {
            return stored
        }
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }
}
