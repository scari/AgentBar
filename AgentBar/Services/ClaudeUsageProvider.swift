import Foundation

// MARK: - API Response Models

struct ClaudeOAuthCredentials: Decodable, Sendable {
    let claudeAiOauth: ClaudeOAuthToken
}

struct ClaudeOAuthToken: Decodable, Sendable {
    let accessToken: String
}

struct ClaudeUsageResponse: Decodable, Sendable {
    private let windows: [String: ClaudeUsageWindow]

    init(windows: [String: ClaudeUsageWindow] = [:]) {
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var parsed: [String: ClaudeUsageWindow] = [:]

        for key in container.allKeys {
            if let window = try? container.decode(ClaudeUsageWindow.self, forKey: key) {
                parsed[key.stringValue] = window
            }
        }
        self.windows = parsed
    }

    func mergedWindow(for baseKey: String) -> ClaudeUsageWindow? {
        if let exact = windows[baseKey] {
            return exact
        }

        let prefix = "\(baseKey)_"
        let candidates = windows
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)
        guard !candidates.isEmpty else { return nil }

        let utilization = candidates.map(\.utilization).max() ?? 0
        let resetTime = candidates
            .compactMap { window -> (Date, String)? in
                guard let resetRaw = window.resets_at,
                      let resetDate = DateUtils.parseISO8601(resetRaw) else {
                    return nil
                }
                return (resetDate, resetRaw)
            }
            .sorted { $0.0 < $1.0 }
            .first?
            .1

        return ClaudeUsageWindow(utilization: utilization, resets_at: resetTime)
    }
}

struct ClaudeUsageWindow: Decodable, Sendable {
    let utilization: Double
    let resets_at: String?
}

// MARK: - Provider

