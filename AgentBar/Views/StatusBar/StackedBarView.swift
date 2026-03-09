import SwiftUI

struct StackedBarView: View {
    let services: [UsageData]
    var hasError: Bool = false

    @State private var currentScrollIndex = 0
    @State private var isHovered = false

    private var rankedServices: [UsageData] {
        StatusBarDisplayPlanner.rankedServices(from: services)
    }

    private var rowHeight: CGFloat {
        StatusBarDisplayPlanner.rowHeight(forServiceCount: rankedServices.count)
    }

    private var rowSpacing: CGFloat {
        StatusBarDisplayPlanner.rowSpacing(forServiceCount: rankedServices.count)
    }

    private var shouldCenterRowsVertically: Bool {
        StatusBarDisplayPlanner.centersRowsVertically(forServiceCount: rankedServices.count)
    }

    private var cycleTaskID: String {
        let signature = rankedServices
            .map { usage in
                let fiveHour = Int((usage.fiveHourUsage.percentage * 1000).rounded())
                let weekly = Int(((usage.weeklyUsage?.percentage ?? 0) * 1000).rounded())
                return "\(usage.service.rawValue):\(fiveHour):\(weekly)"
            }
            .joined(separator: "|")
        return "\(signature)#hover:\(isHovered ? 1 : 0)"
    }

    var body: some View {
        if rankedServices.isEmpty {
            HStack(spacing: 2) {
                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 20)
        } else {
            scrollingRows
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        jumpToTopImmediately()
                    }
                }
                .task(id: cycleTaskID) {
                    await runScrollLoop()
                }
                .padding(.horizontal, 2)
        }
    }

    private var scrollingRows: some View {
        ZStack(alignment: shouldCenterRowsVertically ? .center : .top) {
            VStack(spacing: rowSpacing) {
                ForEach(rankedServices) { usage in
                    SingleBarView(usage: usage)
                        .frame(height: rowHeight)
                }
            }
            .offset(
                y: -CGFloat(currentScrollIndex)
                    * (rowHeight + rowSpacing)
            )
        }
        .frame(
            height: StatusBarDisplayPlanner.viewportHeight,
            alignment: shouldCenterRowsVertically ? .center : .top
        )
        .clipped()
    }

    @MainActor
    private func runScrollLoop() async {
        jumpToTopImmediately()

        let maxIndex = StatusBarDisplayPlanner.maxScrollIndex(for: rankedServices)
        guard maxIndex > 0 else { return }

        while !Task.isCancelled {
            if isHovered {
                jumpToTopImmediately()
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            let duration = currentScrollIndex == 0
                ? StatusBarDisplayPlanner.topPriorityHoldSeconds
                : StatusBarDisplayPlanner.scrollStepHoldSeconds
            let nanoseconds = UInt64(duration * 1_000_000_000)

            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard !isHovered else { continue }

            if currentScrollIndex < maxIndex {
                withAnimation(.easeInOut(duration: StatusBarDisplayPlanner.scrollTransitionSeconds)) {
                    currentScrollIndex += 1
                }
            } else {
                jumpToTopImmediately()
            }
        }
    }

    @MainActor
    private func jumpToTopImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentScrollIndex = 0
        }
    }
}

struct SingleBarView: View {
    let usage: UsageData

    var body: some View {
        HStack(spacing: 2) {
            Text(usage.service.shortName)
                .font(.system(size: 6, weight: .medium, design: .rounded))
                .foregroundStyle(usage.service.darkColor)
                .frame(width: 14, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background — visible outline when empty
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(usage.service.darkColor.opacity(0.15))

                    // Weekly usage (light color)
                    if let weekly = usage.weeklyUsage, weekly.percentage > 0 {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(usage.service.lightColor)
                            .frame(width: max(2, geo.size.width * weekly.percentage))
                    }

                    // 5-hour usage (dark color, overlaps weekly)
                    if usage.fiveHourUsage.percentage > 0 {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(usage.service.darkColor)
                            .frame(width: max(2, geo.size.width * usage.fiveHourUsage.percentage))
                    }
                }
            }
        }
    }
}
