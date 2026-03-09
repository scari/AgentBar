import XCTest
@testable import AgentBar

final class ClaudeUsageProviderTests: XCTestCase {
    private var originalCredentialsFileURLProvider: (@Sendable () -> URL)!
    private var originalCredentialsFileReader: (@Sendable (URL) -> String?)!
    private var originalSecurityCLIRunner: (@Sendable (TimeInterval) -> String?)!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        ClaudeUsageProvider.resetTokenCache()
        originalCredentialsFileURLProvider = ClaudeUsageProvider.credentialsFileURLProvider
        originalCredentialsFileReader = ClaudeUsageProvider.credentialsFileReader
        originalSecurityCLIRunner = ClaudeUsageProvider.securityCLIRunner
    }

    override func tearDown() {
        MockURLProtocol.reset()
        ClaudeUsageProvider.resetTokenCache()
        ClaudeUsageProvider.credentialsFileURLProvider = originalCredentialsFileURLProvider
        ClaudeUsageProvider.credentialsFileReader = originalCredentialsFileReader
        ClaudeUsageProvider.securityCLIRunner = originalSecurityCLIRunner
        super.tearDown()
    }

    private func makeDefaultsSuite() -> UserDefaults {
        let suiteName = "AgentBarTests.ClaudeUsageProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testFetchesUsageFromAPI() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour": {"utilization": 19.0, "resets_at": "2026-02-14T18:00:01.107582+00:00"},
            "seven_day": {"utilization": 50.0, "resets_at": "2026-02-16T09:00:00.107602+00:00"}
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.service, .claude)
        XCTAssertTrue(usage.isAvailable)
        XCTAssertEqual(usage.fiveHourUsage.unit, .percent)
        XCTAssertEqual(usage.fiveHourUsage.used, 19.0)
        XCTAssertEqual(usage.fiveHourUsage.total, 100)
        XCTAssertEqual(usage.weeklyUsage?.used, 50.0)
        XCTAssertEqual(usage.weeklyUsage?.total, 100)
    }

    func testParsesResetTimes() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour": {"utilization": 5.0, "resets_at": "2026-02-14T18:00:01.107582+00:00"},
            "seven_day": {"utilization": 10.0, "resets_at": "2026-02-16T09:00:00.107602+00:00"}
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertNotNil(usage.weeklyUsage?.resetTime)

        // Verify reset time is in the future relative to the test fixture date
        let expectedFiveHour = DateUtils.parseISO8601("2026-02-14T18:00:01.107582+00:00")!
        XCTAssertEqual(
            usage.fiveHourUsage.resetTime!.timeIntervalSince1970,
            expectedFiveHour.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testPercentageCalculation() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour": {"utilization": 85.0, "resets_at": null},
            "seven_day": {"utilization": 42.0, "resets_at": null}
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        // percentage = used / total = 85 / 100 = 0.85
        XCTAssertEqual(usage.fiveHourUsage.percentage, 0.85, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyUsage!.percentage, 0.42, accuracy: 0.001)
    }

    func testUsesModelSpecificWindowsWhenAggregateKeysMissing() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour_sonnet": {"utilization": 37.0, "resets_at": "2099-01-01T05:00:00Z"},
            "five_hour_opus": {"utilization": 22.0, "resets_at": "2099-01-01T04:30:00Z"},
            "seven_day_sonnet": {"utilization": 61.0, "resets_at": "2099-01-07T00:00:00Z"},
            "seven_day_opus": {"utilization": 55.0, "resets_at": "2099-01-06T00:00:00Z"}
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 37.0)
        XCTAssertEqual(usage.weeklyUsage?.used, 61.0)
        XCTAssertNotNil(usage.fiveHourUsage.resetTime)
        XCTAssertNotNil(usage.weeklyUsage?.resetTime)
    }

    func testHandlesNullWindows() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour": null,
            "seven_day": null
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.weeklyUsage?.used, 0)
        XCTAssertNil(usage.fiveHourUsage.resetTime)
    }

    func testUsesCachedValuesWhenWindowsTemporarilyMissing() async throws {
        let defaults = makeDefaultsSuite()
        let initial = """
        {
            "five_hour": {"utilization": 21.0, "resets_at": "2099-01-01T00:00:00Z"},
            "seven_day": {"utilization": 44.0, "resets_at": "2099-01-07T00:00:00Z"}
        }
        """
        MockURLProtocol.stubResponse(data: Data(initial.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let first = try await provider.fetchUsage()
        XCTAssertEqual(first.fiveHourUsage.used, 21.0)
        XCTAssertEqual(first.weeklyUsage?.used, 44.0)

        let missing = """
        {
            "five_hour": null,
            "seven_day": null
        }
        """
        MockURLProtocol.stubResponse(data: Data(missing.utf8), statusCode: 200)
        let second = try await provider.fetchUsage()

        XCTAssertEqual(second.fiveHourUsage.used, 21.0)
        XCTAssertEqual(second.weeklyUsage?.used, 44.0)
        XCTAssertNotNil(second.fiveHourUsage.resetTime)
        XCTAssertNotNil(second.weeklyUsage?.resetTime)
    }

    func testUsesCachedValuesWhenResponsePayloadIsUnexpected() async throws {
        let defaults = makeDefaultsSuite()
        defaults.set(26.0, forKey: "claudeUsageCache.fiveHour.used")
        defaults.set(100.0, forKey: "claudeUsageCache.fiveHour.total")
        defaults.set(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970, forKey: "claudeUsageCache.fiveHour.resetTime")
        defaults.set(58.0, forKey: "claudeUsageCache.sevenDay.used")
        defaults.set(100.0, forKey: "claudeUsageCache.sevenDay.total")
        defaults.set(Date(timeIntervalSinceNow: 6 * 24 * 3600).timeIntervalSince1970, forKey: "claudeUsageCache.sevenDay.resetTime")

        MockURLProtocol.stubResponse(data: Data("[]".utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.fiveHourUsage.used, 26.0)
        XCTAssertEqual(usage.weeklyUsage?.used, 58.0)
    }

    func testClearsExpiredCachedValuesWhenWindowsMissing() async throws {
        let defaults = makeDefaultsSuite()
        defaults.set(55.0, forKey: "claudeUsageCache.fiveHour.used")
        defaults.set(100.0, forKey: "claudeUsageCache.fiveHour.total")
        defaults.set(Date(timeIntervalSinceNow: -300).timeIntervalSince1970, forKey: "claudeUsageCache.fiveHour.resetTime")

        defaults.set(77.0, forKey: "claudeUsageCache.sevenDay.used")
        defaults.set(100.0, forKey: "claudeUsageCache.sevenDay.total")
        defaults.set(Date(timeIntervalSinceNow: -300).timeIntervalSince1970, forKey: "claudeUsageCache.sevenDay.resetTime")

        let missing = """
        {
            "five_hour": null,
            "seven_day": null
        }
        """
        MockURLProtocol.stubResponse(data: Data(missing.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.weeklyUsage?.used, 0)
    }

    func testPrefersNonExpiredCacheWhenAPIReturnsZeroWithoutReset() async throws {
        let defaults = makeDefaultsSuite()
        defaults.set(33.0, forKey: "claudeUsageCache.fiveHour.used")
        defaults.set(100.0, forKey: "claudeUsageCache.fiveHour.total")
        defaults.set(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970, forKey: "claudeUsageCache.fiveHour.resetTime")

        let json = """
        {
            "five_hour": {"utilization": 0.0, "resets_at": null},
            "seven_day": null
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.fiveHourUsage.used, 33.0)
    }

    func testClearsLegacyZeroCacheWithoutResetWhenWindowsMissing() async throws {
        let defaults = makeDefaultsSuite()
        defaults.set(0.0, forKey: "claudeUsageCache.fiveHour.used")
        defaults.set(100.0, forKey: "claudeUsageCache.fiveHour.total")
        defaults.removeObject(forKey: "claudeUsageCache.fiveHour.resetTime")

        let json = """
        {
            "five_hour": null,
            "seven_day": null
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        _ = try await provider.fetchUsage()
        XCTAssertNil(defaults.object(forKey: "claudeUsageCache.fiveHour.used"))
    }

    func testHandlesUnauthorized() async throws {
        let defaults = makeDefaultsSuite()
        MockURLProtocol.stubResponse(data: Data(), statusCode: 401)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "expired-token" },
            defaults: defaults
        )

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Should have thrown")
        } catch {
            // Expected — unauthorized with no cache
        }
    }

    func testFallsBackToCacheOnAPIFailureWhenSevenDayCacheValid() async throws {
        let defaults = makeDefaultsSuite()
        // 5h cache expired, 7d cache still valid (reset in 3 days)
        defaults.set(15.0, forKey: "claudeUsageCache.fiveHour.used")
        defaults.set(100.0, forKey: "claudeUsageCache.fiveHour.total")
        defaults.set(Date(timeIntervalSinceNow: -3600).timeIntervalSince1970,
                     forKey: "claudeUsageCache.fiveHour.resetTime")

        defaults.set(42.0, forKey: "claudeUsageCache.sevenDay.used")
        defaults.set(100.0, forKey: "claudeUsageCache.sevenDay.total")
        defaults.set(Date(timeIntervalSinceNow: 3 * 24 * 3600).timeIntervalSince1970,
                     forKey: "claudeUsageCache.sevenDay.resetTime")

        MockURLProtocol.stubResponse(data: Data(), statusCode: 401)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "expired-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        // 5h expired → 0%, 7d cached → 42%
        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.weeklyUsage?.used, 42.0)
        XCTAssertNotNil(usage.weeklyUsage?.resetTime)
    }

    func testFallsBackToCacheOnMissingCredentials() async throws {
        let defaults = makeDefaultsSuite()
        defaults.set(30.0, forKey: "claudeUsageCache.sevenDay.used")
        defaults.set(100.0, forKey: "claudeUsageCache.sevenDay.total")
        defaults.set(Date(timeIntervalSinceNow: 2 * 24 * 3600).timeIntervalSince1970,
                     forKey: "claudeUsageCache.sevenDay.resetTime")

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { nil },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        XCTAssertEqual(usage.fiveHourUsage.used, 0)
        XCTAssertEqual(usage.weeklyUsage?.used, 30.0)
    }

    func testHandlesMissingCredentials() async {
        let defaults = makeDefaultsSuite()
        let provider = ClaudeUsageProvider(
            credentialProvider: { nil },
            defaults: defaults
        )

        let isConfigured = await provider.isConfigured()
        XCTAssertFalse(isConfigured)
    }

    func testSendsCorrectHeaders() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {"five_hour": {"utilization": 0, "resets_at": null}, "seven_day": null}
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)
        MockURLProtocol.onRequest = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer my-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertEqual(request.url, ClaudeUsageProvider.usageURL)
        }

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "my-token" },
            defaults: defaults
        )

        _ = try await provider.fetchUsage()
    }

    // MARK: - security CLI token reading

    func testReadKeychainTokenViaCLICachesWithinTTL() {
        let credJSON = """
        {"claudeAiOauth":{"accessToken":"cached-token"}}
        """
        let counter = CLICounterBox()
        ClaudeUsageProvider.securityCLIRunner = { _ in
            counter.increment()
            return credJSON
        }

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ClaudeUsageProvider.readKeychainTokenViaCLI(now: now, cacheTTL: 60), "cached-token")
        XCTAssertEqual(ClaudeUsageProvider.readKeychainTokenViaCLI(now: now.addingTimeInterval(10), cacheTTL: 60), "cached-token")
        XCTAssertEqual(counter.value, 1, "Should only call CLI once within TTL")

        // After TTL expires, should call again
        XCTAssertEqual(ClaudeUsageProvider.readKeychainTokenViaCLI(now: now.addingTimeInterval(61), cacheTTL: 60), "cached-token")
        XCTAssertEqual(counter.value, 2)
    }

    func testReadKeychainTokenViaCLICachesNilOnFailure() {
        let counter = CLICounterBox()
        ClaudeUsageProvider.securityCLIRunner = { _ in
            counter.increment()
            return nil
        }

        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertNil(ClaudeUsageProvider.readKeychainTokenViaCLI(now: now, cacheTTL: 60))
        XCTAssertNil(ClaudeUsageProvider.readKeychainTokenViaCLI(now: now.addingTimeInterval(5), cacheTTL: 60))
        XCTAssertEqual(counter.value, 1)
    }

    func testReadAccessTokenPrefersCredentialsFile() {
        ClaudeUsageProvider.credentialsFileURLProvider = {
            URL(fileURLWithPath: "/tmp/test-claude-credentials.json")
        }
        ClaudeUsageProvider.credentialsFileReader = { _ in
            """
            {"claudeAiOauth":{"accessToken":"file-token"}}
            """
        }
        ClaudeUsageProvider.securityCLIRunner = { _ in
            XCTFail("Should not read keychain when file credentials are present")
            return nil
        }

        XCTAssertEqual(ClaudeUsageProvider.readAccessToken(), "file-token")
    }

    func testReadAccessTokenFallsBackToKeychainWhenFileMissing() {
        ClaudeUsageProvider.credentialsFileReader = { _ in nil }
        ClaudeUsageProvider.securityCLIRunner = { _ in
            """
            {"claudeAiOauth":{"accessToken":"keychain-token"}}
            """
        }

        XCTAssertEqual(ClaudeUsageProvider.readAccessToken(), "keychain-token")
    }

    func testReadAccessTokenFallsBackToKeychainWhenFileIsMalformed() {
        ClaudeUsageProvider.credentialsFileReader = { _ in "not json" }
        ClaudeUsageProvider.securityCLIRunner = { _ in
            """
            {"claudeAiOauth":{"accessToken":"keychain-token"}}
            """
        }

        XCTAssertEqual(ClaudeUsageProvider.readAccessToken(), "keychain-token")
    }

    func testDefaultCredentialProviderUsesFileCredentials() async {
        let defaults = makeDefaultsSuite()
        ClaudeUsageProvider.credentialsFileReader = { _ in
            """
            {"claudeAiOauth":{"accessToken":"file-token"}}
            """
        }
        ClaudeUsageProvider.securityCLIRunner = { _ in nil }

        let provider = ClaudeUsageProvider(defaults: defaults)

        let isConfigured = await provider.isConfigured()
        XCTAssertTrue(isConfigured)
    }

    func testExecuteSecurityCLICommandTimeoutForceKillsIfStillRunning() {
        var terminateCallCount = 0
        var forceTerminateCallCount = 0
        var waitTimeouts: [TimeInterval] = []
        let runtime = ClaudeUsageProvider.SecurityCLIProcessRuntime(
            run: {},
            waitForTermination: { timeout in
                waitTimeouts.append(timeout)
                return .timedOut
            },
            isRunning: { true },
            terminate: { terminateCallCount += 1 },
            forceTerminate: { forceTerminateCallCount += 1 },
            terminationStatus: { 0 },
            readOutput: { Data() }
        )

        let result = ClaudeUsageProvider.executeSecurityCLICommand(timeout: 0.05, runtime: runtime)

        XCTAssertNil(result)
        XCTAssertEqual(terminateCallCount, 1)
        XCTAssertEqual(forceTerminateCallCount, 1)
        XCTAssertEqual(waitTimeouts.count, 3)
        XCTAssertEqual(waitTimeouts[0], 0.05, accuracy: 0.0001)
        XCTAssertEqual(waitTimeouts[1], 0.25, accuracy: 0.0001)
        XCTAssertEqual(waitTimeouts[2], 0.25, accuracy: 0.0001)
    }

    func testExecuteSecurityCLICommandTimeoutDoesNotForceKillWhenTerminateStopsProcess() {
        var terminateCallCount = 0
        var forceTerminateCallCount = 0
        var waitTimeouts: [TimeInterval] = []
        var isRunningCheckCount = 0
        let runtime = ClaudeUsageProvider.SecurityCLIProcessRuntime(
            run: {},
            waitForTermination: { timeout in
                waitTimeouts.append(timeout)
                return .timedOut
            },
            isRunning: {
                defer { isRunningCheckCount += 1 }
                return isRunningCheckCount == 0
            },
            terminate: { terminateCallCount += 1 },
            forceTerminate: { forceTerminateCallCount += 1 },
            terminationStatus: { 0 },
            readOutput: { Data() }
        )

        let result = ClaudeUsageProvider.executeSecurityCLICommand(timeout: 0.05, runtime: runtime)

        XCTAssertNil(result)
        XCTAssertEqual(terminateCallCount, 1)
        XCTAssertEqual(forceTerminateCallCount, 0)
        XCTAssertEqual(waitTimeouts.count, 2)
        XCTAssertEqual(waitTimeouts[0], 0.05, accuracy: 0.0001)
        XCTAssertEqual(waitTimeouts[1], 0.25, accuracy: 0.0001)
    }

    func testExecuteSecurityCLICommandReturnsNilForNonZeroExitStatus() {
        let runtime = ClaudeUsageProvider.SecurityCLIProcessRuntime(
            run: {},
            waitForTermination: { _ in .success },
            isRunning: { false },
            terminate: {},
            terminationStatus: { 1 },
            readOutput: { Data("token".utf8) }
        )

        let result = ClaudeUsageProvider.executeSecurityCLICommand(timeout: 0.05, runtime: runtime)

        XCTAssertNil(result)
    }

    func testExecuteSecurityCLICommandReturnsNilForEmptyOutput() {
        let runtime = ClaudeUsageProvider.SecurityCLIProcessRuntime(
            run: {},
            waitForTermination: { _ in .success },
            isRunning: { false },
            terminate: {},
            terminationStatus: { 0 },
            readOutput: { Data("   \n\t".utf8) }
        )

        let result = ClaudeUsageProvider.executeSecurityCLICommand(timeout: 0.05, runtime: runtime)

        XCTAssertNil(result)
    }

    func testParseAccessTokenFromValidJSON() {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oauth-test-123"}}
        """
        XCTAssertEqual(ClaudeUsageProvider.parseAccessToken(from: json), "sk-ant-oauth-test-123")
    }

    func testParseAccessTokenFromInvalidJSON() {
        XCTAssertNil(ClaudeUsageProvider.parseAccessToken(from: "not json"))
        XCTAssertNil(ClaudeUsageProvider.parseAccessToken(from: "{}"))
        XCTAssertNil(ClaudeUsageProvider.parseAccessToken(from: "{\"other\":\"field\"}"))
    }

    func testIgnoresExtraFields() async throws {
        let defaults = makeDefaultsSuite()
        let json = """
        {
            "five_hour": {"utilization": 19.0, "resets_at": "2026-02-14T18:00:01+00:00"},
            "seven_day": {"utilization": 50.0, "resets_at": "2026-02-16T09:00:00+00:00"},
            "seven_day_opus": null,
            "seven_day_sonnet": {"utilization": 3.0, "resets_at": "2026-02-17T00:00:00+00:00"},
            "iguana_necktie": null,
            "extra_usage": {"is_enabled": true, "monthly_limit": 5000}
        }
        """
        MockURLProtocol.stubResponse(data: Data(json.utf8), statusCode: 200)

        let provider = ClaudeUsageProvider(
            session: MockURLProtocol.session(),
            credentialProvider: { "test-token" },
            defaults: defaults
        )

        let usage = try await provider.fetchUsage()

        // Should decode successfully ignoring unknown keys
        XCTAssertEqual(usage.fiveHourUsage.used, 19.0)
        XCTAssertEqual(usage.weeklyUsage?.used, 50.0)
    }
}

// MARK: - Mock URL Protocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stubData: Data = Data()
    nonisolated(unsafe) static var stubStatusCode: Int = 200
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?

    static func reset() {
        stubData = Data()
        stubStatusCode = 200
        onRequest = nil
    }

    static func stubResponse(data: Data, statusCode: Int) {
        stubData = data
        stubStatusCode = statusCode
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.onRequest?(request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: MockURLProtocol.stubStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockURLProtocol.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CLICounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
