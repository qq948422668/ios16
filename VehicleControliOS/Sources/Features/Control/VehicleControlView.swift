import SwiftUI

struct VehicleControlView: View {
    let vehicle: Vehicle

    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel = VehicleControlViewModel()
    @State private var pendingCommand: VehicleCommand?

    private var availableCommands: [VehicleCommand] {
        VehicleCommand.allCases.filter { command in
            guard let capability = command.requiredCapability else { return true }
            return vehicle.capabilities.contains(capability)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summary

                if viewModel.phase != .idle {
                    CommandBanner(phase: viewModel.phase) { viewModel.dismissPhase() }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                metrics

                controlSection

                footer
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                StreamStatusPill(status: viewModel.status)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
        .task {
            viewModel.start(
                vehicle: vehicle,
                stream: container.vehicleStream,
                service: container.vehicleService,
                resolver: container.receiptResolver,
                cache: container.snapshotCache
            )
        }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            pendingCommand.map { "确认执行「\($0.title)」？" } ?? "",
            isPresented: Binding(
                get: { pendingCommand != nil },
                set: { if !$0 { pendingCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认执行", role: .destructive) {
                guard let command = pendingCommand else { return }
                pendingCommand = nil
                Task { await viewModel.run(command) }
            }
            Button("取消", role: .cancel) {
                pendingCommand = nil
            }
        } message: {
            Text("该操作会立即通过官方云通道下发到车辆，请确认车辆周围环境安全。")
        }
    }

    // MARK: - Sections

    private var summary: some View {
        HStack(spacing: 14) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.model)
                    .font(.subheadline.weight(.semibold))
                Text("VIN \(vehicle.vin)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let updatedAt = viewModel.snapshot?.capturedAt {
                    Text("状态更新于 \(updatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            MetricCard(
                title: "电量",
                value: viewModel.snapshot.map { "\(Int($0.battery.percent.rounded()))%" } ?? "--",
                detail: viewModel.snapshot.map { "\(Int($0.battery.rangeKm.rounded())) km 续航" },
                systemImage: "battery.75"
            )
            MetricCard(
                title: "充电",
                value: viewModel.snapshot?.battery.charging.label ?? "--",
                detail: viewModel.snapshot?.battery.chargeLimitPercent.map { "限值 \(Int($0))%" },
                systemImage: "bolt.fill",
                tint: .green
            )
            MetricCard(
                title: "车门",
                value: securityText,
                detail: viewModel.snapshot?.security.trunkOpen == true ? "后备箱开启" : nil,
                systemImage: viewModel.snapshot?.security.isLocked == false ? "lock.open.fill" : "lock.fill",
                tint: viewModel.snapshot?.security.isLocked == false ? .orange : .accentColor
            )
            MetricCard(
                title: "空调",
                value: climateText,
                detail: viewModel.snapshot?.climate.insideCelsius.map { "车内 \(Int($0))°C" },
                systemImage: "fanblades.fill",
                tint: viewModel.snapshot?.climate.isOn == true ? .cyan : .secondary
            )
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("远程控制")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(availableCommands) { command in
                    ControlTile(
                        command: command,
                        isEnabled: !availableCommands.isEmpty,
                        isBusy: viewModel.isRunningCommand
                    ) {
                        if command.requiresConfirmation {
                            pendingCommand = command
                        } else {
                            Task { await viewModel.run(command) }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("所有指令经由官方车联网通道下发，HTTP 成功仅表示云端已受理，最终结果以车辆回执为准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("网络断开时请下拉刷新或点击右上角重试，避免重复下发同一指令。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var securityText: String {
        guard let security = viewModel.snapshot?.security else { return "--" }
        return security.isLocked ? "已锁车" : "未锁车"
    }

    private var climateText: String {
        guard let climate = viewModel.snapshot?.climate else { return "--" }
        guard climate.isOn else { return "已关闭" }
        return climate.targetCelsius.map { "设定 \(Int($0))°C" } ?? "运行中"
    }
}
