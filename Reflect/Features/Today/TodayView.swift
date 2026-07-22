// The writing room (§3.6), M1 form: real date, live editor (in-memory until
// M2/M3 persistence), margin scaffolding with the fade-while-writing behavior.
// Marginalia content (echoes, observations) arrives with Phase 1.
import SwiftUI

struct TodayView: View {
    @State private var text = ""
    @State private var isTyping = false
    @State private var idleTimer: Timer?

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 1160
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    if wide {
                        marginColumn {
                            // Memory echoes appear here (Phase 1).
                            EmptyView()
                        }
                    }

                    centerColumn

                    if wide {
                        marginColumn {
                            metaBlock(label: "Words today", value: "\(wordCount)")
                        }
                    }
                }
                .frame(maxWidth: wide ? 1300 : 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
    }

    // MARK: - Center: the writing

    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: Date.now.formatted(.dateTime.weekday(.wide)))
                .padding(.bottom, 14)

            Text(Date.now.formatted(.dateTime.month(.wide).day()))
                .font(Typography.serif(56, weight: .light))
                .foregroundStyle(Theme.ink)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Begin…")
                        .font(Typography.serif(22))
                        .foregroundStyle(Theme.ink4)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                SerifTextView(text: $text, onEdit: handleEdit)
                    .frame(minHeight: 320)
            }
            .padding(.top, 44)
        }
        .frame(width: Theme.writingColumnWidth)
        .padding(.top, 120)
        .padding(.bottom, 160)
    }

    // MARK: - Margins

    private func marginColumn<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 34, content: content)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 34)
            .padding(.top, 130)
            .opacity(isTyping ? 0.25 : 1)
    }

    private func metaBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker(text: label)
            Text(value)
                .font(Typography.serif(16))
                .foregroundStyle(Theme.ink2)
        }
    }

    // MARK: - Focus behavior

    private func handleEdit() {
        withAnimation(.easeOut(duration: 0.3)) { isTyping = true }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeIn(duration: 0.7)) { isTyping = false }
            }
        }
    }
}
