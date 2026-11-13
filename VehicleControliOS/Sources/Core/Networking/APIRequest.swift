import Foundation

/// 一次接口调用的完整描述（等价于 Retrofit 的 @GET/@POST 方法声明），
/// 泛型 Response 决定解码类型，业务层只关心请求/响应模型。
struct APIRequest<Response: Decodable>: Sendable {
    let path: String
    let method: HTTPMethod
    let query: [String: String]
    let headers: [String: String]
    let body: Data?
    let requiresAuth: Bool
    let timeout: TimeInterval
    let retryPolicy: RetryPolicy

    private let decoderOverride: (@Sendable (Data) throws -> Response)?

    init(
        path: String,
        method: HTTPMethod = .get,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval = 20,
        retryPolicy: RetryPolicy = .standard,
        decoder: (@Sendable (Data) throws -> Response)? = nil
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.headers = headers
        self.body = body
        self.requiresAuth = requiresAuth
        self.timeout = timeout
        self.retryPolicy = retryPolicy
        self.decoderOverride = decoder
    }

    func decodeResponse(from data: Data) throws -> Response {
        if let decoderOverride {
            return try decoderOverride(data)
        }
        return try JSONCoding.decode(Response.self, from: data)
    }
}

/// 只关心状态码、不关心响应体的接口（如设备令牌上报，可能返回 204）。
struct EmptyResponse: Decodable {
    init() {}
}
