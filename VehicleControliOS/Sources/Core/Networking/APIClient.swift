import Foundation
import os

/// 网络执行器：URL 组装、Bearer 注入、单次 401 自动刷新后重放、
/// 幂等重试、状态码到 APIError 的映射。
final class APIClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any TokenProviding
    private let log = Logger(subsystem: "com.vehiclecontrol.app", category: "network")

    init(baseURL: URL, tokenProvider: any TokenProviding, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
    }

    func send<R: Decodable>(_ request: APIRequest<R>) async throws -> R {
        var attempt = 1
        var didRetryAfterAuth = false

        while true {
            try Task.checkCancellation()
            do {
                return try await perform(request)
            } catch {
                let apiError = Self.normalize(error)

                if case .unauthorized = apiError, request.requiresAuth, !didRetryAfterAuth {
                    didRetryAfterAuth = true
                    do {
                        try await tokenProvider.forceRefresh()
                    } catch {
                        throw APIError.refreshFailed(error.localizedDescription)
                    }
                    continue
                }

                guard apiError.isRetryable,
                      let delay = request.retryPolicy.delay(forAttempt: attempt) else {
                    throw apiError
                }
                attempt += 1
                log.debug("retry \(attempt - 1) after \(delay, privacy: .public)s: \(request.path, privacy: .public)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Private

    private func perform<R: Decodable>(_ request: APIRequest<R>) async throws -> R {
        let urlRequest = try await build(request)
        let result = try await transport(urlRequest)
        let data = result.data

        guard let http = result.response as? HTTPURLResponse else {
            throw APIError.invalidRequest("响应不是 HTTP 协议")
        }

        log.debug("\(http.statusCode, privacy: .public) \(urlRequest.httpMethod ?? "", privacy: .public) \(urlRequest.url?.path ?? "", privacy: .public)")

        switch http.statusCode {
        case 200..<300:
            do {
                return try request.decodeResponse(from: data)
            } catch {
                throw APIError.decoding(error.localizedDescription)
            }
        case 401:
            throw APIError.unauthorized
        default:
            let envelope = try? JSONCoding.decode(APIErrorEnvelope.self, from: data)
            throw APIError.server(
                status: http.statusCode,
                code: envelope?.code,
                message: envelope?.message
            )
        }
    }

    /// 把 URLSession 的各类失败统一收敛成 APIError，避免上层出现裸 URLError。
    private func transport(_ urlRequest: URLRequest) async throws -> (data: Data, response: URLResponse) {
        do {
            return try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            throw urlError.code == .cancelled ? APIError.cancelled : APIError.transport(urlError)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw APIError.cancelled
            }
            throw APIError.invalidRequest(error.localizedDescription)
        }
    }

    private func build<R: Decodable>(_ request: APIRequest<R>) async throws -> URLRequest {
        let relativePath = request.path.hasPrefix("/")
            ? String(request.path.dropFirst())
            : request.path

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(relativePath),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidRequest("无效路径 \(request.path)")
        }

        if !request.query.isEmpty {
            components.queryItems = request.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else {
            throw APIError.invalidRequest("URL 组装失败 \(request.path)")
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue

        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        if request.requiresAuth {
            do {
                let token = try await tokenProvider.accessToken()
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } catch {
                throw (error as? APIError) ?? APIError.notAuthenticated
            }
        }

        return urlRequest
    }

    private static func normalize(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport(urlError)
        }
        if error is CancellationError { return .cancelled }
        return .invalidRequest(error.localizedDescription)
    }
}
