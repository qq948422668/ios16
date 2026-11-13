import Foundation

/// OTA 更新清单（服务端发布，CI 在每次成功构建后写入 `.github/ota/manifest.json`）。
///
/// ```json
/// {
///   "latest_version": "1.0.1",
///   "min_version": "1.0.0",
///   "build": 6,
///   "updated_at": "2026-11-13T06:40:00Z",
///   "notes": "修复启动闪退",
///   "ipa_url": "https://github.com/owner/repo/actions/runs/123",
///   "manifest_plist_url": null
/// }
/// ```
/// `manifest_plist_url` 非空时表示该包已签名并挂了 itms-services
/// 无线安装清单，可直接 OTA 安装；为空时只能引导用户去 `ipa_url` 下载后重签。
struct OTAInfo: Codable, Equatable, Sendable {
    let latestVersion: String
    let minVersion: String
    let build: Int?
    let updatedAt: String?
    let notes: String?
    let ipaURL: String?
    let manifestPlistURL: String?

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
        case minVersion = "min_version"
        case build
        case updatedAt = "updated_at"
        case notes
        case ipaURL = "ipa_url"
        case manifestPlistURL = "manifest_plist_url"
    }
}

/// 更新检查结论。
struct UpdateAnnouncement: Equatable, Sendable, Identifiable {
    var id: String { info.latestVersion }

    enum Kind: Equatable, Sendable {
        /// 建议更新（弹一次，可忽略）。
        case available
        /// 强制更新（当前版本低于 min_version，不更新无法继续使用）。
        case required
    }

    let kind: Kind
    let info: OTAInfo
}

enum SemVer {
    /// 宽松比较：只取数字段，长度不足补 0；非法片段按 0 处理。
    static func parse(_ string: String) -> (Int, Int, Int) {
        let parts = string.split(separator: ".").prefix(3)
        var numbers = parts.map { Int($0) ?? 0 }
        while numbers.count < 3 {
            numbers.append(0)
        }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// lhs > rhs 时返回 true。
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        parse(lhs) > parse(rhs)
    }

    /// lhs < rhs 时返回 true。
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        parse(lhs) < parse(rhs)
    }
}

/// OTA 更新检查器：启动时拉取更新清单，与当前版本比较。
///
/// 触发条件：应用每次冷启动后检查一次；接口失败静默跳过（离线可用优先）。
/// 强更判定：当前版本 < min_version → required；否则 latest > 当前 → available。
@MainActor
final class UpdateChecker: ObservableObject {
    /// 更新提示。公开 setter 是有意的：`.alert(item:)` 关闭时需要回写 nil 来消除弹窗。
    @Published var announcement: UpdateAnnouncement?

    private let manifestURL: URL?
    private let session: URLSession
    private var didCheck = false

    init(manifestURL: URL?, session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    func check() async {
        guard !didCheck else { return }
        didCheck = true
        guard let manifestURL else { return }

        do {
            let (data, _) = try await session.data(from: manifestURL)
            let info = try JSONCoding.decode(OTAInfo.self, from: data)
            let current = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

            if SemVer.isOlder(current, than: info.minVersion) {
                announcement = UpdateAnnouncement(kind: .required, info: info)
            } else if SemVer.isNewer(info.latestVersion, than: current) {
                announcement = UpdateAnnouncement(kind: .available, info: info)
            }
        } catch {
            // 清单不可达/解析失败：静默降级，不影响正常使用。
        }
    }
}
