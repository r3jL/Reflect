// Insights monthly chapter — M1 placeholder. Real stats arrive with M9's
// data; the essay itself is Phase 4 (§3.6).
import SwiftUI

struct InsightsView: View {
    var body: some View {
        VStack(spacing: 22) {
            Kicker(text: "Insights")
            Text("Your chapter arrives at month's end.")
                .font(Typography.serifItalic(23))
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
