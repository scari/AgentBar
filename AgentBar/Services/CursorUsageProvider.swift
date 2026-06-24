import Foundation
import SQLite3

// MARK: - API Response Models

/// Legacy `/api/usage` response.
///
/// Cursor froze the per-model request counters (`numRequests`, `numTokens`, …) at 0
/// when it moved to credit/usage-based pricing in June 2025, so we only read
/// `startOfMonth` from this endpoint to anchor the billing period. Real usage comes
/// from `dashboard/get-aggregated-usage-events`.
struct CursorUsageResponse: Decodable, Sendable {
    let startOfMonth: String?
}

/// `dashboard/get-aggregated-usage-events` response — the authoritative usage source
/// under Cursor's credit-based pricing. `totalCostCents / 100` is the dollar spend the
/// Cursor dashboard shows for the queried window.
struct CursorAggregatedUsageResponse: Decodable, Sendable {
    struct Aggregation: Decodable, Sendable {
        let totalCents: Double?
    }

    let totalCostCents: Double?
    let aggregations: [Aggregation]?

    /// Spend in cents for the window. Prefers the server-provided total and falls
    /// back to summing the per-model aggregations if it is absent.
    var resolvedCents: Double {
        if let totalCostCents { return totalCostCents }
        return (aggregations ?? []).compactMap(\.totalCents).reduce(0, +)
    }
}

// MARK: - Provider

final class CursorUsageProvider: UsageProviderProtocol, @unchecked Sendable {
    let serviceType: ServiceType = .cursor

    private let session: URLSession
    private let monthlyUsageLimitUSD: Double
    private let dbPathProvider: @Sendable () -> String
    private let defaults: UserDefaults

    /// Legacy endpoint, kept only for the `startOfMonth` billing anchor.
    static let apiBaseURL = "https://www.cursor.com/api/usage"
    /// Current usage endpoint (credit-based pricing).
    static let aggregatedUsageURL = "https://cursor.com/api/dashboard/get-aggregated-usage-events"
    /// Required `Origin` for the dashboard endpoint; without it the API responds 403
    /// "Invalid origin for state-changing request".
    static let dashboardOrigin = "https://cursor.com"

    private static let cacheKey = "cursorUsageCache.monthly"

    static let defaultDBPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()

    init(
        monthlyUsageLimitUSD: Double = CursorPlan.pro.monthlyUsageLimitUSD,
        session: URLSession = .shared,
        dbPathProvider: (@Sendable () -> String)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.monthlyUsageLimitUSD = monthlyUsageLimitUSD
        self.session = session
        self.dbPathProvider = dbPathProvider ?? { Self.defaultDBPath }
        self.defaults = defaults
    }

    func isConfigured() async -> Bool {
        FileManager.default.fileExists(atPath: dbPathProvider())
    }

    func fetchUsage() async throws -> UsageData {
        do {
            return try await fetchUsageFromAPI()
        } catch {
            return try cachedOrThrow(error)
        }
    }

    private func fetchUsageFromAPI() async throws -> UsageData {
        let dbPath = dbPathProvider()

        // 1. Read JWT from SQLite and derive the user id.
        let jwt = try readAccessToken(from: dbPath)
        let userId = try Self.decodeUserIdFromJWT(jwt)
        let cookie = Self.sessionCookie(userId: userId, jwt: jwt)

        // 2. Anchor the billing period via the legacy endpoint. Its request counters are
        //    always 0 under credit-based pricing, so only `startOfMonth` is used.
        let legacy = try await fetchLegacyUsage(userId: userId, cookie: cookie)
        let periodStart = legacy.startOfMonth.flatMap(DateUtils.parseISO8601)
            ?? Self.startOfCurrentMonthUTC()
        let resetTime = legacy.startOfMonth.flatMap(Self.parseStartOfMonthReset)
            ?? CopilotUsageProvider.firstOfNextMonthUTC()

        // 3. Real usage: dollars spent this period from aggregated usage events.
        let spentCents = try await fetchAggregatedSpendCents(cookie: cookie, since: periodStart)

        let metric = UsageMetric(
            used: spentCents / 100.0,
            total: monthlyUsageLimitUSD,
            unit: .dollars,
            resetTime: resetTime
        )
        saveMetricCache(metric, forKey: Self.cacheKey)

        return UsageData(
            service: .cursor,
            fiveHourUsage: metric,
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true,
            planName: resolvedPlanName()
        )
    }

    // MARK: - API Calls

