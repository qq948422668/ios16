import Combine
import Foundation

@MainActor
final class VehicleControlViewModel: ObservableObject {
    @Published private(set) var snapshot: VehicleSnapshot?
    @Published private(set) var status: StreamStatus = .connecting
    @Published private(set) var phase: CommandPhase = .idle

    private var streamTask: Task<Void, Never>?
    private var phaseResetTask: Task<Void, Never>?
    private var service: (any VehicleServicing)?
    private var resolver: (any CommandReceiptResolving)?
    private var vehicleId: String?

    var isRunningCommand: Bool {
        if case .running = phase { return true }
        return false
    }

    /// 供附属页面（充电中心/行驶统计/环视照片）定位车辆。
    var currentVehicleId: String? { vehicleId }

    func start(
        vehicle: Vehicle,
        stream: any VehicleStreaming,
        service: any VehicleServicing,
        resolver: any CommandReceiptResolving,
        cache: SnapshotCache
    ) {
        guard streamTask == nil else { return }

        self.service = service
        self.resolver = resolver
        self.vehicleId = vehicle.id

        // 先用本地缓存渲染，网络结果到达后覆盖，避免白屏。
        if snapshot == nil {
            snapshot = cache.latest(for: vehicle.id)
        }

        let events = stream.events(for: vehicle.id)
        streamTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .status(let status):
                    self.status = status
                case .snapshot(let snapshot):
                    self.snapshot = snapshot
                }
            }
        }

        Task { [weak self] in
            await self?.refresh()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        phaseResetTask?.cancel()
        phaseResetTask = nil
    }

    func refresh() async {
        guard let service, let vehicleId else { return }
        if let latest = try? await service.fetchSnapshot(vehicleId: vehicleId) {
            snapshot = latest
        }
    }

    /// 指令链路：提交 -> 等回执（推送优先/轮询兜底）-> 终态；
    /// 成功后补拉一次状态，让 UI 与车辆真实状态对齐。
    func run(_ command: VehicleCommand) async {
        guard let service, let resolver, let vehicleId, !isRunningCommand else { return }

        phase = .running(command.title)
        phaseResetTask?.cancel()

        do {
            let ticket = try await service.send(command, to: vehicleId)
            let receipt = try await resolver.receipt(
                for: ticket,
                vehicleId: vehicleId,
                timeout: 45
            )

            if receipt.isSuccess {
                phase = .succeeded(command.title)
                await refresh()
                schedulePhaseReset()
            } else if receipt.status == .expired {
                phase = .failed(command.title, reason: "车辆未在有效期内响应指令")
            } else {
                phase = .failed(
                    command.title,
                    reason: receipt.failureReason ?? "车辆返回状态：\(receipt.status.rawValue)"
                )
            }
        } catch {
            if let apiError = error as? APIError {
                switch apiError {
                case .commandFailed(let reason):
                    phase = .failed(command.title, reason: reason)
                case .cancelled:
                    phase = .failed(command.title, reason: "指令已取消或页面已关闭")
                default:
                    phase = .failed(command.title, reason: apiError.userMessage)
                }
            } else if error is CancellationError {
                phase = .failed(command.title, reason: "指令已取消或页面已关闭")
            } else {
                phase = .failed(command.title, reason: error.localizedDescription)
            }
        }
    }

    func dismissPhase() {
        phaseResetTask?.cancel()
        phaseResetTask = nil
        phase = .idle
    }

    private func schedulePhaseReset() {
        phaseResetTask?.cancel()
        phaseResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }
}
