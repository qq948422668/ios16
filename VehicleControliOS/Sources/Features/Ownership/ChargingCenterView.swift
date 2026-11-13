import SwiftUI

/// 行驶统计聚合模型（接口 17/18/19 合并视图）。
struct DrivingStats: Sendable {
    let detail: DrivingDetail
    let weekly: WeeklyEnergy?
}

/// 充电中心：健康充电上限 + 谷电预约充电（cmdid=190）+ 电池预热（cmdid=161）。
struct ChargingCenterView: View {
    let vehicleId: String
    let service: any VehicleServicing

    @State private var chargeLimit = 80.0
    @State private var pushState = false
    @State private var scheduledCharging = false
    @State private var chargeStart = "23:00"
    @State private var chargeEnd = "07:00"
    @State private var preheatOn = false
    @State private var preheatTime = "07:30"
    @State private var busy = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section("健康充电上限（50% ~ 100%）") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("充电至 \(Int(chargeLimit))%")
                        .font(.title3.bold())
                    Slider(value: $chargeLimit, in: 50...100, step: 5)
                    Toggle("策略推送到车端", isOn: $pushState)
                        .disabled(true)
                }
                Button {
                    Task { await saveChargeLimit() }
                } label: {
                    if busy { ProgressView() } else { Text("保存充电上限") }
                }
                .disabled(busy)
            }

            Section("谷电预约充电（cmdid 190）") {
                Toggle("启用预约", isOn: $scheduledCharging)
                if scheduledCharging {
                    DatePicker("开始时间", selection: .constant(Date()), displayedComponents: .hourAndMinute)
                        .disabled(true)
                    Text("时段 \(chargeStart) → \(chargeEnd) · 覆盖每周一至周日 · 目标 \(Int(chargeLimit))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await applyScheduledCharging() }
                } label: {
                    Text(scheduledCharging ? "下发预约计划" : "取消预约")
                }
                .disabled(busy)
            }

            Section("预约电池预热（cmdid 161）") {
                Toggle("启用预热", isOn: $preheatOn)
                if preheatOn {
                    Text("每日 \(preheatTime) 自动预热电池（工作日生效）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await applyPreheat() }
                } label: {
                    Text(preheatOn ? "下发预热计划" : "取消预热")
                }
                .disabled(busy)
            }
        }
        .navigationTitle("充电中心")
        .alert("提示", isPresented: presenceBinding($notice)) {
            Button("好", role: .cancel) {}
        } message: { Text(notice ?? "") }
        .alert("失败", isPresented: presenceBinding($error)) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task {
            pushState = (try? await service.chargePushState(vehicleId: vehicleId)) ?? false
        }
    }

    private func saveChargeLimit() async {
        await run {
            try await service.setChargeLimit(
                vehicleId: vehicleId, targetSoc: Int(chargeLimit)
            )
            notice = "充电上限已设置为 \(Int(chargeLimit))%"
        }
    }

    private func applyScheduledCharging() async {
        await run {
            let payload: [String: Any] = scheduledCharging ? [
                "chargeEnable": 1,
                "chargesoc": Int(chargeLimit),
                "circulation": 1,
                "cycles": "1,2,3,4,5,6,7",
                "starttime": chargeStart,
                "endtime": chargeEnd,
                "recharge": 1,
            ] : ["chargeEnable": 0]
            let state = String(
                data: try JSONSerialization.data(withJSONObject: payload),
                encoding: .utf8
            ) ?? "{}"
            _ = try await service.sendRawCommand(
                cmdid: "190", vehicleId: vehicleId, state: state
            )
            notice = scheduledCharging ? "谷电预约已下发" : "谷电预约已取消"
        }
    }

    private func applyPreheat() async {
        await run {
            let payload: [String: Any]
            if preheatOn {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let now = Date()
                payload = [
                    "controls": [[
                        "on": "1",
                        "set_id": "ptc_set_\(Int64(now.timeIntervalSince1970 * 1000))",
                        "start_time": formatter.string(from: now),
                        "update_time": String(Int64(now.timeIntervalSince1970 * 1000)),
                        "days": [1, 2, 3, 4, 5],
                    ]]
                ]
            } else {
                payload = ["controls": []]
            }
            let state = String(
                data: try JSONSerialization.data(withJSONObject: payload),
                encoding: .utf8
            ) ?? "{}"
            _ = try await service.sendRawCommand(
                cmdid: "161", vehicleId: vehicleId, state: state
            )
            notice = preheatOn ? "电池预热已下发" : "电池预热已取消"
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        error = nil
        notice = nil
        do {
            try await operation()
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

/// 把可选字符串消息绑定成 alert(isPresented:)。
private func presenceBinding(_ value: Binding<String?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { shown in if !shown { value.wrappedValue = nil } }
    )
}
