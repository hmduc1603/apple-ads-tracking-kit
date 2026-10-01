import XCTest
@testable import AdTrackingKit

final class AdTrackingKitTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testConfigDefaultsToHostBundleIdentifier() {
        let config = AdTrackingConfig(backendURL: URL(string: "https://example.com")!, apiKey: "test-key")
        XCTAssertEqual(config.bundleId, Bundle.main.bundleIdentifier ?? "")
        XCTAssertFalse(config.loggingEnabled)
    }

    func testAppAccountTokenIsStableAndUsesSnippetKey() {
        let store = AccountTokenStore(defaults: Self.freshDefaults())
        let first = store.appAccountToken
        XCTAssertEqual(first, store.appAccountToken)
        XCTAssertEqual(store.defaults.string(forKey: "kd.appAccountToken"), first.uuidString)
    }

    func testAdoptsTokenWrittenByDashboardSnippet() {
        let defaults = Self.freshDefaults()
        let existing = UUID()
        defaults.set(existing.uuidString, forKey: "kd.appAccountToken")
        XCTAssertEqual(AccountTokenStore(defaults: defaults).appAccountToken, existing)
    }

    func testRequestShape() throws {
        let client = AttributionAPIClient(config: Self.config(), session: StubURLProtocol.session)
        let payload = AttributionPayload(
            bundleId: "com.example.app",
            appAccountToken: "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
            attributionToken: nil,
            sdkVersion: AdTrackingKit.sdkVersion
        )
        let request = try client.makeRequest(payload)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/attribution")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(json["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(json["appAccountToken"] as? String, "6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        XCTAssertEqual(json["sdkVersion"] as? String, AdTrackingKit.sdkVersion)
    }

    func testAcceptedReportIsSentOnlyOnce() async {
        StubURLProtocol.respond(status: 200, body: #"{"success":true,"status":"resolved","campaignId":"42"}"#)
        let (reporter, store) = Self.reporter(token: "token-1")

        let first = await reporter.reportIfNeeded()
        let second = await reporter.reportIfNeeded()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertTrue(store.isReported)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        let body = try! JSONSerialization.jsonObject(with: StubURLProtocol.lastBody!) as! [String: Any]
        XCTAssertEqual(body["attributionToken"] as? String, "token-1")
        XCTAssertEqual(body["appAccountToken"] as? String, store.appAccountToken.uuidString)
    }

    func testPendingResponseStillCountsAsDelivered() async {
        // 202: the backend stored it and keeps resolving on its own — the app must not resend.
        StubURLProtocol.respond(status: 202, body: #"{"success":true,"status":"pending","campaignId":null}"#)
        let (reporter, store) = Self.reporter(token: "token-1")
        let delivered = await reporter.reportIfNeeded()
        XCTAssertTrue(delivered)
        XCTAssertTrue(store.isReported)
    }

    func testServerErrorIsRetried() async {
        StubURLProtocol.respond(status: 503, body: "")
        let (reporter, store) = Self.reporter(token: nil)

        let first = await reporter.reportIfNeeded()
        XCTAssertFalse(first)
        XCTAssertFalse(store.isReported)

        StubURLProtocol.respond(status: 200, body: #"{"success":true,"status":"no_token"}"#)
        let second = await reporter.reportIfNeeded()
        XCTAssertTrue(second)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testRefusalWaitsForNextLaunch() async {
        StubURLProtocol.respond(status: 401, body: #"{"success":false,"message":"Unauthorized"}"#)
        let (reporter, store) = Self.reporter(token: "token-1")

        _ = await reporter.reportIfNeeded()
        _ = await reporter.reportIfNeeded()
        XCTAssertFalse(store.isReported)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // MARK: - Helpers

    private static func config() -> AdTrackingConfig {
        AdTrackingConfig(backendURL: URL(string: "https://example.com")!, apiKey: "test-key", bundleId: "com.example.app")
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "com.adtrackingkit.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private static func reporter(token: String?) -> (AttributionReporter, AccountTokenStore) {
        let store = AccountTokenStore(defaults: freshDefaults())
        let reporter = AttributionReporter(
            client: AttributionAPIClient(config: config(), session: StubURLProtocol.session),
            store: store,
            tokenProvider: { token }
        )
        return (reporter, store)
    }
}

/// Answers every request with a canned response and records what was sent.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private(set) static var requestCount = 0
    nonisolated(unsafe) private(set) static var lastBody: Data?

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func respond(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = Data(body.utf8)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        status = 200; body = Data(); requestCount = 0; lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
