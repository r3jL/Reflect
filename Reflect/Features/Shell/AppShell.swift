import SwiftUI

enum AppSection: String, CaseIterable {
    case today = "Today"
    case life = "Life"
    case insights = "Insights"
}

struct AppShell: View {
    @State private var section: AppSection = .today

    var body: some View {
        VStack(spacing: 0) {
            TopBar(section: $section)
            ZStack {
                switch section {
                case .today: TodayView()
                case .life: LifeView()
                case .insights: InsightsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.paper)
        .ignoresSafeArea()
    }
}