    private func fetchLegacyUsage(userId: String, cookie: String) async throws -> CursorUsageResponse {
        var components = URLComponents(string: Self.apiBaseURL)
        components?.queryItems = [URLQueryItem(name: "user", value: userId)]
        guard let url = components?.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }

    private func fetchAggregatedSpendCents(cookie: String, since periodStart: Date) async throws -> Double {
        guard let url = URL(string: Self.aggregatedUsageURL) else {
            throw APIError.invalidResponse
        }

        let body: [String: Any] = [
            "teamId": -1,
            "startDate": String(Int(periodStart.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(Date().timeIntervalSince1970 * 1000))
        ]

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The dashboard API rejects requests without a matching Origin (CSRF guard).
        request.setValue(Self.dashboardOrigin, forHTTPHeaderField: "Origin")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(CursorAggregatedUsageResponse.self, from: data).resolvedCents
    }

    private static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    private func resolvedPlanName() -> String {
        (defaults.string(forKey: "cursorPlan")
            .flatMap { CursorPlan(rawValue: $0) } ?? .pro).rawValue
    }

    // MARK: - Usage Caching

    private func cachedOrThrow(_ error: Error) throws -> UsageData {
        let now = Date()
        guard let cached = validCachedMetric(forKey: Self.cacheKey, now: now) else {
            throw error
        }
        return UsageData(
            service: .cursor,
            fiveHourUsage: cached,
            weeklyUsage: nil,
            lastUpdated: now,
            isAvailable: true,
            planName: resolvedPlanName()
        )
    }

    private func validCachedMetric(forKey key: String, now: Date) -> UsageMetric? {
        guard defaults.object(forKey: "\(key).used") != nil else { return nil }
        let used = defaults.double(forKey: "\(key).used")
        let total = defaults.object(forKey: "\(key).total") != nil
            ? defaults.double(forKey: "\(key).total") : monthlyUsageLimitUSD
        let resetTimestamp = defaults.object(forKey: "\(key).resetTime") as? Double
        let resetTime = resetTimestamp.map { Date(timeIntervalSince1970: $0) }

        if let resetTime, resetTime <= now {
            clearMetricCache(forKey: key)
            return nil
        }
        if used <= 0, resetTime == nil {
            clearMetricCache(forKey: key)
            return nil
        }
        return UsageMetric(used: used, total: total, unit: .dollars, resetTime: resetTime)
    }

    private func saveMetricCache(_ metric: UsageMetric, forKey key: String) {
        defaults.set(metric.used, forKey: "\(key).used")
        defaults.set(metric.total, forKey: "\(key).total")
        defaults.set(metric.resetTime?.timeIntervalSince1970, forKey: "\(key).resetTime")
    }

    private func clearMetricCache(forKey key: String) {
        defaults.removeObject(forKey: "\(key).used")
        defaults.removeObject(forKey: "\(key).total")
        defaults.removeObject(forKey: "\(key).resetTime")
    }

    // MARK: - SQLite Token Reading

    func readAccessToken(from dbPath: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw APIError.noData
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw APIError.noData
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw APIError.noData
        }

        guard let cString = sqlite3_column_text(stmt, 0) else {
            throw APIError.noData
        }

        return String(cString: cString)
    }

    // MARK: - JWT Decoding

    static func decodeUserIdFromJWT(_ jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw APIError.decodingError("Invalid JWT format")
        }

        let payload = String(parts[1])
        guard let data = base64URLDecode(payload) else {
            throw APIError.decodingError("Failed to decode JWT payload")
        }

        struct JWTPayload: Decodable {
            let sub: String
        }

        let decoded = try JSONDecoder().decode(JWTPayload.self, from: data)
        return decoded.sub
    }

    // MARK: - Helpers

    /// Builds the `WorkosCursorSessionToken` value: `<userId>::<jwt>`, percent-encoded.
    static func sessionCookie(userId: String, jwt: String) -> String {
        let encodedUserId = percentEncodeCookieComponent(userId)
        let encodedJWT = percentEncodeCookieComponent(jwt)
        return "\(encodedUserId)%3A%3A\(encodedJWT)"
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    static func percentEncodeCookieComponent(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func parseStartOfMonthReset(_ startOfMonth: String) -> Date? {
        guard let startDate = DateUtils.parseISO8601(startOfMonth) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: 1, to: startDate)
    }

    /// Fallback billing-period start when the API omits `startOfMonth`.
    static func startOfCurrentMonthUTC() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: components) ?? Date()
    }
}
