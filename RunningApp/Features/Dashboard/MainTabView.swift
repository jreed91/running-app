import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Tab = .home

    enum Tab: String, CaseIterable {
        case home     = "Home"
        case plan     = "Plan"
        case history  = "History"
        case progress = "Progress"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .home:     "house.fill"
            case .plan:     "calendar"
            case .history:  "clock.arrow.circlepath"
            case .progress: "chart.line.uptrend.xyaxis"
            case .settings: "gear"
            }
        }

        var strideIcon: StrideIconName {
            switch self {
            case .home:     return .home
            case .plan:     return .calendar
            case .history:  return .history
            case .progress: return .chart
            case .settings: return .gear
            }
        }
    }

    var body: some View {
        Group {
            switch selectedTab {
            case .home:     DashboardView()
            case .plan:     PlanTabView()
            case .history:  HistoryView()
            case .progress: ProgressDashboardView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Using the actual tab bar as the safeAreaInset content lets SwiftUI
            // automatically wire up ScrollView content insets to exactly this height.
            // .ignoresSafeArea lets the bar extend into the home-indicator region.
            glassTabBar
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var glassTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .padding(.bottom, 10)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }

    private func tabItem(_ tab: Tab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                StrideIcon(
                    name: tab.strideIcon,
                    size: 22,
                    color: isActive ? .brand : .secondary,
                    strokeWeight: isActive ? 2.2 : 1.8
                )
                Text(tab.rawValue)
                    .font(.system(size: 10, weight: isActive ? .bold : .medium))
                    .kerning(-0.1)
                    .foregroundStyle(isActive ? Color.brand : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                isActive
                    ? RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.brand.opacity(0.1))
                    : nil
            )
        }
        .buttonStyle(.plain)
    }
}
