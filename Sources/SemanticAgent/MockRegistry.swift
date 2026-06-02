#if DEBUG
import Foundation

// MARK: - Mock Registry Protocol

protocol MockRegistryProtocol {
    func canHandle(url: URL, method: String) -> Bool
    func handle(url: URL, method: String) -> MockResponse?
    func register(mocks: [MockEntry])
    func clear()
    func clear(urlPattern: String)
}

struct MockEntry {
    let urlPattern: String
    let method: String
    let response: MockResponse
}

struct MockResponse {
    let status: Int
    let body: Data
    let headers: [String: String]
}

// MARK: - Mock Registry Implementation

final class MockRegistry: MockRegistryProtocol {
    static let shared = MockRegistry()
    private var entries: [MockEntry] = []
    private let lock = NSLock()

    func canHandle(url: URL, method: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { entry in
            url.path.contains(entry.urlPattern) &&
            (entry.method == "*" || entry.method.uppercased() == method.uppercased())
        }
    }

    func handle(url: URL, method: String) -> MockResponse? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { entry in
            url.path.contains(entry.urlPattern) &&
            (entry.method == "*" || entry.method.uppercased() == method.uppercased())
        }?.response
    }

    func register(mocks: [MockEntry]) {
        lock.lock()
        entries.append(contentsOf: mocks)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func clear(urlPattern: String) {
        lock.lock()
        entries.removeAll { $0.urlPattern == urlPattern }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private(set) var hitCount: Int = 0
    private(set) var hitLog: [(url: String, method: String, status: Int)] = []

    func recordHit(url: String, method: String, status: Int) {
        lock.lock()
        hitCount += 1
        hitLog.append((url: url, method: method, status: status))
        lock.unlock()
    }

    func hitSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let entries = hitLog.map { "\($0.method) \($0.url) → \($0.status)" }
        return "hits: \(hitCount)\n" + entries.joined(separator: "\n")
    }
}

// MARK: - URLProtocol Adapter

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if url.host == "127.0.0.1" || url.host == "localhost" { return false }
        let can = MockRegistry.shared.canHandle(url: url, method: request.httpMethod ?? "GET")
        if MockRegistry.shared.count > 0 {
            print("[MockURLProtocol] canInit: \(request.httpMethod ?? "GET") \(url.absoluteString.prefix(100)) → \(can)")
        }
        return can
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let mock = MockRegistry.shared.handle(url: url, method: request.httpMethod ?? "GET") else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        MockRegistry.shared.recordHit(url: url.path, method: request.httpMethod ?? "GET", status: mock.status)
        print("[MockURLProtocol] served: \(request.httpMethod ?? "GET") \(url.path) → \(mock.status)")

        var headerFields = mock.headers
        headerFields["X-Mock"] = "true"

        if let response = HTTPURLResponse(url: url, statusCode: mock.status,
                                          httpVersion: "HTTP/1.1", headerFields: headerFields) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: mock.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func install() {
        URLProtocol.registerClass(MockURLProtocol.self)
        swizzleSessionConfiguration()
    }

    static func uninstall() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        unswizzleSessionConfiguration()
    }

    private static var isSwizzled = false

    private static func swizzleSessionConfiguration() {
        guard !isSwizzled else { return }
        let orig = class_getInstanceMethod(URLSessionConfiguration.self,
                                           #selector(getter: URLSessionConfiguration.protocolClasses))!
        let swizzled = class_getInstanceMethod(URLSessionConfiguration.self,
                                               #selector(getter: URLSessionConfiguration.mock_protocolClasses))!
        method_exchangeImplementations(orig, swizzled)
        isSwizzled = true
    }

    private static func unswizzleSessionConfiguration() {
        guard isSwizzled else { return }
        let orig = class_getInstanceMethod(URLSessionConfiguration.self,
                                           #selector(getter: URLSessionConfiguration.protocolClasses))!
        let swizzled = class_getInstanceMethod(URLSessionConfiguration.self,
                                               #selector(getter: URLSessionConfiguration.mock_protocolClasses))!
        method_exchangeImplementations(orig, swizzled)
        isSwizzled = false
    }
}
// MARK: - URLSessionConfiguration Swizzle

extension URLSessionConfiguration {
    @objc dynamic var mock_protocolClasses: [AnyClass]? {
        var classes = self.mock_protocolClasses ?? []
        if !classes.contains(where: { $0 == MockURLProtocol.self }) {
            classes.insert(MockURLProtocol.self, at: 0)
        }
        return classes
    }
}
#endif
