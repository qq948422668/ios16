import Foundation

/// 状态快照的本地缓存（Caches 目录，可被系统回收）。
/// 用途：冷启动 / 后台刷新后，进入车控页先渲染上次结果，避免白屏等待网络。
struct SnapshotCache: Sendable {
    private let fileURL: URL

    init(fileName: String = "snapshots.json") {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base.appendingPathComponent(fileName)
    }

    func save(_ snapshots: [VehicleSnapshot]) {
        do {
            let data = try JSONCoding.encode(snapshots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 缓存失败不影响主流程。
        }
    }

    func latest(for vehicleId: String) -> VehicleSnapshot? {
        load().first { $0.vehicleId == vehicleId }
    }

    private func load() -> [VehicleSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONCoding.decode([VehicleSnapshot].self, from: data)) ?? []
    }
}
