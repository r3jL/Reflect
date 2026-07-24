// Insights (§3.6, M15 form): the monthly chapter's header + count-up stat
// row with real numbers, theme & entity browse (FR-027), open action items
// (FR-028). The essay arrives in Phase 4; its place is held quietly.
import ReflectCore
import SwiftUI

struct InsightsView: View {
    @State private var model = InsightsModel()

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    statsRow.padding(.top, 56)
                    Rectangle().fill(Theme.hair2)
                        .frame(width: 44, height: 1)
                        .padding(.vertical, 56)

                    VStack(alignment: .leading, spacing: 64) {
                        threadsSection
                        peopleSection
                        stillOpenSection
                    }
                    .frame(maxWidth: 820, alignment: .leading)

                    closingCard.padding(.top, 80)
                }
                .padding(.horizontal, 40)
                .padding(.top, 96)
                .padding(.bottom, 160)
                .frame(maxWidth: .infinity)
            }

            browseOverlay
            openedOverlay
        }
        .background(Theme.paper)
        .onAppear { model.load() }
    }

    // MARK: - Header + stats

    private var header: some View {
        VStack(spacing: 22) {
            Text(model.seasonKicker.uppercased())
                .font(Typography.sans(11))
                .tracking(3.1)
                .foregroundStyle(Theme.ink4)
            Text(model.monthName)
                .font(Typography.serif(118, weight: .light))
                .foregroundStyle(Theme.ink)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 52) {
            statBlock(model.stats.entryCount, "journal pages")
            statBlock(model.streakDays, "day streak")
            statBlock(model.stats.wordCount, "words")
            statBlock(model.stats.photoCount, "photographs")
        }
    }

    private func statBlock(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 8) {
            CountUpText(value: value)
            Text(label.uppercased())
                .font(Typography.sans(11))
                .tracking(1.2)
                .foregroundStyle(Theme.ink4)
        }
    }

    // MARK: - Sections

    private func sectionHeader(_ label: String) -> some View {
        HStack(spacing: 14) {
            Text(label.uppercased())
                .font(Typography.sans(12))
                .tracking(2.4)
                .foregroundStyle(Theme.ink4)
            Rectangle().fill(Theme.hair).frame(height: 1)
        }
    }

    @ViewBuilder
    private var threadsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Threads")
            if model.themes.isEmpty {
                emptyLine("Themes appear as Reflect reads your entries.")
            } else {
                FlowRow(spacing: 10) {
                    ForEach(model.themes, id: \.name) { theme in
                        chip(theme.name, count: theme.count) {
                            model.browseTheme(theme.name)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("People & places")
            if model.entities.isEmpty {
                emptyLine("The people, places and projects of your life gather here.")
            } else {
                FlowRow(spacing: 10) {
                    ForEach(model.entities, id: \.entity.name) { item in
                        chip(item.entity.name, count: item.count) {
                            model.browseEntity(item.entity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stillOpenSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Still open")
            if model.actions.isEmpty {
                emptyLine("Nothing waiting on you. The page is clear.")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.actions) { action in
                        actionRow(action)
                    }
                }
            }
        }
    }

    private func actionRow(_ action: MetadataRepository.OpenAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.text)
                    .font(Typography.serif(17))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    Text(action.entryDate)
                        .font(Typography.sans(11))
                        .foregroundStyle(Theme.ink4)
                    if let hint = action.dueHint {
                        Text(hint)
                            .font(Typography.sans(11))
                            .foregroundStyle(Theme.accentSoft)
                    }
                }
            }
            Spacer()
            Button("done") { model.markAction(action, done: true) }
                .buttonStyle(.plain)
                .font(Typography.sans(11, weight: .medium))
                .foregroundStyle(Theme.accent)
            Button("let go") { model.markAction(action, done: false) }
                .buttonStyle(.plain)
                .font(Typography.sans(11))
                .foregroundStyle(Theme.ink4)
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair).frame(height: 1)
        }
    }

    private var closingCard: some View {
        VStack(spacing: 18) {
            Kicker(text: "Closing reflection")
            Text("Your chapter arrives at month's end.")
                .font(Typography.serifItalic(22))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: 640)
        .padding(44)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2))
    }

    // MARK: - Pieces

    private func chip(_ label: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(label)
                    .font(Typography.sans(13))
                    .foregroundStyle(Theme.ink2)
                Text("\(count)")
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Theme.paper)
                    .overlay(Capsule().stroke(Theme.hair, lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.serifItalic(16))
            .foregroundStyle(Theme.ink3)
    }

    // MARK: - Overlays (browse → entry, FR-027 flow)

    @ViewBuilder
    private var browseOverlay: some View {
        if let browsing = model.browsing {
            Theme.paper3.opacity(0.72)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { model.browsing = nil }
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Kicker(text: "Entries about")
                        Text(browsing.title)
                            .font(Typography.serif(30, weight: .light))
                            .foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    Button(action: { model.browsing = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.paper))
                            .overlay(Circle().stroke(Theme.hair, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(browsing.entries) { entry in
                            Button(action: { model.open(entry) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.entryDate)
                                        .font(Typography.sans(11))
                                        .foregroundStyle(Theme.ink4)
                                    Text(EchoService.snippet(entry.body))
                                        .font(Typography.serif(17))
                                        .foregroundStyle(Theme.ink)
                                        .multilineTextAlignment(.leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 26)
                }
            }
            .padding(36)
            .frame(maxWidth: 560, maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.3), radius: 34, y: 18)
            )
            .padding(60)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var openedOverlay: some View {
        if let opened = model.opened {
            Theme.ink.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { model.opened = nil }
                .transition(.opacity)
            EntryReadView(
                entry: opened,
                mood: model.openedMood,
                onClose: {
                    withAnimation(.easeOut(duration: 0.3)) { model.opened = nil }
                }
            )
            .padding(40)
            .transition(.scale(scale: 0.985).combined(with: .opacity))
        }
    }
}

/// The design's count-up numeral (~1.1s ease-out).
struct CountUpText: View {
    let value: Int
    @State private var displayed = 0

    var body: some View {
        Text("\(displayed)")
            .font(Typography.serif(52, weight: .light))
            .foregroundStyle(Theme.accent)
            .monospacedDigit()
            .task(id: value) {
                let start = ContinuousClock.now
                let duration = 1.1
                while true {
                    let elapsed = Double(
                        (ContinuousClock.now - start).components.attoseconds) / 1e18
                    let k = min(1, elapsed / duration)
                    let eased = 1 - pow(1 - k, 3)
                    displayed = Int(Double(value) * eased)
                    if k >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(33))
                }
                displayed = value
            }
    }
}
