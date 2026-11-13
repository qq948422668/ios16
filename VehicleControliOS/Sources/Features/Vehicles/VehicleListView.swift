import SwiftUI

struct VehicleListView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var session: SessionStore
    @StateObject private var viewModel = VehicleListViewModel()

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的车辆")
            .navigationDestination(for: Vehicle.self) { vehicle in
                VehicleControlView(vehicle: vehicle)
            }
            .refreshable {
                await viewModel.load(service: container.vehicleService, force: true)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            Task { await session.signOut() }
                        } label: {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .task {
                await viewModel.load(service: container.vehicleService)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.vehicles.isEmpty {
            HStack {
                Spacer()
                ProgressView("正在同步车辆…")
                Spacer()
            }
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        } else if viewModel.vehicles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "car.2.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(viewModel.errorMessage ?? "暂无已绑定车辆")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("重新加载") {
                    Task { await viewModel.load(service: container.vehicleService, force: true) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowBackground(Color.clear)
        } else {
            ForEach(viewModel.vehicles) { vehicle in
                NavigationLink(value: vehicle) {
                    VehicleRow(vehicle: vehicle)
                }
            }

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct VehicleRow: View {
    let vehicle: Vehicle

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "car.side.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.displayName)
                    .font(.headline)
                Text(vehicle.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("VIN \(vehicle.vin.suffix(6))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
final class VehicleListViewModel: ObservableObject {
    @Published private(set) var vehicles: [Vehicle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(service: any VehicleServicing, force: Bool = false) async {
        guard !isLoading else { return }
        if !force && !vehicles.isEmpty { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            vehicles = try await service.fetchVehicles()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
