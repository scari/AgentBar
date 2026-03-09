import Foundation
import CoreGraphics

enum StatusBarDisplayPlanner {
    static let maximumVisibleRowCount = 3
    static let compactVisibleRowCount = 2
    static let standardRowSpacing: CGFloat = 1
    static let viewportHeight: CGFloat = 20

    static let topPriorityHoldSeconds: TimeInterval = 8
    static let scrollStepHoldSeconds: TimeInterval = 3
    static let scrollTransitionSeconds: TimeInterval = 1.2

    private static let serviceOrder: [ServiceType] = [.claude, .codex, .gemini, .copilot, .cursor, .opencode, .zai]

    static func rankedServices(from services: [UsageData]) -> [UsageData] {
        services
            .filter(\.isAvailable)
            .sorted { lhs, rhs in
                let lhsScore = usageScore(lhs)
                let rhsScore = usageScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                let lhsRank = serviceOrder.firstIndex(of: lhs.service) ?? serviceOrder.count
                let rhsRank = serviceOrder.firstIndex(of: rhs.service) ?? serviceOrder.count
                return lhsRank < rhsRank
            }
    }

    static func maxScrollIndex(for rankedServices: [UsageData]) -> Int {
        max(0, rankedServices.count - visibleRowCount(forServiceCount: rankedServices.count))
    }

    static func visibleRowCount(forServiceCount serviceCount: Int) -> Int {
        guard serviceCount > 0 else { return maximumVisibleRowCount }
        return serviceCount <= compactVisibleRowCount
            ? compactVisibleRowCount
            : maximumVisibleRowCount
    }

    static func rowHeight(forServiceCount serviceCount: Int) -> CGFloat {
        if usesCompactLayout(forServiceCount: serviceCount) {
            return compactRowHeight
        }

        let rowCount = CGFloat(visibleRowCount(forServiceCount: serviceCount))
        let totalSpacing = standardRowSpacing * max(0, rowCount - 1)
        return (viewportHeight - totalSpacing) / rowCount
    }

    static func rowSpacing(forServiceCount serviceCount: Int) -> CGFloat {
        switch serviceCount {
        case 2:
            return (viewportHeight - (rowHeight(forServiceCount: serviceCount) * 2)) / 3
        case 1:
            return 0
        default:
            return standardRowSpacing
        }
    }

    static func centersRowsVertically(forServiceCount serviceCount: Int) -> Bool {
        usesCompactLayout(forServiceCount: serviceCount)
    }

    private static func usageScore(_ data: UsageData) -> Double {
        let weekly = data.weeklyUsage?.percentage ?? 0
        return max(data.fiveHourUsage.percentage, weekly)
    }

    private static var compactRowHeight: CGFloat {
        let fullCompactRowHeight = (viewportHeight - standardRowSpacing) / CGFloat(compactVisibleRowCount)
        return fullCompactRowHeight * 0.8
    }

    private static func usesCompactLayout(forServiceCount serviceCount: Int) -> Bool {
        serviceCount > 0 && serviceCount <= compactVisibleRowCount
    }
}
