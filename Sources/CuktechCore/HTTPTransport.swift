import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 一次 HTTP 请求。故意不用 URLRequest 直接当接口，是为了让单测能塞假 transport。
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// 一次 HTTP 响应。**不自动跟随 302**：小米登录要逐跳读 Set-Cookie 拿 serviceToken，
/// 跟丢了就再也拿不到，所以这里把 Location 原样交回调用方自己走。
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// 按出现顺序的 (name, value)，已去掉属性段。
    public var cookies: [(name: String, value: String)]
    public var location: String?

    public init(status: Int, headers: [String: String], body: Data,
                cookies: [(name: String, value: String)] = [], location: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.cookies = cookies
        self.location = location
    }

    public func cookie(_ name: String) -> String? {
        cookies.last { $0.name == name }?.value
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 真正走网络的 transport。
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false        // cookie 全部自己管
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            return HTTPResponse(status: 0, headers: [:], body: data)
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            let name = String(describing: key).lowercased()
            let text = String(describing: value)
            if let existing = headers[name] {
                headers[name] = existing + ", " + text
            } else {
                headers[name] = text
            }
        }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: request.url)
            .map { (name: $0.name, value: $0.value) }

        return HTTPResponse(
            status: http.statusCode,
            headers: headers,
            body: data,
            cookies: cookies,
            location: http.value(forHTTPHeaderField: "Location")
        )
    }
}

/// 关掉 URLSession 的自动重定向（返回 nil 表示「别跟，把响应原样给我」）。
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
