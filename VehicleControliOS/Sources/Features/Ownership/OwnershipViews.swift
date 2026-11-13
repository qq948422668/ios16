import SwiftUI

/// iOS 16 兼容的空状态占位（替代 iOS 17 的 ContentUnavailableView）。
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// 行驶统计：总量卡 + 近 7 日柱状图 + 近 6 周能耗与排行（接口 17/18/19）。
struct DrivingStatsView: View {
    let vehicleId: String
    let service: any VehicleServicing

    @State private var stats: DrivingStats?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let stats {
                ScrollView {
                    VStack(spacing: 16) {
                        totalsCard(stats.detail)
                        if let daily = stats.detail.detail, !daily.isEmpty {
                            dailyChart(daily)
                        }
                        if let weekly = stats.weekly {
                            weeklyCard(weekly)
                        }
                    }
                    .padding()
                }
            } else if isLoading {
                ProgressView("加载行驶数据…")
            } else {
                EmptyStateView(
                    title: "暂无数据",
                    systemImage: "chart.bar",
                    message: error ?? "该车辆暂无行驶记录"
                )
            }
        }
        .navigationTitle("行驶统计")
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            stats = try await service.fetchDrivingStats(vehicleId: vehicleId)
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func totalsCard(_ detail: DrivingDetail) -> some View {
        let items: [(String, String)] = [
            ("总里程", detail.totalMileage.map { String(format: "%.1f km", $0) } ?? "—"),
            ("累计电耗", detail.totalEnergy.map { String(format: "%.1f kWh", $0) } ?? "—"),
            ("累计油耗", detail.totalFuel.map { String(format: "%.1f L", $0) } ?? "—"),
            ("百公里能耗", detail.averageEnergy.map { String(format: "%.1f", $0) } ?? "—"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(spacing: 4) {
                    Text(item.1).font(.headline)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func dailyChart(_ daily: [DailyMileage]) -> some View {
        let maxMileage = daily.compactMap(\.accumulatedMileage).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("近 7 日里程").font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(daily, id: \.day) { item in
                    VStack(spacing: 4) {
                        Text(item.accumulatedMileage.map { String(format: "%.0f", $0) } ?? "-")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(height: CGFloat(item.accumulatedMileage ?? 0) / CGFloat(max(maxMileage, 1)) * 110 + 6)
                        Text(item.day.suffix(5).description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func weeklyCard(_ weekly: WeeklyEnergy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("近 6 周百公里能耗").font(.headline)
            if let rank = weekly.rankPercent {
                Text("同车型能耗排行：优于全国 \(String(format: "%.0f%%", 100 - rank)) 的车主")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            let points = weekly.points.suffix(6)
            if !points.isEmpty {
                let maxEc = points.compactMap(\.ec).max() ?? 1
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.7))
                                .frame(height: CGFloat(point.ec ?? 0) / CGFloat(max(maxEc, 1)) * 90 + 6)
                            Text(point.week ?? "-")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 驻车环视照片（接口 12）：元信息 → OSS 图下载 → 双指缩放预览。
struct ParkingPhotoView: View {
    let vehicleId: String
    let service: any VehicleServicing

    @State private var image: UIImage?
    @State private var uploadedAt: Date?
    @State private var isLoading = false
    @State private var error: String?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(lastScale * value, 0.8), 5.0)
                                }
                                .onEnded { _ in lastScale = scale }
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                if let uploadedAt {
                    Text("拍摄于 \(uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if isLoading {
                ProgressView("正在获取环视照片…")
            } else {
                EmptyStateView(
                    title: "暂无照片",
                    systemImage: "camera.on.rectangle",
                    message: error ?? "车辆尚未上传驻车环视照片"
                )
            }
        }
        .navigationTitle("驻车环视")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await service.fetchParkingPhoto(vehicleId: vehicleId)
            uploadedAt = info.uploadedAt
            let (data, _) = try await URLSession.shared.data(from: URL(string: info.fileUrl)!)
            image = UIImage(data: data)
            if image == nil {
                error = "照片数据无法解码"
            }
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
