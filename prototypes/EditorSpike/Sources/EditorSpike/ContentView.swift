// The Today writing room, reduced to what the spike must prove:
// center column + date header, live word count, margins that fade to 25%
// while typing and return on pause, and a 2s-idle autosave (AC-002 hook).
import SwiftUI

struct ContentView: View {
    @State private var text = """
        The studio is two days old and already it has a smell — coffee and cut \
        wood and the particular dust of a room that is becoming something.
        """
    @State private var isTyping = false
    @State private var lastSave = "not yet"
    @State private var idleTimer: Timer?
    @State private var saveTimer: Timer?

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            margin(alignment: .leading) {
                marginBlock(
                    kicker: "Memory echo", kickerColor: Theme.accentSoft,
                    body: "A year ago this week you wrote that you were afraid to begin.",
                    meta: "July 2025")
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Tuesday".uppercased())
                    .font(.system(size: 11, weight: .regular))
                    .tracking(2.2)
                    .foregroundStyle(Theme.ink4)
                    .padding(.bottom, 14)
                Text("July 21")
                    .font(.system(size: 56, weight: .light, design: .serif))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 14) {
                    HStack(spacing: 7) {
                        Circle().fill(Color(hex: 0xB07E4A)).frame(width: 8, height: 8)
                        Text("warm")
                    }
                    Text("·").foregroundStyle(Theme.ink4)
                    Text("The studio")
                    Text("·").foregroundStyle(Theme.ink4)
                    Text("19°, clear")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
                .padding(.top, 14)

                SerifTextView(text: $text, onEdit: handleEdit)
                    .padding(.top, 44)
            }
            .frame(width: 640)
            .padding(.top, 120)

            margin(alignment: .leading) {
                marginBlock(
                    kicker: "Reflect noticed", kickerColor: Theme.ink4,
                    body: "You write about rooms the way other people write about people.",
                    meta: nil)
                Rectangle().fill(Theme.hair).frame(width: 44, height: 1)
                metaBlock(label: "Words today", value: "\(wordCount)")
                metaBlock(label: "Autosaved", value: lastSave)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }

    // MARK: - Behavior under test

    private func handleEdit() {
        withAnimation(.easeOut(duration: 0.3)) { isTyping = true }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeIn(duration: 0.7)) { isTyping = false }
            }
        }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async {
                let stamp = Date().formatted(date: .omitted, time: .standard)
                lastSave = stamp
                print("autosave @ \(stamp) — \(wordCount) words")
            }
        }
    }

    // MARK: - Pieces

    private func margin<Content: View>(
        alignment: HorizontalAlignment, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: alignment, spacing: 34, content: content)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 34)
            .padding(.top, 130)
            .opacity(isTyping ? 0.25 : 1)
    }

    private func marginBlock(kicker: String, kickerColor: Color, body: String, meta: String?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(kickerColor).frame(width: 5, height: 5)
                Text(kicker.uppercased()).font(.system(size: 10)).tracking(1.6)
            }
            .foregroundStyle(kickerColor)
            Text(body)
                .font(.system(size: 16, design: .serif).italic())
                .foregroundStyle(Theme.ink2)
                .lineSpacing(4)
            if let meta {
                Text(meta).font(.system(size: 11)).foregroundStyle(Theme.ink4)
            }
        }
    }

    private func metaBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.system(size: 10)).tracking(1.6)
                .foregroundStyle(Theme.ink4)
            Text(value).font(.system(size: 16, design: .serif)).foregroundStyle(Theme.ink2)
        }
    }
}
