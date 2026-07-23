import SwiftUI

enum AppSection: String, CaseIterable {
    case today = "Today"
    case life = "Life"
    case insights = "Insights"
}

struct AppShell: View {
    @State private var section: AppSection = .today
    @State private var showRemember = false
    @State private var showTrash = false
    @State private var lock = AppLock()

    var body: some View {
        ZStack {
            if lock.isLocked {
                // FR-014: nothing renders behind the lock.
                LockView(lock: lock)
            } else {
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

                if showTrash {
                    TrashView {
                        withAnimation(.easeOut(duration: 0.25)) { showTrash = false }
                    }
                    .zIndex(40)
                }
            }
        }
        .background(Theme.paper)
        .ignoresSafeArea()
        .onAppear {
            // FR-020: launch sweep — drain anything left pending.
            AppServices.orchestrator.kick()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .reflectShowTrash)
        ) { _ in
            guard !lock.isLocked else { return }
            withAnimation(.easeOut(duration: 0.25)) { showTrash = true }
        }
    }
}
