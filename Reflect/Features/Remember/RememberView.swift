// The Remember overlay (§3.6): full-screen blur, a giant serif question,
// grouped results, suggestion chips. A chosen memory opens the read view
// above the overlay; ESC walks back out.
import ReflectCore
import SwiftUI

struct RememberView: View {
    var onClose: () -> Void

    @State private var model = RememberModel()
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            // Veil over the whole stage
            Theme.paper3.opacity(0.72)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    searchField
                    lead
                    if model.isEmptyState {
                        chips.padding(.top, 24)
                    } else {
                        results.padding(.top, 26)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 120)
                .padding(.bottom, 120)
                .frame(maxWidth: .infinity)
            }

            if let opened = model.opened {
                Theme.ink.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { model.opened = nil }
                EntryReadView(
                    entry: opened,
                    mood: model.openedMood,
                    onClose: { withAnimation(.easeOut(duration: 0.3)) { model.opened = nil } }
                )
                .padding(40)
                .transition(.scale(scale: 0.985).combined(with: .opacity))
            }
        }
        .transition(.opacity)
        .onAppear {
            model.loadHints()
            searchFocused = true
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField(
                "What are you trying to remember?", text: $model.query,
                axis: .horizontal
            )
            .textFieldStyle(.plain)
            .font(Typography.serif(38, weight: .light))
            .foregroundStyle(Theme.ink)
            .focused($searchFocused)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.paper))
                    .overlay(Circle().stroke(Theme.hair2, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hair2).frame(height: 1)
        }
    }

    @ViewBuilder
    private var lead: some View {
        if !model.lead.isEmpty {
            Text(model.lead)
                .font(Typography.serifItalic(18))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 26)
        }
    }

    private var chips: some View {
        FlowRow(spacing: 10) {
            ForEach(model.hints, id: \.self) { hint in
                Button(action: { model.query = hint }) {
                    Text(hint)
                        .font(Typography.sans(13))
                        .foregroundStyle(Theme.ink2)
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
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 38) {
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Text(group.label.uppercased())
                            .font(Typography.sans(11))
                            .tracking(2)
                            .foregroundStyle(Theme.accentSoft)
                        Rectangle().fill(Theme.hair).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(group.items, id: \.entry.id) { hit in
                            resultRow(hit)
                        }
                    }
                }
            }
        }
    }

    private func resultRow(_ hit: EntriesRepository.SearchHit) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.3)) { model.open(hit.entry) } }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedDay(hit.entry.entryDate))
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
                Text(hit.snippet.isEmpty ? String(hit.entry.body.prefix(120)) : hit.snippet)
                    .font(Typography.serif(20))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formattedDay(_ entryDate: String) -> String {
        let parts = entryDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(
                  from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return entryDate }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    // MARK: - Keys (ESC: close entry, then overlay)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if model.opened != nil {
                withAnimation(.easeOut(duration: 0.3)) { model.opened = nil }
            } else {
                onClose()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Minimal wrapping layout for the suggestion chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
