import XCTest
import SQLite3
@testable import AgentBar

final class CursorUsageProviderTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        CursorMockURLProtocol.reset()
        suiteName = "CursorUsageProviderTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        CursorMockURLProtocol.reset()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFetchesDollarUsageFromAggregatedEndpoint() async throws {
        let dbPath = try createTempDB(jwt: makeTestJWT(sub: "user_abc123"))

        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"{"totalCostCents": 12345.6, "aggregations": []}"#
        )

        let provider = CursorUsageProvider(
            monthlyUsageLimitUSD: 400,
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .cursor)
        XCTAssertTrue(usage.isAvailable)
        XCTAssertEqual(usage.fiveHourUsage.unit, .dollars)
        XCTAssertEqual(usage.fiveHourUsage.used, 123.456, accuracy: 0.0001) // totalCostCents / 100
        XCTAssertEqual(usage.fiveHourUsage.total, 400)                       // plan USD allotment
        XCTAssertNil(usage.weeklyUsage)
    }

    func testSumsAggregationsWhenTotalCostCentsMissing() async throws {
        let dbPath = try createTempDB(jwt: makeTestJWT(sub: "user_sum"))

        // No top-level totalCostCents -> fall back to summing per-model aggregations.
        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"""
            {"aggregations": [
                {"modelIntent": "gpt-5", "totalCents": 1000.0},
                {"modelIntent": "claude", "totalCents": 250.5}
            ]}
            """#
        )

        let provider = CursorUsageProvider(
            monthlyUsageLimitUSD: 400,
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 12.505, accuracy: 0.0001) // (1000 + 250.5) / 100
    }

    func testComputesResetFromStartOfMonth() async throws {
        let dbPath = try createTempDB(jwt: makeTestJWT(sub: "user_xyz"))

        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"{"totalCostCents": 0}"#
        )

        let provider = CursorUsageProvider(
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        let usage = try await provider.fetchUsage()

        // Reset should be startOfMonth + 1 month = 2026-03-01
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: usage.fiveHourUsage.resetTime!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 1)
    }

    func testUsesPlanLimitAsTotal() async throws {
        let dbPath = try createTempDB(jwt: makeTestJWT(sub: "user_total"))

        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"{"totalCostCents": 5000}"#
        )

        let provider = CursorUsageProvider(
            monthlyUsageLimitUSD: 60,
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.total, 60)
    }

    func testHandlesMissingDatabase() async {
        let provider = CursorUsageProvider(
            dbPathProvider: { "/nonexistent/path/state.vscdb" },
            defaults: testDefaults
        )

        let isConfigured = await provider.isConfigured()
        XCTAssertFalse(isConfigured)
    }

    func testSendsRequiredOriginHeaderOnAggregatedRequest() async throws {
        let dbPath = try createTempDB(jwt: makeTestJWT(sub: "user_origin"))

        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"{"totalCostCents": 100}"#
        )

        let provider = CursorUsageProvider(
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        _ = try await provider.fetchUsage()

        // The dashboard endpoint rejects requests without a matching Origin (CSRF guard).
        let aggregatedRequest = CursorMockURLProtocol.capturedRequests.first {
            $0.url?.absoluteString.contains("aggregated-usage-events") == true
        }
        XCTAssertNotNil(aggregatedRequest)
        XCTAssertEqual(aggregatedRequest?.httpMethod, "POST")
        XCTAssertEqual(aggregatedRequest?.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertTrue(
            aggregatedRequest?.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=") == true
        )
    }

    func testEncodesReservedCharactersInUserAndCookieHeader() async throws {
        let userId = "auth0|abc/def?x=1"
        let jwt = makeTestJWT(sub: userId)
        let dbPath = try createTempDB(jwt: jwt)

        CursorMockURLProtocol.stub(
            legacy: #"{"startOfMonth": "2026-02-01T00:00:00.000Z"}"#,
            aggregated: #"{"totalCostCents": 1}"#
        )
        CursorMockURLProtocol.onRequest = { request in
            // Only assert on the legacy GET, which carries the `user` query item.
            guard let url = request.url, url.path.contains("/api/usage") else { return }

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryUserId = components?.queryItems?.first(where: { $0.name == "user" })?.value
            XCTAssertEqual(queryUserId, userId)
            XCTAssertTrue(components?.percentEncodedQuery?.contains("%7C") == true)

            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: allowed) ?? userId
            let encodedJWT = jwt.addingPercentEncoding(withAllowedCharacters: allowed) ?? jwt
            let expectedCookie = "WorkosCursorSessionToken=\(encodedUserId)%3A%3A\(encodedJWT)"
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), expectedCookie)
        }

        let provider = CursorUsageProvider(
            session: CursorMockURLProtocol.session(),
            dbPathProvider: { dbPath },
            defaults: testDefaults
        )

        _ = try await provider.fetchUsage()
    }

    func testJWTDecoding() throws {
        let jwt = makeTestJWT(sub: "user_12345")
        let userId = try CursorUsageProvider.decodeUserIdFromJWT(jwt)
        XCTAssertEqual(userId, "user_12345")
    }

    // MARK: - Helpers

    private func makeTestJWT(sub: String) -> String {
        // Header: {"alg":"HS256","typ":"JWT"}
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

        // Payload with sub claim
        let payloadJSON = "{\"sub\":\"\(sub)\",\"iat\":1700000000}"
        let payloadData = payloadJSON.data(using: .utf8)!
        let payload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // Fake signature
        let signature = "fake_signature"

        return "\(header).\(payload).\(signature)"
    }

    private func createTempDB(jwt: String) throws -> String {
        let tempDir = NSTemporaryDirectory()
        let dbPath = (tempDir as NSString).appendingPathComponent("test_state_\(UUID().uuidString).vscdb")

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create test DB"])
        }
        defer { sqlite3_close(db) }

        let createSQL = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT)"
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create table"])
        }

        let insertSQL = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare insert"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (jwt as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to insert"])
        }

        return dbPath
    }
}

// MARK: - Mock URL Protocol

/// Routes the provider's two calls to separate stubs: the legacy `/api/usage` GET and
/// the `dashboard/get-aggregated-usage-events` POST.
private final class CursorMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var data: Data
        var status: Int
    }

    nonisolated(unsafe) static var legacyStub = Stub(data: Data(), status: 200)
    nonisolated(unsafe) static var aggregatedStub = Stub(data: Data(), status: 200)
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?

    static func reset() {
        legacyStub = Stub(data: Data(), status: 200)
        aggregatedStub = Stub(data: Data(), status: 200)
        capturedRequests = []
        onRequest = nil
    }

    static func stub(
        legacy: String,
        legacyStatus: Int = 200,
        aggregated: String,
        aggregatedStatus: Int = 200
    ) {
        legacyStub = Stub(data: Data(legacy.utf8), status: legacyStatus)
        aggregatedStub = Stub(data: Data(aggregated.utf8), status: aggregatedStatus)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func isAggregated(_ request: URLRequest) -> Bool {
        request.url?.absoluteString.contains("aggregated-usage-events") ?? false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CursorMockURLProtocol.capturedRequests.append(request)
        CursorMockURLProtocol.onRequest?(request)

        let stub = CursorMockURLProtocol.isAggregated(request)
            ? CursorMockURLProtocol.aggregatedStub
            : CursorMockURLProtocol.legacyStub

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: nil
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