final class ClaudeUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .claude

    private let session: URLSession
    private let credentialProvider: @Sendable () -> String?
    private let defaults: UserDefaults

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let credentialsFileRelativePath = ".claude/.credentials.json"
    private static let keychainService = "Claude Code-credentials"
    private static let tokenCacheLock = NSLock()
    private static let defaultCacheTTL: TimeInterval = 60
    private static let securityCLITimeout: TimeInterval = 2
    nonisolated(unsafe) private static var cachedToken: String?
    nonisolated(unsafe) private static var tokenLastLookupAt: Date?
    typealias SecurityCLIProcessRuntime = CLIProcessRuntime
    nonisolated(unsafe) static var credentialsFileURLProvider: @Sendable () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(credentialsFileRelativePath)
    }
    nonisolated(unsafe) static var credentialsFileReader: @Sendable (_ url: URL) -> String? = { url in
        try? String(contentsOf: url, encoding: .utf8)
    }
    nonisolated(unsafe) static var securityCLIRunner: @Sendable (_ timeout: TimeInterval) -> String? = { timeout in
        runSecurityCLICommand(timeout: timeout)
    }

    init(
        session: URLSession = .shared,
        credentialProvider: (@Sendable () -> String?)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.credentialProvider = credentialProvider ?? { Self.readAccessToken() }
        self.defaults = defaults
    }

    func isConfigured() async -> Bool {
        credentialProvider() != nil
    }

    func fetchUsage() async throws -> UsageData {
        guard let token = credentialProvider() else {
            return try cachedOrThrow(APIError.unauthorized)
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let usageResponse: ClaudeUsageResponse
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return try cachedOrThrow(APIError.invalidResponse)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let error: APIError = httpResponse.statusCode == 401
                    ? .unauthorized : .httpError(httpResponse.statusCode)
                return try cachedOrThrow(error)
            }

            usageResponse = (try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
                ?? ClaudeUsageResponse()
        } catch {
            return try cachedOrThrow(error)
        }

        let fiveHour = resolveMetric(
            window: usageResponse.mergedWindow(for: "five_hour"),
            cacheKey: "claudeUsageCache.fiveHour"
        )
        let sevenDay = resolveMetric(
            window: usageResponse.mergedWindow(for: "seven_day"),
            cacheKey: "claudeUsageCache.sevenDay"
        )

        let planName = (defaults.string(forKey: "claudePlan")
            .flatMap { ClaudePlan(rawValue: $0) } ?? .pro).rawValue

        return UsageData(
            service: .claude,
            fiveHourUsage: fiveHour,
            weeklyUsage: sevenDay,
            lastUpdated: Date(),
            isAvailable: true,
            planName: planName
        )
    }

    /// Returns cached usage data when available, otherwise re-throws the original error.
    /// This preserves valid 7d values when the API fails (e.g. token expiry overnight)
    /// but the 7d reset window hasn't passed yet.
    private func cachedOrThrow(_ error: Error) throws -> UsageData {
        let now = Date()
        let fiveHour = validCachedMetric(forKey: "claudeUsageCache.fiveHour", now: now)
        let sevenDay = validCachedMetric(forKey: "claudeUsageCache.sevenDay", now: now)

        guard fiveHour != nil || sevenDay != nil else { throw error }

        let zeroPercent = UsageMetric(used: 0, total: 100, unit: .percent, resetTime: nil)
        let planName = (defaults.string(forKey: "claudePlan")
            .flatMap { ClaudePlan(rawValue: $0) } ?? .pro).rawValue

        return UsageData(
            service: .claude,
            fiveHourUsage: fiveHour ?? zeroPercent,
            weeklyUsage: sevenDay ?? zeroPercent,
            lastUpdated: Date(),
            isAvailable: true,
            planName: planName
        )
    }

    private func resolveMetric(window: ClaudeUsageWindow?, cacheKey: String) -> UsageMetric {
        let now = Date()
        let cached = validCachedMetric(forKey: cacheKey, now: now)

        guard let window else {
            return cached ?? UsageMetric(used: 0, total: 100, unit: .percent, resetTime: nil)
        }

        let incoming = UsageMetric(
            used: window.utilization,
            total: 100,
            unit: .percent,
            resetTime: window.resets_at.flatMap { DateUtils.parseISO8601($0) }
        )

        if shouldPreferCachedMetric(cached, over: incoming, now: now) {
            return cached!
        }

        saveMetricCache(incoming, forKey: cacheKey)
        return incoming
    }

    private func validCachedMetric(forKey key: String, now: Date) -> UsageMetric? {
        guard let cached = loadMetricCache(forKey: key) else { return nil }

        if let reset = cached.resetTime, reset <= now {
            clearMetricCache(forKey: key)
            return nil
        }

        // Legacy or meaningless cache entry from older builds.
        if cached.used <= 0, cached.resetTime == nil {
            clearMetricCache(forKey: key)
            return nil
        }

        return cached
    }

    private func shouldPreferCachedMetric(
        _ cached: UsageMetric?,
        over incoming: UsageMetric,
        now: Date
    ) -> Bool {
        guard let cached else { return false }
        guard cached.used > 0 else { return false }
        guard let cachedReset = cached.resetTime, cachedReset > now else { return false }
        guard incoming.used <= 0 else { return false }

        // Idle sessions can return empty windows; keep cached usage until known reset.
        if incoming.resetTime == nil {
            return true
        }

        // If reset boundary didn't actually advance, sudden zero is likely a transient API gap.
        if let incomingReset = incoming.resetTime,
           abs(incomingReset.timeIntervalSince(cachedReset)) < 1 {
            return true
        }

        return false
    }

    private func saveMetricCache(_ metric: UsageMetric, forKey key: String) {
        defaults.set(metric.used, forKey: "\(key).used")
        defaults.set(metric.total, forKey: "\(key).total")
        defaults.set(metric.resetTime?.timeIntervalSince1970, forKey: "\(key).resetTime")
    }

    private func loadMetricCache(forKey key: String) -> UsageMetric? {
        guard defaults.object(forKey: "\(key).used") != nil else { return nil }
        let used = defaults.double(forKey: "\(key).used")
        let total = defaults.object(forKey: "\(key).total") != nil ? defaults.double(forKey: "\(key).total") : 100
        let resetTimestamp = defaults.object(forKey: "\(key).resetTime") as? Double
        let resetTime = resetTimestamp.map { Date(timeIntervalSince1970: $0) }
        return UsageMetric(used: used, total: total, unit: .percent, resetTime: resetTime)
    }

    private func clearMetricCache(forKey key: String) {
        defaults.removeObject(forKey: "\(key).used")
        defaults.removeObject(forKey: "\(key).total")
        defaults.removeObject(forKey: "\(key).resetTime")
    }

    // MARK: - Keychain Access via security CLI

    static func readAccessToken() -> String? {
        readTokenFromCredentialsFile() ?? readKeychainTokenViaCLI()
    }

    static func readTokenFromCredentialsFile() -> String? {
        let url = credentialsFileURLProvider()
        guard let rawJSON = credentialsFileReader(url) else { return nil }
        return parseAccessToken(from: rawJSON)
    }

    /// Reads the Claude Code OAuth token using the `security` CLI to avoid
    /// per-app Keychain ACL prompts. The result is cached with a TTL matching
    /// the app's refresh interval.
    static func readKeychainTokenViaCLI(now: Date = Date(), cacheTTL: TimeInterval? = nil) -> String? {
        let effectiveTTL = max(0, cacheTTL ?? cacheTTLFromRefreshInterval())
        tokenCacheLock.lock()
        defer { tokenCacheLock.unlock() }

        if let lastLookup = tokenLastLookupAt,
           now.timeIntervalSince(lastLookup) < effectiveTTL {
            return cachedToken
        }

        let rawJSON = securityCLIRunner(securityCLITimeout)
        let token = rawJSON.flatMap { parseAccessToken(from: $0) }
        cachedToken = token
        tokenLastLookupAt = now
        return token
    }

    static func resetTokenCache() {
        tokenCacheLock.lock()
        cachedToken = nil
        tokenLastLookupAt = nil
        tokenCacheLock.unlock()
    }

    /// Parses the OAuth access token from the raw JSON credential blob.
    static func parseAccessToken(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let creds = try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data) else {
            return nil
        }
        return creds.claudeAiOauth.accessToken
    }

    private static func cacheTTLFromRefreshInterval() -> TimeInterval {
        let refreshInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        return refreshInterval > 0 ? refreshInterval : defaultCacheTTL
    }

    /// Runs `security find-generic-password -s "Claude Code-credentials" -w`
    /// which outputs the password data to stdout. The `security` binary is a
    /// system-trusted application so it bypasses per-app ACL prompts.
    private static func runSecurityCLICommand(timeout: TimeInterval) -> String? {
        CLIProcessExecutor.executeCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: timeout
        )
    }

    static func executeSecurityCLICommand(timeout: TimeInterval, runtime: SecurityCLIProcessRuntime) -> String? {
        CLIProcessExecutor.executeCommand(timeout: timeout, runtime: runtime)
    }
}
