import Foundation

enum StreamStatus: Sendable, Equatable {
    case connecting
    case live
    case polling
    case offline
}

enum VehicleStreamEvent: Sendable {
    case status(StreamStatus)
    case snapshot(VehicleSnapshot)
}

protocol VehicleStreaming: Sendable {
    func events(for vehicleId: String) -> AsyncStream<VehicleStreamEvent>
}

/// 长连接优先、失败降级轮询的混合推送源：
/// 1. 立即拉一次快照，保证首屏不空白；
/// 2. 建立 WebSocket 接收增量；
/// 3. 断链后进入 60s 轮询窗口，同时指数退避重连；
/// 4. 连续失败 3 次 → offline，由上层提示用户手动刷新。
final class HybridVehicleStream: VehicleStreaming, @unchecked Sendable {
    private let client: APIClient
    private let environment: AppEnvironment
    private let tokenProvider: any TokenProviding
    private let session: URLSession

    init(
        client: APIClient,
        environment: AppEnvironment,
        tokenProvider: any TokenProviding,
        session: URLSession = .shared
    ) {
        self.client = client
        self.environment = environment
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func events(for vehicleId: String) -> AsyncStream<VehicleStreamEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.run(vehicleId: vehicleId, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func run(
        vehicleId: String,
        continuation: AsyncStream<VehicleStreamEvent>.Continuation
    ) async {
        if let initial = try? await client.send(VehicleAPI.snapshot(vehicleId: vehicleId)) {
            continuation.yield(.snapshot(initial))
        }

        var consecutiveFailures = 0
        while !Task.isCancelled {
            continuation.yield(.status(.connecting))
            do {
                let socket = try await openSocket(vehicleId: vehicleId)
                continuation.yield(.status(.live))

                for try await payload in socket.messages {
                    if let snapshot = try? JSONCoding.decode(VehicleSnapshot.self, from: payload) {
                        continuation.yield(.snapshot(snapshot))
                        consecutiveFailures = 0
                    }
                }
                socket.cancel(with: .goingAway, reason: nil)
            } catch {
                // 断链后先降级轮询，避免用户看到一屏过期数据。
            }

            await pollFallback(vehicleId: vehicleId, continuation: continuation)
            consecutiveFailures += 1

            let backoff = min(pow(2, Double(consecutiveFailures)), 30)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }

        continuation.finish()
    }

    private func pollFallback(
        vehicleId: String,
        continuation: AsyncStream<VehicleStreamEvent>.Continuation
    ) async {
        continuation.yield(.status(.polling))
        var failures = 0
        let deadline = Date().addingTimeInterval(60)

        while !Task.isCancelled, Date() < deadline {
            do {
                let snapshot = try await client.send(VehicleAPI.snapshot(vehicleId: vehicleId))
                continuation.yield(.snapshot(snapshot))
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 {
                    continuation.yield(.status(.offline))
                    return
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(environment.pollingInterval * 1_000_000_000))
        }
    }

    private func openSocket(vehicleId: String) async throws -> URLSessionWebSocketTask {
        let path = VehicleAPI.streamPath(vehicleId: vehicleId)
        guard let url = URL(string: path, relativeTo: environment.streamBaseURL) else {
            throw APIError.invalidRequest("推送地址无效：\(path)")
        }
        let token = try await tokenProvider.accessToken()

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }
}

private extension URLSessionWebSocketTask {
    /// 把回调式 receive() 包装成可 for-await 的流，便于和轮询逻辑组合。
    var messages: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task {
                while true {
                    do {
                        let message = try await self.receive()
                        switch message {
                        case .data(let data):
                            continuation.yield(data)
                        case .string(let text):
                            if let data = text.data(using: .utf8) {
                                continuation.yield(data)
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
