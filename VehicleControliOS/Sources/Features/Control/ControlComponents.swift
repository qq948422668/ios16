import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String?
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.title3.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

struct ControlTile: View {
    let command: VehicleCommand
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: command.systemImage)
                    .font(.title3)
                Text(command.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(command.requiresConfirmation ? 0.35 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? (isBusy ? 0.45 : 1) : 0.4)
    }
}

struct StreamStatusPill: View {
    let status: StreamStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
    }

    private var text: String {
        switch status {
        case .connecting: return "连接中"
        case .live: return "实时"
        case .polling: return "轮询中"
        case .offline: return "已断开"
        }
    }

    private var color: Color {
        switch status {
        case .connecting: return .orange
        case .live: return .green
        case .polling: return .orange
        case .offline: return .red
        }
    }
}

struct CommandBanner: View {
    let phase: CommandPhase
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.footnote.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.3), lineWidth: 1)
        )
    }

    private var headline: String {
        switch phase {
        case .idle: return ""
        case .running(let title): return "正在执行：\(title)"
        case .succeeded(let title): return "已完成：\(title)"
        case .failed(let title, _): return "执行失败：\(title)"
        }
    }

    private var detail: String? {
        switch phase {
        case .idle, .succeeded: return nil
        case .running: return "指令已提交云端，等待车辆回执…"
        case .failed(_, let reason): return reason
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var accent: Color {
        switch phase {
        case .idle: return .clear
        case .running: return .orange
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
