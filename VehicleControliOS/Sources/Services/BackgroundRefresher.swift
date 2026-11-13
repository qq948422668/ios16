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

    /// 启动期登记的活跃实例：系统触发 BGTask 时由它消费。
    private static let instanceLock = NSLock()
    private static var active: BackgroundRefresher?

    init(service: any VehicleServicing, cache: SnapshotCache) {
        self.service = service
        self.cache = cache
    }

    /// 必须在 AppDelegate 的 didFinishLaunching 里调用：BGTask 的 launch
    /// handler 只允许在 App 完成启动之前注册，iOS 15+ 晚于启动注册会抛
    /// NSInternalInconsistencyException 直接闪退（此前正是在 SwiftUI .task
    /// 里注册导致签名安装后一启动就崩）。
    /// 这里只登记 handler 本身；业务实例由 start() 在容器装配完成后挂入。
    static func registerAtLaunch() {
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            dispatch(task)
        }
        if !accepted {
            // 仅当 Info.plist 未登记该标识符时发生：停用后台刷新而非崩溃。
            Logger(subsystem: "com.vehiclecontrol.app", category: "background")
                .error("BGTask register rejected; background refresh disabled")
        }
    }

    private static func dispatch(_ task: BGTask) {
        instanceLock.lock()
        let instance = active
        instanceLock.unlock()
        guard let instance else {
            task.setTaskCompleted(success: false)
            return
        }
        instance.handle(task)
    }

    /// 容器装配完成后调用：挂入活跃实例并提交首次调度请求。
    /// （submit 不受启动时序限制，晚于启动调用是安全的。）
    func start() {
        Self.instanceLock.lock()
        Self.active = self
        Self.instanceLock.unlock()
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
