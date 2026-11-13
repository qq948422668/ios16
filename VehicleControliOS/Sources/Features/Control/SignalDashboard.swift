import SwiftUI

/// 车况仪表盘：对齐零跑 App 首页的「电量环 + 续航 + 关键车况」布局，
/// 数据全部来自官方 signalMap（文档 §5.1）。
struct SignalDashboard: View {
    let snapshot: VehicleSnapshot?

    private var percent: Double { snapshot?.battery.percent ?? 0 }
    private var rangeKm: Int { Int((snapshot?.battery.rangeKm ?? 0).rounded()) }
    private var details: SignalDetails? { snapshot?.details }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                socRing
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(rangeKm)")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("km")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    Text("剩余续航 · \(rangeModeText)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))

                    chargeChip
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Color.white.opacity(0.08))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                stat("总里程", details?.totalMileageKm.map { "\(Int($0)) km" } ?? "--")
                stat("挡位", details?.gear ?? "--")
                stat("车内", details?.interiorTempC.map { "\(Int($0))°C" } ?? "--")
                stat("驻车", details?.parkingBrakeOn == true ? "已拉起" : "已释放")
            }

            if let tires = details?.tirePressure {
                tireRow(tires)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.13, blue: 0.20),
                            Color(red: 0.06, green: 0.08, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 子视图

    private var socRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                .stroke(
                    AngularGradient(
                        colors: [Color(red: 0.30, green: 0.85, blue: 0.65), Color(red: 0.20, green: 0.62, blue: 0.95)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: percent)

            VStack(spacing: 0) {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("%").font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 96, height: 96)
    }

    private var chargeChip: some View {
        let charging = snapshot?.battery.charging ?? .unknown
        return HStack(spacing: 5) {
            Image(systemName: charging == .charging ? "bolt.fill" : "bolt.slash")
                .font(.caption2)
            Text(chargingText(charging))
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(charging == .charging ? Color.green : Color.white.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                (charging == .charging ? Color.green : Color.white).opacity(0.12)
            )
        )
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func tireRow(_ tires: SignalDetails.TirePressures) -> some View {
        VStack(spacing: 6) {
            HStack {
                tire("左前", tires.leftFront)
                Spacer()
                Image(systemName: "car.side.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                tire("右前", tires.rightFront)
            }
            HStack {
                tire("左后", tires.leftRear)
                Spacer()
                tire("右后", tires.rightRear)
            }
        }
        .padding(.horizontal, 6)
    }

    private func tire(_ position: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(position)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
            Text(value.map { String(format: "%.1f bar", $0) } ?? "--")
                .font(.caption2.weight(.medium))
                .foregroundStyle(value == nil ? Color.white.opacity(0.4) : Color.white.opacity(0.85))
        }
    }

    private var rangeModeText: String {
        details?.chargeRemainMinutes.map { "剩余 \($0) 分钟充满" } ?? "CLTC 标准"
    }

    private func chargingText(_ status: ChargingStatus) -> String {
        switch status {
        case .charging: return "充电中"
        case .complete: return "已充满"
        case .fault: return "充电故障"
        case .idle: return "未充电"
        case .unknown: return "状态未知"
        }
    }
}
