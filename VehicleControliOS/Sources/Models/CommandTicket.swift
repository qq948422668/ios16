import Foundation

/// 指令下发后返回的工单：车控是异步链路，HTTP 200 只代表“已受理”，
/// 真实结果必须靠回执确认。
struct CommandTicket: Decodable, Sendable, Equatable, Identifiable {
    let ticketId: String
    let status: CommandStatus
    let requestedAt: Date?

    var id: String { ticketId }
}

struct CommandReceipt: Decodable, Sendable, Equatable {
    let ticketId: String
    let status: CommandStatus
    let failureReason: String?
    let completedAt: Date?

    var isSuccess: Bool { status == .succeeded }
}

enum CommandStatus: String, Decodable, Sendable {
    case pending
    case dispatched
    case accepted
    case running
    case succeeded
    case failed
    case expired
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        self = CommandStatus(rawValue: raw) ?? .unknown
    }

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .expired: return true
        default: return false
        }
    }
}

/// 面向 UI 的指令阶段，供横幅/Toast 直接展示。
enum CommandPhase: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String, reason: String)
}
