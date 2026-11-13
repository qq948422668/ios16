import BackgroundTasks
import Foundation
import os

/// 后台刷新：用 BGAppRefreshTask 周期性同步车辆状态并落缓存。
///
/// 注意：iOS 只把它当作“机会”而非保证，执行时机由系统调度（通常 ≥15 分钟，
/// 且受低电量模式、后台 App 刷新开关影响）。车控指令**不要**依赖后台任务，
/// 指令链路的可靠性由「回执轮询 + APNs 推送」保证。
final class BackgroundRefresher: @unchecked Sendable {
    static let taskIdentifier = "com.vehiclecontrol.app.refresh"

    private let service: any VehicleServicing
    private let cache: SnapshotCache
    private let log = Logger(subsystem: "com.vehiclecontrol.app", category: "background")
    private var registered = false

    init(service: any VehicleServicing, cache: SnapshotCache) {
        self.service = service
        self.cache = cache
    }

    /// 必须在 App 启动完成前调用（didFinishLaunching 阶段），否则系统会拒绝注册。
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handle(task)
        }
        schedule()
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.debug("submit refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ task: BGTask) {
        schedule()

        let work = Task { [service = self.service, cache = self.cache, log = self.log] in
            do {
                let vehicles = try await service.fetchVehicles()
                var snapshots: [VehicleSnapshot] = []
                snapshots.reserveCapacity(vehicles.count)

                for vehicle in vehicles {
                    if let snapshot = try? await service.fetchSnapshot(vehicleId: vehicle.id) {
                        snapshots.append(snapshot)
                    }
                }

                if !snapshots.isEmpty {
                    cache.save(snapshots)
                }
                log.info("background refresh done: \(snapshots.count, privacy: .public) vehicles")
                task.setTaskCompleted(success: !snapshots.isEmpty)
            } catch {
                log.error("background refresh failed: \(error.localizedDescription, privacy: .public)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
