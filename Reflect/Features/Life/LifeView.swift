// Life month map — M1 placeholder wearing the design's header; the calendar
// grid, mood washes, and cell-morph entry open land in M4.
import SwiftUI

struct LifeView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Kicker(text: season(for: Date.now) + " · " + Date.now.formatted(.dateTime.year()))
                    .padding(.bottom, 12)
                Text(Date.now.formatted(.dateTime.month(.wide)))
                    .font(Typography.serif(88, weight: .light))
                    .foregroundStyle(Theme.ink)
                Text("The shape of these weeks, remembered.")
                    .font(Typography.serifItalic(19))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 56)
            .padding(.top, 76)
        }
        .background(Theme.paper)
    }

    private func season(for date: Date) -> String {
        let names = [
            "Deep winter", "Late winter", "Early spring", "Spring", "Late spring",
            "Early summer", "High summer", "Late summer", "Early autumn", "Autumn",
            "Late autumn", "Winter",
        ]
        return names[Calendar.current.component(.month, from: date) - 1]
    }
}
