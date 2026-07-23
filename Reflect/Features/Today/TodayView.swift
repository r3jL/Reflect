// The writing room (§3.6), wired to ReflectCore (M3): the day's draft loads
// or is created on appear, autosaves on idle/blur, and completes into the
// pipeline. Marginalia content (echoes, observations) arrives with Phase 1.
import SwiftUI

struct TodayView: View {
    @State private var model = TodayModel()
    @State private var isTyping = false
    @State private var idleTimer: Timer?

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
                            metaBlock(label: "Words today", value: "\(model.wordCount)")
                            if model.streakDays > 1 {
                                metaBlock(
                                    label: "Writing streak",
                                    value: "\(model.streakDays) days")
                            }
                            if model.onThisDay > 0 {
                                metaBlock(
                                    label: "On this day",
                                    value: "\(model.onThisDay) past \(model.onThisDay == 1 ? "entry" : "entries")")
                            }
                        }
                    }
                }
                .frame(maxWidth: wide ? 1300 : 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
        .onAppear { model.load() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)
        ) { _ in
            model.flush()
            model.saveContext()
        }
    }

    // MARK: - Center: the writing

    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(text: Date.now.formatted(.dateTime.weekday(.wide)))
                .padding(.bottom, 14)

            Text(Date.now.formatted(.dateTime.month(.wide).day()))
                .font(Typography.serif(56, weight: .light))
                .foregroundStyle(Theme.ink)

            metaRow.padding(.top, 14)

            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Begin…")
                        .font(Typography.serif(22))
                        .foregroundStyle(Theme.ink4)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                SerifTextView(
                    text: $model.text,
                    onEdit: handleEdit,
                    onBlur: { model.flush() },
                    focusOnAppear: true
                )
                .frame(minHeight: 320)
            }
            .padding(.top, 44)

            completeRow.padding(.top, 34)
        }
        .frame(width: Theme.writingColumnWidth)
        .padding(.top, 120)
        .padding(.bottom, 160)
    }

    /// Mood dot (hollow until reflection exists) · place · weather (FR-015).
    private var metaRow: some View {
        HStack(spacing: 14) {
            Circle()
                .stroke(Theme.ink4, lineWidth: 1.5)
                .frame(width: 8, height: 8)

            dotSeparator
            contextField("Add place", text: $model.place)
            dotSeparator
            contextField("Weather", text: $model.weather)
            Spacer()
        }
        .font(Typography.sans(12.5))
        .foregroundStyle(Theme.ink3)
    }

    private var dotSeparator: some View {
        Circle().fill(Theme.ink4).frame(width: 3, height: 3)
    }

    private func contextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.ink3)
            .fixedSize()
            .onSubmit { model.saveContext() }
    }

    /// Quiet completion affordance; after completing, the AI-pending state
    /// (AC-004) shows as a breathing dot until the pipeline drains (Phase 1).
    @ViewBuilder
    private var completeRow: some View {
        if model.canComplete {
            Button(action: { model.complete() }) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    Text("Complete entry")
                        .font(Typography.sans(11))
                        .tracking(0.4)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if model.isCompleted {
            HStack(spacing: 8) {
                Kicker(text: "Completed")
                if model.pendingJobs {
                    HStack(spacing: 6) {
                        BreathingDot(color: Theme.accentSoft)
                        Text("AI pending")
                            .font(Typography.sans(11))
                            .foregroundStyle(Theme.ink4)
                    }
                }
            }
        }
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

/// The design's 4s "breathing" dot (§3.6 motion vocabulary).
struct BreathingDot: View {
    let color: Color
    @State private var up = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(up ? 1 : 0.55)
            .scaleEffect(up ? 1.35 : 1)
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: up)
            .onAppear { up = true }
    }
}
