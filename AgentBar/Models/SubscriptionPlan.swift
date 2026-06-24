import Foundation

enum CodexPlan: String, CaseIterable, Codable, Sendable {
    case plus = "Plus"
    case pro = "Pro"
    case custom = "Custom"

    var fiveHourTokenLimit: Double {
        switch self {
        case .plus: return 1_000_000
        case .pro: return 10_000_000
        case .custom: return 0
        }
    }

    var weeklyTokenLimit: Double {
        switch self {
        case .plus: return 10_000_000
        case .pro: return 100_000_000
        case .custom: return 0
        }
    }
}

enum ClaudePlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case max5x = "Max 5x"
    case max20x = "Max 20x"
    case team = "Team"
}

enum CopilotPlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case proPlus = "Pro+"
    case business = "Business"
    case enterprise = "Enterprise"
    case custom = "Custom"
}

enum CursorPlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case proPlus = "Pro+"
    case ultra = "Ultra"
    case teams = "Teams"
    case custom = "Custom"

    /// Approximate monthly included-usage allotment, in US dollars.
    ///
    /// Since June 2025 Cursor bills on credit/usage-based pricing rather than a
    /// premium-request count, so usage is tracked as the dollar value of model
    /// usage consumed. These figures estimate each plan's included allotment
    /// (Ultra includes ~20x Pro); users on `.custom` can override the limit in
    /// Settings.
    var monthlyUsageLimitUSD: Double {
        switch self {
        case .free: return 0
        case .pro: return 20
        case .proPlus: return 60
        case .ultra: return 400
        case .teams: return 40
        case .custom: return 0
        }
    }

    static func migrateLegacyRawValue(_ rawValue: String) -> String {
        switch rawValue {
        case "Business":
            return CursorPlan.teams.rawValue
        default:
            return rawValue
        }
    }

    static func resolveAndMigrateStoredPlan(in defaults: UserDefaults = .standard) -> CursorPlan {
        let storedRawValue = defaults.string(forKey: "cursorPlan") ?? CursorPlan.pro.rawValue
        let migratedRawValue = migrateLegacyRawValue(storedRawValue)

        if migratedRawValue != storedRawValue {
            defaults.set(migratedRawValue, forKey: "cursorPlan")
        }

        if let resolvedPlan = CursorPlan(rawValue: migratedRawValue) {
            return resolvedPlan
        }

        defaults.set(CursorPlan.pro.rawValue, forKey: "cursorPlan")
        return .pro
    }
}
