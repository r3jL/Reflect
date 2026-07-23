import SwiftUI

enum AppSection: String, CaseIterable {
    case today = "Today"
    case life = "Life"
    case insights = "Insights"
}

struct AppShell: View {
    @State private var section: AppSection = .today
    @State private var showRemember = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(section: $section) {
                    withAnimation(.easeOut(duration: 0.32)) { showRemember = true }
                }
                ZStack {
                    switch section {
                    case .today: TodayView()
                    case .life: LifeView()
                    case .insights: InsightsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showRemember {
                RememberView {
                    withAnimation(.easeOut(duration: 0.25)) { showRemember = false }
                }
                .zIndex(30)
            }
        }
        .background(Theme.paper)
        .ignoresSafeArea()
    }
}
