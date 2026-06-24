import Foundation
import Combine

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usageData: [UsageData] = []
    @Published var lastError: String?
    @Published var isLoading: Bool = false

    private static let serviceOrder: [ServiceType] = [
        .claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai
    ]

    private var providers: [any UsageProviderProtocol]
    private let historyStore: UsageHistoryStoreProtocol
    private let refreshInterval: TimeInterval
    private var timerCancellable: AnyCancellable?
    private var limitsCancellable: AnyCancellable?
    init(
        providers: [any UsageProviderProtocol]? = nil,
        refreshInterval: TimeInterval = 60,
        historyStore: UsageHistoryStoreProtocol = UsageHistoryStore()
    ) {
        self.refreshInterval = refreshInterval
        self.providers = providers ?? Self.buildProviders()
        self.historyStore = historyStore

        if providers == nil {
            limitsCancellable = NotificationCenter.default
                .publisher(for: .limitsChanged)
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.rebuildProviders()
                }
        }
    }

    func startMonitoring() {
        // Initial fetch
        Task { await fetchAllUsage() }

        // Periodic refresh
        timerCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.fetchAllUsage()
                }
            }
    }

    func stopMonitoring() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    func rebuildProviders() {
        providers = Self.buildProviders()
        Task { await fetchAllUsage() }
    }

    func fetchAllUsage() async {
        isLoading = true
        defer { isLoading = false }

        var results: [UsageData] = []
        var successfulResults: [UsageData] = []

        await withTaskGroup(of: ProviderFetchOutcome?.self) { group in
            for provider in providers {
                group.addTask {
                    guard await provider.isConfigured() else { return nil }
                    do {
                        let usage = try await provider.fetchUsage()
                        return ProviderFetchOutcome(data: usage, shouldRecordHistory: true)
                    } catch {
                        // Return zero usage so the bar stays visible
                        return ProviderFetchOutcome(
                            data: Self.zeroUsageData(for: provider.serviceType),
                            shouldRecordHistory: false
                        )
                    }
                }
            }

            for await result in group {
                if let result {
                    results.append(result.data)
                    if result.shouldRecordHistory {
                        successfulResults.append(result.data)
                    }
                }
            }
        }

        results.sort { a, b in
            Self.sortIndex(for: a.service) < Self.sortIndex(for: b.service)
        }

        usageData = results
        lastError = results.isEmpty ? "No data available" : nil

        guard !successfulResults.isEmpty else { return }
        await historyStore.record(samples: successfulResults, recordedAt: Date())
        NotificationCenter.default.post(name: .usageHistoryChanged, object: nil)
    }

    private static func sortIndex(for service: ServiceType) -> Int {
        serviceOrder.firstIndex(of: service) ?? Int.max
    }

    nonisolated private static func zeroUsageData(for service: ServiceType) -> UsageData {
        UsageData(
            service: service,
            fiveHourUsage: UsageMetric(used: 0, total: 100, unit: .percent, resetTime: nil),
            weeklyUsage: nil,
            lastUpdated: Date(),
            isAvailable: true,
            planName: storedPlanName(for: service)
        )
    }

    nonisolated private static func storedPlanName(for service: ServiceType) -> String? {
        let defaults = UserDefaults.standard
        switch service {
        case .claude:
            return defaults.string(forKey: "claudePlan")
        case .codex:
            return defaults.string(forKey: "codexPlan")
        case .cursor:
            return defaults.string(forKey: "cursorPlan")
        default:
            return nil
        }
    }

    // MARK: - Provider Factory

    private static func buildProviders() -> [any UsageProviderProtocol] {
        let defaults = UserDefaults.standard
        var providers: [any UsageProviderProtocol] = []

        if isEnabled("claudeEnabled", in: defaults) {
            providers.append(ClaudeUsageProvider())
        }

        if isEnabled("codexEnabled", in: defaults) {
            let codexLimits = codexTokenLimits(in: defaults)
            providers.append(CodexUsageProvider(
                fiveHourTokenLimit: codexLimits.fiveHour,
                weeklyTokenLimit: codexLimits.weekly
            ))
        }

        if isEnabled("geminiEnabled", in: defaults) {
            providers.append(GeminiUsageProvider(
                dailyRequestLimit: geminiDailyLimit(in: defaults)
            ))
        }

        if isEnabled("copilotEnabled", in: defaults) {
            providers.append(CopilotUsageProvider())
        }

        if isEnabled("cursorEnabled", in: defaults) {
            providers.append(CursorUsageProvider(
                monthlyUsageLimitUSD: cursorUsageLimitUSD(in: defaults)
            ))
        }

        if isEnabled("zaiEnabled", in: defaults) {
            providers.append(ZaiUsageProvider())
        }

        return providers
    }

    private static func isEnabled(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key, defaultValue: true)
    }

    private static func codexTokenLimits(in defaults: UserDefaults) -> (fiveHour: Double, weekly: Double) {
        let planRaw = defaults.string(forKey: "codexPlan") ?? CodexPlan.pro.rawValue
        let plan = CodexPlan(rawValue: planRaw) ?? .pro

        if plan == .custom {
            return (
                defaults.double(forKey: "codexFiveHourLimit").nonZero ?? CodexPlan.pro.fiveHourTokenLimit,
                defaults.double(forKey: "codexWeeklyLimit").nonZero ?? CodexPlan.pro.weeklyTokenLimit
            )
        }

        return (plan.fiveHourTokenLimit, plan.weeklyTokenLimit)
    }

    private static func geminiDailyLimit(in defaults: UserDefaults) -> Double {
        defaults.double(forKey: "geminiDailyLimit").nonZero ?? 1_000
    }

    private static func cursorUsageLimitUSD(in defaults: UserDefaults) -> Double {
        let plan = CursorPlan.resolveAndMigrateStoredPlan(in: defaults)
        if plan == .custom {
            return defaults.double(forKey: "cursorMonthlyLimit").nonZero ?? CursorPlan.pro.monthlyUsageLimitUSD
        }
        return plan.monthlyUsageLimitUSD
    }
}

private struct ProviderFetchOutcome: Sendable {
    let data: UsageData
    let shouldRecordHistory: Bool
}

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
